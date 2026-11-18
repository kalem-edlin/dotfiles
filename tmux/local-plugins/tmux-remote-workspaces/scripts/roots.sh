#!/usr/bin/env bash
# Root-level operations shared by rw handoff / handback / open / forget /
# reclaim / status and libexec/reconcile-pending. Sourced only; never
# executed directly. Builds on common.sh (ownership records, ssh transport,
# endpoint registry) -- see the ownership section there for the record
# layout, and docs/tasks/mini-remote-sessions.md for the contracts.

RW_ROOTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$RW_ROOTS_DIR/common.sh"

RW_TAB="$(printf '\t')"

# rw_root_panes <root_local>
# Every pane on this tmux server (any session) whose cwd is the root or
# inside it, one line each:
#   pane_id<TAB>cwd<TAB>session<TAB>window_index<TAB>pane_index<TAB>@rw-endpoint<TAB>@rw-root-id<TAB>command
rw_root_panes() {
  local root="$1"
  tmux list-panes -a -F "#{pane_id}${RW_TAB}#{pane_current_path}${RW_TAB}#{session_name}${RW_TAB}#{window_index}${RW_TAB}#{pane_index}${RW_TAB}#{@rw-endpoint}${RW_TAB}#{@rw-root-id}${RW_TAB}#{pane_current_command}" 2>/dev/null |
    awk -F '\t' -v root="$root" '$2 == root || index($2, root "/") == 1'
}

# rw_root_bound_panes <root_id> <endpoint-ids...>
# Panes bound to the root: @rw-root-id equals it, or @rw-endpoint is one of
# the record's endpoints (a pane restored before @rw-root-id existed).
# Prints pane_id<TAB>endpoint_id.
rw_root_bound_panes() {
  local root_id="$1"
  shift
  tmux list-panes -a -F "#{pane_id}${RW_TAB}#{@rw-endpoint}${RW_TAB}#{@rw-root-id}" 2>/dev/null |
    awk -F '\t' -v id="$root_id" -v eps="$*" '
      BEGIN { n = split(eps, e, " "); for (i = 1; i <= n; i++) want[e[i]] = 1 }
      $2 != "" && ($3 == id || ($2 in want)) { print $1 "\t" $2 }'
}

# rw_path_under_root <path> <root_local> <worker_root>
# Maps a focus-side path inside the root onto the worker; a path outside
# the root maps to the worker root itself.
rw_path_under_root() {
  local path="$1" root="$2" worker_root="$3"
  case "$path" in
    "$root") printf '%s\n' "$worker_root" ;;
    "$root"/*) printf '%s/%s\n' "$worker_root" "${path#"$root"/}" ;;
    *) printf '%s\n' "$worker_root" ;;
  esac
}

# rw_is_idle_command <pane_current_command> -- a shell or an editor: safe to
# replace (editors only lose unsaved buffers, which the picker warns about).
rw_is_idle_command() {
  case "$1" in
    zsh | bash | sh | fish | dash | ksh | -zsh | -bash | nvim | vim | vi) return 0 ;;
  esac
  return 1
}

# rw_mirror_push_from_record <worker> <worker_home> <root_id>
# Pushes the focus record (rewritten for the worker: root_local = the
# worker's own path) and both manifests to the worker's mirror dir.
rw_mirror_push_from_record() {
  local worker="$1" worker_home="$2" root_id="$3" dir tmp json
  dir="$(rw_owned_record_dir "$root_id")"
  json="$(rw_owned_record_read "$root_id")" || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rw-mirror.XXXXXX")"
  printf '%s' "$json" | jq -c '.root_local = .worker_root' >"$tmp/record.json"
  [ -f "$dir/manifest.focus.tsv" ] && cp "$dir/manifest.focus.tsv" "$tmp/"
  [ -f "$dir/manifest.worker.tsv" ] && cp "$dir/manifest.worker.tsv" "$tmp/"
  rw_worker_mirror_push "$worker" "$worker_home" "$root_id" "$tmp"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

# rw_mirror_push_json <worker> <worker_home> <root_id> <record-json> [manifest-dir]
# Pushes an explicit mirror record (and manifests named manifest.*.tsv in
# [manifest-dir]) -- used after hand-back, when the focus record is gone.
rw_mirror_push_json() {
  local worker="$1" worker_home="$2" root_id="$3" json="$4" mdir="${5:-}" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rw-mirror.XXXXXX")"
  printf '%s' "$json" | jq -c '.root_local = .worker_root' >"$tmp/record.json"
  if [ -n "$mdir" ]; then
    [ -f "$mdir/manifest.focus.tsv" ] && cp "$mdir/manifest.focus.tsv" "$tmp/"
    [ -f "$mdir/manifest.worker.tsv" ] && cp "$mdir/manifest.worker.tsv" "$tmp/"
  fi
  rw_worker_mirror_push "$worker" "$worker_home" "$root_id" "$tmp"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

# rw_release_pane <pane_id> <dir>
# Replaces a pane's root process (attach-loop -> ssh) with tmux's local
# shell in <dir>, keeping the pane id, layout and window, and clears its
# remote options. Atomic via respawn-pane -k: an attach loop never sees a
# tombstone first and takes its intentional-close path (2026-08-09).
rw_release_pane() {
  local pane_id="$1" dir="$2" shell cmd
  shell="$(tmux show-options -gv default-shell 2>/dev/null || true)"
  if [ -z "$shell" ] || [ ! -x "$shell" ]; then
    shell="${SHELL:-/bin/sh}"
  fi
  printf -v cmd 'exec %q -l' "$shell"
  [ -d "$dir" ] || dir="$HOME"
  tmux respawn-pane -k -t "$pane_id" -c "$dir" "$cmd" 2>/dev/null || return 1
  local opt
  for opt in @rw-endpoint @rw-worker @rw-workspace @rw-root-id @remote-host @workspace-resurrect-skip; do
    rw_pane_unset "$pane_id" "$opt"
  done
  return 0
}

# rw_wait_local_shell <pane_id> -- up to ~10s for the pane to show a shell.
rw_wait_local_shell() {
  local pane_id="$1" i=0 cmd
  while [ "$i" -lt 20 ]; do
    cmd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
    case "$cmd" in
      zsh | bash | sh | fish | -zsh | -bash) return 0 ;;
    esac
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

# rw_forget_worker_copy <worker> <worker_home> <root_id> <root_rel>
# Deletes the worker copy and its mirror record, but only when the mirror
# record exists and names the same root_rel (never deletes a directory this
# focus machine did not hand off). Prints one of: deleted | no-mirror.
# Returns 6 when the worker cannot be reached.
rw_forget_worker_copy() {
  local worker="$1" worker_home="$2" root_id="$3" root_rel="$4" mirror root out status=0
  case "$root_rel" in '' | /* | '~'* | ..* | */..* ) return 7 ;; esac
  mirror="$(rw_worker_mirror_dir "$worker_home" "$root_id")"
  root="${worker_home%/}/$root_rel"
  out="$(rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" "
    m=$(rw_shquote "$mirror"); r=$(rw_shquote "$root")
    if [ -f \"\$m/record.json\" ] && grep -Fq $(rw_shquote "\"root_rel\":\"$root_rel\"") \"\$m/record.json\"; then
      rm -rf -- \"\$r\" && rm -rf -- \"\$m\" && echo deleted
    else
      echo no-mirror
    fi" </dev/null 2>/dev/null)" || status=$?
  [ "$status" -eq 0 ] || return 6
  printf '%s\n' "$out"
}

# rw_close_root_endpoints <root_id> <reason> [endpoint ids...]
# Tombstone-first close of each endpoint (kills its worker session when
# reachable) and removes it from the record.
rw_close_root_endpoints() {
  local root_id="$1" reason="$2" e
  shift 2
  for e in "$@"; do
    [ -n "$e" ] || continue
    rw_close_endpoint_core "$e" "$reason" </dev/null
    rw_record_remove_endpoint "$root_id" "$e"
  done
}

# rw_reconcile_pending <worker> <worker_home>
# Runs every pending action recorded for <worker>, now that it answered:
#   pending.action = forget    -> close endpoints, delete the worker copy
#                                 and mirror, drop the focus record
#   pending.action = reconcile -> close the root's endpoints (their worker
#                                 sessions), mark the mirror stale and
#                                 focus-owned, keep the worker copy; drop
#                                 the focus record unless it is worker-owned
# Best effort: a failure leaves the record pending for the next contact.
rw_reconcile_pending() {
  local worker="$1" worker_home="$2" rec root_id root_rel action owner eps out
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    root_id="$(printf '%s' "$rec" | jq -r '.root_id')"
    root_rel="$(printf '%s' "$rec" | jq -r '.root_rel')"
    action="$(printf '%s' "$rec" | jq -r '.pending.action // empty')"
    owner="$(printf '%s' "$rec" | jq -r '.owner')"
    # shellcheck disable=SC2207 # endpoint ids are fixed-format hex
    eps=($(printf '%s' "$rec" | jq -r '.endpoints[]?'))
    case "$action" in
      forget)
        rw_close_root_endpoints "$root_id" "forget" ${eps[@]+"${eps[@]}"}
        out="$(rw_forget_worker_copy "$worker" "$worker_home" "$root_id" "$root_rel")" || continue
        rw_owned_record_remove "$root_id"
        rw_held_unmark "$worker" "$root_id"
        rw_log_event "forget" "" "$worker" "" "success" "root=$root_rel pending=1 worker_copy=$out"
        ;;
      reconcile)
        rw_close_root_endpoints "$root_id" "reconcile:${owner}" ${eps[@]+"${eps[@]}"}
        rw_mirror_push_json "$worker" "$worker_home" "$root_id" \
          "$(printf '%s' "$rec" | jq -c '.owner = "focus" | .endpoints = [] | .stale_worker = true | del(.pending)')" || continue
        if [ "$owner" = "worker" ]; then
          rw_owned_record_write "$root_id" "$(rw_owned_record_read "$root_id" | jq -c 'del(.pending) | del(.stale_worker)')"
        else
          rw_owned_record_remove "$root_id"
        fi
        rw_log_event "reconcile" "" "$worker" "" "success" "root=$root_rel pending=1 closed=${#eps[@]}"
        ;;
    esac
  done < <(rw_owned_records_json | jq -c --arg w "$worker" '.[] | select(.worker == $w and .pending != null)')

  # Held entries with a pending forget whose focus record is gone (a second
  # unreachable worker during one `rw forget`).
  local f
  for f in "$(rw_held_dir)/$worker"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.pending.action // empty' "$f" 2>/dev/null)" = "forget" ] || continue
    root_id="$(jq -r '.root_id' "$f")"
    root_rel="$(jq -r '.root_rel' "$f")"
    out="$(rw_forget_worker_copy "$worker" "$worker_home" "$root_id" "$root_rel")" || continue
    rm -f "$f"
    rw_log_event "forget" "" "$worker" "" "success" "root=$root_rel pending=1 worker_copy=$out"
  done
  return 0
}
