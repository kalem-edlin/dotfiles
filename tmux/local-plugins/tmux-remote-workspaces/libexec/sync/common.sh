#!/usr/bin/env bash
# Shared helpers for the workspace transfer core (libexec/sync/handoff).
# Sourced only; never executed directly.
#
# This extends, never duplicates, the shared plugin helpers in
# scripts/common.sh (machine id, event log, endpoint registry, ssh
# transport). It adds the pieces specific to Phase 4/5 handoff: a
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
# initial-plan.md asks for so local-dir testing and real ssh share one code
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
rw_sync_shquote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

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
__rw_untracked="$(git -C "$__RW_FP_PATH" ls-files --others --exclude-standard -z | LC_ALL=C sort -z | rw_sync_hash)"
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
# endpoint registry (--endpoint), per initial-plan.md's synchronization
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
# Claim marker helpers -- the .worktree-claim marker travels with the
# workspace as coordination metadata (initial-plan.md "Worktree claims and
# editing ownership"; worktrees/.local/lib/worktrees/common.sh's
# wt_sync_claim_from_marker adopts it into the far side's registry lazily,
# the next time anything there touches worktree-claim). This package never
# calls worktree-claim over ssh; the marker file is enough.
# ---------------------------------------------------------------------------

rw_sync_claim_marker_name() { printf '.worktree-claim\n'; }

# Resolve the worktree-claim executable: prefer $PATH (normal installed
# case, ~/.local/bin/worktree-claim via the worktrees stow package), fall
# back to the in-repo path so this also works from an unstowed checkout
# (dev/test environments).
rw_sync_worktree_claim_bin() {
  if command -v worktree-claim >/dev/null 2>&1; then
    command -v worktree-claim
    return 0
  fi
  local candidate
  candidate="$(cd "$RW_SYNC_LIB_DIR/../../../../.." && pwd)/worktrees/.local/bin/worktree-claim"
  [ -x "$candidate" ] && printf '%s\n' "$candidate"
}
