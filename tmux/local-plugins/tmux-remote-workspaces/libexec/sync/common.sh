#!/usr/bin/env bash
# Shared helpers for the workspace transfer core (libexec/sync/handoff).
# Sourced only; never executed directly.
#
# This extends, never duplicates, the shared plugin helpers in
# scripts/common.sh (machine id, event log, endpoint registry, ssh
# transport). It adds the pieces specific to handoff: a
# destination "exec wrapper" abstraction so the same code path drives a real
# ssh worker and a plain local directory in tests, plus a content
# fingerprint used for divergence detection.
#
# Written to run identically wherever it is sourced from -- rely only on
# things scripts/common.sh already relies on (bash, jq, tar, git). Remote-side
# logic is always run by explicitly invoking `bash -s` over the exec wrapper
# (see rw_sync_dest_exec_script), never by trusting the destination login
# shell to be bash -- this sidesteps an ambiguous remote $SHELL entirely.

RW_SYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RW_SYNC_SCRIPTS_DIR="$(cd "$RW_SYNC_LIB_DIR/../../scripts" && pwd)"
# shellcheck source-path=SCRIPTDIR/../../scripts
# shellcheck source=common.sh
source "$RW_SYNC_SCRIPTS_DIR/common.sh"

# ---------------------------------------------------------------------------
# Destination exec wrapper
#
# The wrapper is an argv PREFIX (binary + fixed args); the actual command is
# always appended as the final argv element -- this is the "exec-wrapper"
# docs/tmux-remote-workspaces.md asks for so local-dir testing and real ssh share one code
# path:
#   ssh -o BatchMode=yes -o ConnectTimeout=8 mini   -- real worker
#   bash -c                                          -- local-dir test double
#   <anything else>                                  -- --dest-mode custom,
#                                                        e.g. a throttling/
#                                                        truncating test
#                                                        wrapper that
#                                                        simulates a dropped
#                                                        transfer
# ---------------------------------------------------------------------------

RW_SYNC_DEST_EXEC_BIN=""
RW_SYNC_DEST_EXEC_ARGS=()

rw_sync_set_dest_exec_ssh() {
  local worker="$1"
  RW_SYNC_DEST_EXEC_BIN="$(rw_ssh_bin)"
  RW_SYNC_DEST_EXEC_ARGS=(-o BatchMode=yes -o ConnectTimeout="$(rw_ssh_connect_timeout)" "$worker")
}

rw_sync_set_dest_exec_local() {
  RW_SYNC_DEST_EXEC_BIN="bash"
  RW_SYNC_DEST_EXEC_ARGS=(-c)
}

rw_sync_set_dest_exec_custom() {
  local bin="$1"
  shift
  RW_SYNC_DEST_EXEC_BIN="$bin"
  RW_SYNC_DEST_EXEC_ARGS=("$@")
}

rw_sync_dest_exec_configured() { [ -n "$RW_SYNC_DEST_EXEC_BIN" ]; }

# Runs "$1" (a short, single shell command string -- caller is responsible
# for quoting any embedded paths with rw_sync_shquote) on the destination.
# Normal stdio inheritance: a caller may pipe into this and/or capture its
# stdout via command substitution. Exit status is the destination command's.
rw_sync_dest_run() {
  local cmd="$1"
  rw_sync_dest_exec_configured || rw_die "sync: destination exec wrapper not configured" 70
  "$RW_SYNC_DEST_EXEC_BIN" "${RW_SYNC_DEST_EXEC_ARGS[@]+"${RW_SYNC_DEST_EXEC_ARGS[@]}"}" "$cmd"
}

# Runs local file $1 as a bash script *on the destination*, over the exec
# wrapper, by piping its content over stdin and explicitly invoking `bash -s`
# remotely/locally -- this is what lets every path embedded in the generated
# script (via heredoc substitution, %q-quoted at generation time) be
# trusted, because the interpreter that will parse it is always the bash we
# just invoked, never an ambiguous remote login shell.
rw_sync_dest_exec_script() {
  local script_file="$1"
  rw_sync_dest_exec_configured || rw_die "sync: destination exec wrapper not configured" 70
  "$RW_SYNC_DEST_EXEC_BIN" "${RW_SYNC_DEST_EXEC_ARGS[@]+"${RW_SYNC_DEST_EXEC_ARGS[@]}"}" "bash -s" <"$script_file"
}

# POSIX-safe single-quote escaping for embedding a value inside a command
# STRING passed to rw_sync_dest_run (as opposed to rw_sync_dest_exec_script,
# where paths are embedded via heredoc expansion instead).
rw_sync_shquote() { rw_shquote "$1"; }

# ---------------------------------------------------------------------------
# Content fingerprint: HEAD commit + hash of staged/unstaged/untracked state.
# Used for divergence detection -- "has this side changed since the last
# recorded synchronization generation?" Identical algorithm locally and
# remotely (the remote copy runs via rw_sync_dest_exec_script so it is
# always interpreted by the same bash).
# ---------------------------------------------------------------------------

# Prints a self-contained bash script (to stdout) that computes and prints
# the fingerprint of the git worktree at $__RW_FP_PATH when run. $__RW_FP_PATH
# is substituted by the caller via a heredoc, not passed positionally, so
# this never needs remote argv quoting.
rw_sync_fingerprint_script_body() {
  cat <<'EOS'
rw_sync_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}
if ! git -C "$__RW_FP_PATH" rev-parse HEAD >/dev/null 2>&1; then
  printf 'EMPTY\n'
  exit 0
fi
__rw_head="$(git -C "$__RW_FP_PATH" rev-parse HEAD)"
__rw_staged="$(git -C "$__RW_FP_PATH" diff --binary --cached | rw_sync_hash)"
__rw_unstaged="$(git -C "$__RW_FP_PATH" diff --binary | rw_sync_hash)"
# Keep-both copies (<file>.local-YYYYMMDD-HHMMSS, see the manifest gate in
# ./handoff) are deliberately invisible to divergence tracking.
__rw_untracked="$(git -C "$__RW_FP_PATH" ls-files --others --exclude-standard -z | tr '\0' '\n' |
  grep -Ev '\.local-[0-9]{8}-[0-9]{6}$' | LC_ALL=C sort | rw_sync_hash)"
printf '%s:%s:%s:%s\n' "$__rw_head" "$__rw_staged" "$__rw_unstaged" "$__rw_untracked"
EOS
}

# Writes a ready-to-run fingerprint script for $1 (a path) to $2 (a file).
rw_sync_write_fingerprint_script() {
  local path="$1" out="$2"
  {
    printf '__RW_FP_PATH=%q\n' "$path"
    rw_sync_fingerprint_script_body
  } >"$out"
}

# Local fingerprint (no exec wrapper involved).
rw_sync_fingerprint_local() {
  local path="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rw-sync-fp.XXXXXX")"
  rw_sync_write_fingerprint_script "$path" "$tmp"
  bash "$tmp"
  rm -f "$tmp"
}

# Destination fingerprint, over the configured exec wrapper.
rw_sync_fingerprint_dest() {
  local path="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rw-sync-fp.XXXXXX")"
  rw_sync_write_fingerprint_script "$path" "$tmp"
  rw_sync_dest_exec_script "$tmp"
  rm -f "$tmp"
}

# Generic form: $1 is the NAME of a function that runs a local script file
# either locally or over the exec wrapper (see handoff's exec_source_script/
# exec_dest_script). This lets a caller get a fingerprint for "whichever
# side a given exec strategy reaches" without hard-coding local-vs-remote --
# what --pull (return handoff, where the source lives on the far side
# instead of the destination) needs.
rw_sync_fingerprint_via() {
  local exec_fn="$1" path="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rw-sync-fp.XXXXXX")"
  rw_sync_write_fingerprint_script "$path" "$tmp"
  "$exec_fn" "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Generation state: "what was the last-known-good synced fingerprint, and
# what generation number is that". Two interchangeable backends so the core
# is testable standalone (--state-file) as well as integrated with the real
# endpoint registry (--endpoint), per docs/tmux-remote-workspaces.md's synchronization
# generation requirement.
# ---------------------------------------------------------------------------

# Backend: endpoint registry (workspace.sync sub-object of endpoints/<id>.json)
rw_sync_gen_read_endpoint() {
  local endpoint_id="$1" json
  json="$(rw_read_endpoint "$endpoint_id" 2>/dev/null)" || {
    printf '{"generation":0,"fingerprint":null}\n'
    return 0
  }
  printf '%s' "$json" | jq -c '.workspace.sync // {generation:0,fingerprint:null}'
}

rw_sync_gen_write_endpoint() {
  local endpoint_id="$1" sync_json="$2" json
  json="$(rw_read_endpoint "$endpoint_id" 2>/dev/null)" || rw_die "sync: no registry entry for endpoint $endpoint_id to record a synchronization generation on" 70
  json="$(printf '%s' "$json" | jq -c --argjson sync "$sync_json" --arg now "$(rw_now_iso)" '.workspace.sync = $sync | .updated_at = $now')"
  rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$json"
}

# Backend: a plain state file (used by tests and any ad hoc/no-endpoint sync).
rw_sync_gen_read_statefile() {
  local file="$1"
  [ -f "$file" ] || {
    printf '{"generation":0,"fingerprint":null}\n'
    return 0
  }
  cat "$file"
}

rw_sync_gen_write_statefile() {
  local file="$1" sync_json="$2"
  rw_write_json_atomic "$file" "$sync_json"
}

# ---------------------------------------------------------------------------
# rsync channel and manifests (docs/tasks/mini-remote-sessions.md, Q4/C1).
#
# The rsync channel carries everything the git channel ignores: for a `git`
# root, exactly the gitignored set (`.env*`, node_modules, build output);
# for a `plain` root, the whole tree. A manifest lists every file that
# channel carries, one `<relpath>\t<size>\t<mtime-epoch>` row each (symlinks
# record mtime 0, since rsync does not carry symlink times), sorted
# byte-wise, plus a final `#git\t<fingerprint>` row for git roots (added by
# the caller). `.DS_Store` files and keep-both copies
# (`<file>.local-YYYYMMDD-HHMMSS`) are never listed.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034 # used by ./handoff, which sources this file
RW_SYNC_KEEP_BOTH_ERE='\.local-[0-9]{8}-[0-9]{6}$'

# rw_sync_kind_probe <path> -- a shell command printing "git" when <path>
# is a worktree toplevel, else "plain".
rw_sync_kind_probe() {
  local q
  q="$(rw_sync_shquote "$1")"
  printf '%s' "cd $q 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -z \"\$(git rev-parse --show-prefix 2>/dev/null)\" ] && echo git || echo plain"
}

# The collapsed gitignored entries of a worktree are the `!!` rows of
# `git status --ignored=matching`: every path that itself matches an ignore
# rule, directories collapsed and ending in "/". (`git ls-files -o -i
# --directory` is NOT equivalent: it also lists untracked parent
# directories that merely contain ignored paths, e.g. `pkgs/` for
# `pkgs/app/node_modules/`.) --no-optional-locks keeps a frozen copy's
# index untouched. Requires git >= 2.16.
RW_SYNC_IGNORED_LIST_CMD='git --no-optional-locks status --porcelain=v1 -z --ignored=matching --untracked-files=normal 2>/dev/null | tr '"'"'\0'"'"' '"'"'\n'"'"' | sed -n '"'"'s/^!! //p'"'"''

# Script body listing the collapsed gitignored entries of the worktree at
# $__RW_I_PATH, one per line. Empty when the path does not exist or is not
# a worktree.
rw_sync_ignored_script_body() {
  # shellcheck disable=SC2016 # expands in the generated script
  printf 'cd "$__RW_I_PATH" 2>/dev/null || exit 0\n'
  printf '%s\n' "$RW_SYNC_IGNORED_LIST_CMD"
}

rw_sync_write_ignored_script() {
  {
    printf '__RW_I_PATH=%q\n' "$1"
    rw_sync_ignored_script_body
  } >"$2"
}

# Script body printing the manifest rows of $__RW_M_PATH for kind
# $__RW_M_KIND. Portable across BSD (macOS) and GNU stat; bash 3.2-safe.
rw_sync_manifest_script_body() {
  printf '__rw_m_ignored() { %s; }\n' "$RW_SYNC_IGNORED_LIST_CMD"
  printf '__rw_m_untracked() { git ls-files --others --exclude-standard -z 2>/dev/null | tr "\\0" "\\n"; }\n' 
  cat <<'EOS'
cd "$__RW_M_PATH" 2>/dev/null || exit 0
__rw_m_list() {
  if [ "$__RW_M_KIND" = "git" ]; then
    # Ignored entries (the rsync channel) and untracked files (the git
    # channel's tar): every file whose CONTENT a sync can overwrite outside
    # git's own diff. A nested repository's .git is never listed.
    { __rw_m_ignored; __rw_m_untracked; } | while IFS= read -r __rw_e; do
        case "$__rw_e" in
          '') : ;;
          */) find "./${__rw_e%/}" -name .git -prune -o \( -type f -o -type l \) -print0 2>/dev/null ;;
          *) if [ -e "$__rw_e" ] || [ -L "$__rw_e" ]; then printf './%s\0' "$__rw_e"; fi ;;
        esac
      done
  else
    find . -path ./.git -prune -o \( -type f -o -type l \) -print0 2>/dev/null
  fi
}
if stat --version >/dev/null 2>&1; then
  __rw_m_stat() { xargs -0 stat --printf '%F\t%s\t%Y\t%n\n' 2>/dev/null; }
else
  __rw_m_stat() { xargs -0 stat -f '%HT%t%z%t%m%t%N' 2>/dev/null; }
fi
__rw_m_list | __rw_m_stat | awk -F '\t' '
  {
    t = tolower($1); s = $2; m = $3; p = $0
    sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", p)
    sub(/^\.\//, "", p)
    n = p; sub(/.*\//, "", n)
    if (n == ".DS_Store") next
    if (p ~ /\.local-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]$/) next
    if (t ~ /symbolic/) m = 0
    printf "%s\t%s\t%s\n", p, s, m
  }' | LC_ALL=C sort
exit 0
EOS
}

rw_sync_write_manifest_script() {
  {
    printf '__RW_M_PATH=%q\n' "$1"
    printf '__RW_M_KIND=%q\n' "$2"
    rw_sync_manifest_script_body
  } >"$3"
}

# rw_sync_manifest_local <path> <kind> -- manifest of a path on this host.
rw_sync_manifest_local() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rw-sync-manifest.XXXXXX")"
  rw_sync_write_manifest_script "$1" "$2" "$tmp"
  bash "$tmp"
  rm -f "$tmp"
}

# rw_sync_manifest_via <exec-script-fn> <path> <kind>
rw_sync_manifest_via() {
  local exec_fn="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rw-sync-manifest.XXXXXX")"
  rw_sync_write_manifest_script "$2" "$3" "$tmp"
  "$exec_fn" "$tmp"
  rm -f "$tmp"
}

# rw_sync_ignored_via <exec-script-fn> <path>
rw_sync_ignored_via() {
  local exec_fn="$1" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rw-sync-ignored.XXXXXX")"
  rw_sync_write_ignored_script "$2" "$tmp"
  "$exec_fn" "$tmp"
  rm -f "$tmp"
}

# rw_sync_manifest_git_fp <manifest-file> -- the `#git` fingerprint row.
rw_sync_manifest_git_fp() {
  [ -f "$1" ] || return 0
  awk -F '\t' '$1 == "#git" { print $2; exit }' "$1"
}

# rw_sync_manifest_diff <stored> <current> [--no-deleted]
# Prints `conflict\t<relpath>\t<changed|added|deleted>` for every file row
# that differs between a stored manifest and a copy's current manifest,
# sorted by path. `#` rows are ignored (the git fingerprint has its own
# divergence gate). --no-deleted drops rows only in <stored>; used when the
# baseline is the incoming source (a missing destination file is then
# simply about to be created, never at risk).
rw_sync_manifest_diff() {
  local stored="$1" current="$2" deleted=1
  [ "${3:-}" = "--no-deleted" ] && deleted=0
  [ -f "$stored" ] || stored=/dev/null
  [ -f "$current" ] || current=/dev/null
  awk -F '\t' -v deleted="$deleted" '
    FNR == NR { if ($1 ~ /^#/) next; s[$1] = $2 "\t" $3; next }
    $1 ~ /^#/ { next }
    {
      seen[$1] = 1
      if (!($1 in s)) printf "conflict\t%s\tadded\n", $1
      else if (s[$1] != $2 "\t" $3) printf "conflict\t%s\tchanged\n", $1
    }
    END { if (deleted) for (k in s) if (!(k in seen)) printf "conflict\t%s\tdeleted\n", k }
  ' "$stored" "$current" | LC_ALL=C sort -t "$(printf '\t')" -k2,2
}

# rw_sync_conflicts_at_risk <dest-now> <source-now> ; stdin: conflict rows
# Drops conflicts where nothing would be lost: the destination file already
# equals the incoming source file (a retried or partly finished sync), or a
# file deleted on the destination is absent from the source too.
rw_sync_conflicts_at_risk() {
  awk -F '\t' '
    FILENAME == ARGV[1] { if ($1 !~ /^#/) d[$1] = $2 "\t" $3; next }
    FILENAME == ARGV[2] { if ($1 !~ /^#/) s[$1] = $2 "\t" $3; next }
    {
      p = $2
      if ($3 == "deleted") { if (p in s) print; next }
      if ((p in s) && (p in d) && s[p] == d[p]) next
      print
    }' "$1" "$2" -
}

# rw_sync_manifests_equal <a> <b> -- file rows identical (ignores # rows).
rw_sync_manifests_equal() {
  [ -z "$(rw_sync_manifest_diff "$1" "$2")" ]
}

# rw_sync_rsync_escape -- escape rsync wildcard characters in a path read
# from stdin, so every rule below matches literally.
# rsync only treats a backslash as an escape when the pattern also holds a
# wildcard, so lines without one are left exactly as they are.
rw_sync_rsync_escape() { sed '/[][*?]/ s/[][*?\\]/\\&/g'; }

# rw_sync_write_rsync_rules <kind> <entries-file> <protect-file> <out>
# Filter rules for the rsync channel, first match wins:
#   - .DS_Store anywhere, keep-both copies anywhere, and every protected
#     path are excluded: never sent, and never removed by --delete (a
#     keep-both copy stays on the side it was made on until the user deals
#     with it; a retried sync must not delete it);
#   - plain: the root's own .git (if any) is excluded, everything else
#     travels;
#   - git: each collapsed ignored entry (the union of both sides' lists, so
#     an entry that vanished on the owner is deleted on the other side) is
#     included with its ancestor directories, and everything else -- the
#     git channel's tracked and untracked files, .git itself -- is excluded
#     and therefore also protected from --delete.
rw_sync_write_rsync_rules() {
  local kind="$1" entries="$2" protect="$3" out="$4"
  {
    printf -- '- .DS_Store\n'
    printf -- '- *.local-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]\n'
    if [ -s "$protect" ]; then
      rw_sync_rsync_escape <"$protect" | awk 'NF { print "- /" $0 }'
    fi
    if [ "$kind" = "plain" ]; then
      printf -- '- /.git\n'
    else
      if [ -s "$entries" ]; then
        rw_sync_rsync_escape <"$entries" | awk '
          NF {
            e = $0; dir = (e ~ /\/$/); sub(/\/+$/, "", e)
            n = split(e, part, "/"); pre = ""
            for (i = 1; i < n; i++) { pre = pre part[i] "/"; print "+ /" pre }
            if (dir) { print "+ /" e "/"; print "+ /" e "/**" } else print "+ /" e
          }' | LC_ALL=C sort -u
      fi
      printf -- '- *\n'
    fi
  } >"$out"
}
