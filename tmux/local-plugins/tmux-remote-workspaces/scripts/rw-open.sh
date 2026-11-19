#!/usr/bin/env bash
# `rw open` -- a new remote pane in a root the worker already owns (contract
# C2; replaces `rw ensure`). No sync: the worker copy is already the truth.
#
# Idempotent: run against a pane that already has a live @rw-endpoint it
# reattaches that endpoint instead of creating a second one.
#
# The pane's worker directory is its local cwd (or --dir, a path on this
# machine) mapped onto the worker (<worker home>/<path relative to ~>); a
# directory outside the root (possible with --root) maps to the worker root.
#
# Usage: rw-open.sh [--worker <alias>] [--root <path>] [--pane <pane-id>]
#                   [--dir <abs-path>]
#
# On success this script `exec`s into attach-loop.sh in the calling pane,
# or respawns the --pane target into it. It returns (shell intact) when
# the root is not remote (exit 7), the worker is unreachable (exit 6), or
# setup fails (exit 1), so a split that tried to open remote is not left
# dead.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

worker=""
root_arg=""
dir_arg=""
pane_id="${TMUX_PANE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --worker) worker="${2:?}"; shift 2 ;;
    --root) root_arg="${2:?}"; shift 2 ;;
    --pane) pane_id="${2:?}"; shift 2 ;;
    --dir) dir_arg="${2:?}"; shift 2 ;;
    *) rw_die "rw open: unknown argument: $1" 64 ;;
  esac
done

[ -n "$pane_id" ] || rw_die "rw open: must be run inside a tmux pane, or pass --pane" 64
case "$dir_arg" in '' | /*) : ;; *) rw_die "rw open: --dir takes an absolute path" 64 ;; esac

# start_loop <endpoint> [--fresh] -- the calling pane becomes the loop; any
# other pane is respawned into it.
start_loop() {
  local endpoint="$1" fresh="${2:-}" cmd dir
  if [ "$pane_id" = "${TMUX_PANE:-}" ]; then
    rw_root_unlock_all # exec skips the EXIT trap
    trap - EXIT
    exec "$SCRIPT_DIR/attach-loop.sh" "$endpoint" ${fresh:+"$fresh"}
  fi
  printf -v cmd '%q %q %s' "$SCRIPT_DIR/attach-loop.sh" "$endpoint" "$fresh"
  dir="$(rw_read_endpoint "$endpoint" | jq -r '.workspace.focus_path // empty')"
  dir="$(rw_local_existing_dir "${dir:-$HOME}")"
  tmux respawn-pane -k -t "$pane_id" -c "$dir" "$cmd" || rw_die "rw open: could not start the attach loop in pane $pane_id" 1
  exit 0
}

# --- Reattach: the pane already carries a registered endpoint --------------
existing="$(rw_pane_get "$pane_id" @rw-endpoint)"
if [ -n "$existing" ] && rw_endpoint_exists "$existing"; then
  existing_worker="$(rw_pane_get "$pane_id" @rw-worker)"
  if [ -z "$worker" ] || [ "$worker" = "$existing_worker" ]; then
    rw_log_event "reattach" "$existing" "$existing_worker" "" "success" "open"
    start_loop "$existing"
  fi
fi

start_ts="$(rw_now_epoch)"

# --- Root -------------------------------------------------------------------
if [ -n "$dir_arg" ]; then
  cwd="$dir_arg"
else
  cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$(pwd -P)"
cwd="$(rw_physical_path "$cwd")"
if [ -n "$root_arg" ]; then
  rel="$(rw_root_rel "$root_arg")" || rw_die "rw open: '$root_arg' is not inside your home directory." 7
  root_id="$(rw_root_id "$rel")"
else
  root_id="$(rw_owned_root_for_path "$cwd")" ||
    rw_die "rw open: '$cwd' is not in a remote root. Hand the directory off first ('rw handoff --worker <alias>')." 7
fi
record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
[ -n "$record" ] && [ "$(printf '%s' "$record" | jq -r '.owner')" = "worker" ] ||
  rw_die "rw open: ${root_arg:-$cwd} is not in a remote root. Hand it off first ('rw handoff --worker <alias>')." 7
rw_root_lock_or_die "$root_id" "rw open"
trap 'rw_root_unlock_all' EXIT
rec_worker="$(printf '%s' "$record" | jq -r '.worker')"
if [ -n "$worker" ] && [ "$worker" != "$rec_worker" ]; then
  rw_die "rw open: that root is remote on '$rec_worker', not '$worker'." 7
fi
worker="$rec_worker"
rw_worker_known "$worker" || rw_die "rw open: worker '$worker' is not declared in config.json" 1
root_local="$(printf '%s' "$record" | jq -r '.root_local')"
root_rel="$(printf '%s' "$record" | jq -r '.root_rel')"
kind="$(printf '%s' "$record" | jq -r '.kind')"

# --- Preflight ----------------------------------------------------------------
preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" --worker "$worker")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  rw_log_event "create" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "preflight_failed root=$root_rel"
  exit "$(rw_preflight_exit "$preflight_json")"
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"
worker_root="$(printf '%s' "$record" | jq -r '.worker_root // empty')"
[ -n "$worker_root" ] || worker_root="${worker_home%/}/$root_rel"

rw_reconcile_pending "$worker" "$worker_home"

# Worker-side zombie sweep (unregistered rw-<focus>-* sessions a worker
# restore revived) and the local unbound-endpoint report. Best effort.
"$RW_PLUGIN_DIR/libexec/reconcile-worker" --worker "$worker" </dev/null >/dev/null 2>&1 || true
"$RW_PLUGIN_DIR/libexec/reconcile-local" </dev/null >/dev/null 2>&1 || true

# --- Endpoint -----------------------------------------------------------------
case "$cwd" in
  "$root_local" | "$root_local"/*) focus_path="$cwd" ;;
  *) focus_path="$root_local" ;;
esac
remote_path="$(rw_path_under_root "$focus_path" "$root_local" "$worker_root")"

# The owned endpoint (shared with `rw switch`, roots.sh): the hidden session
# on the worker, endpoints/<id>.json, the record and its mirror.
if ! rw_endpoint_open owned "$worker" "$worker_home" "$(printf '%s' "$preflight_json" | jq -r '.hostname')" \
  "$pane_id" "$root_id" "$root_rel" "$kind" "$root_local" "$worker_root" "$focus_path" "$remote_path" open; then
  rw_log_event "create" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "remote_session: $RW_WORKER_SERVER_ERROR"
  rw_die "rw open: could not create the remote session for this pane: $RW_WORKER_SERVER_ERROR." 1
fi
endpoint_id="$RW_ENDPOINT_ID"
rw_bind_pane "$pane_id" "$endpoint_id"

rw_log_event "create" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$start_ts")" "success" "open root=$root_rel"
# New session on the worker: refresh its snapshot (fire and forget).
rw_worker_request_save "$worker"
start_loop "$endpoint_id" --fresh
