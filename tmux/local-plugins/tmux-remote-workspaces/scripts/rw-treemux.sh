#!/usr/bin/env bash
# Remote-aware Treemux dispatcher for `prefix + Tab`.
#
# A local tmux pane that is attached to a worker still has a LOCAL
# `#{pane_current_path}`: its foreground process is attach-loop.sh/ssh. Running
# Treemux in the focus-machine tmux server would therefore browse the wrong
# filesystem. For an @rw-endpoint pane, dispatch Treemux into the endpoint's
# own worker-side tmux session instead. Treemux then derives its root from the
# worker pane, and every tree/editor action remains on that worker.
#
# Plain local panes retain Treemux's original behavior.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

pane_id="${TMUX_PANE:-$(tmux display-message -p -F '#{pane_id}' 2>/dev/null || true)}"

show_error() {
  local message="$1"
  message="${message//$'\n'/ }"
  if [ -n "$pane_id" ]; then
    tmux display-message -t "$pane_id" "rw: $message" 2>/dev/null || true
  fi
  rw_warn "$message"
}

run_local_treemux() {
  local toggle args
  toggle="$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh"
  args="$(tmux show-option -gqv @treemux-key-Tab 2>/dev/null || true)"

  if [ -z "$pane_id" ]; then
    show_error "Treemux must be invoked from a tmux pane."
    return 1
  fi
  if [ ! -x "$toggle" ] || [ -z "$args" ]; then
    show_error "local Treemux is not loaded; install its TPM plugin and reload tmux."
    return 1
  fi

  "$toggle" "$args" "$pane_id"
}

if [ -z "$pane_id" ]; then
  show_error "Treemux must be invoked from a tmux pane."
  exit 1
fi

endpoint_id="$(rw_pane_get "$pane_id" @rw-endpoint)"
if [ -z "$endpoint_id" ]; then
  run_local_treemux
  exit $?
fi

# A stale pane cache must not fall through to local Treemux: that would show
# a plausible-looking but incorrect focus-machine tree beside a remote shell.
endpoint_json="$(rw_read_endpoint "$endpoint_id" 2>/dev/null || true)"
if [ -z "$endpoint_json" ]; then
  show_error "remote endpoint $endpoint_id has no registry entry; run 'rw doctor' instead of opening a local tree."
  exit 1
fi

worker="$(printf '%s' "$endpoint_json" | jq -r '.worker // empty')"
if [ -z "$worker" ]; then
  show_error "remote endpoint $endpoint_id has no worker in its registry entry."
  exit 1
fi
session_name="$(rw_session_name "$endpoint_id")"

# Keep the remote program self-contained so Treemux's option lookup, pane
# lookup, Neovim process, watcher, and filesystem operations all occur on the
# worker. The session name is restricted by rw_session_name() to fixed text
# plus hexadecimal ids and is passed as a positional parameter regardless.
remote_output_file="$(mktemp "${TMPDIR:-/tmp}/rw-treemux.XXXXXX")"
trap 'rm -f "$remote_output_file"' EXIT
rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" \
  bash -s -- "$session_name" >"$remote_output_file" 2>&1 <<'REMOTE_TREEMUX'
set -uo pipefail

session_name="${1:?remote endpoint session name required}"
toggle="$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh"

if ! tmux has-session -t "=$session_name" 2>/dev/null; then
  printf 'endpoint tmux session %s is not running\n' "$session_name" >&2
  exit 20
fi
if [ ! -x "$toggle" ]; then
  printf 'Treemux is not installed on this worker; run make setup-headless there\n' >&2
  exit 21
fi

args="$(tmux show-option -gqv @treemux-key-Tab 2>/dev/null || true)"
if [ -z "$args" ]; then
  printf 'Treemux is installed but not loaded; reload the worker tmux config\n' >&2
  exit 22
fi

# A session target resolves to its current window's active pane. If that pane
# is already the Treemux sidebar, upstream toggle.sh follows its registration
# back to the main pane before closing it.
active_pane="$(tmux display-message -pt "=$session_name:" -F '#{pane_id}' 2>/dev/null || true)"
if [ -z "$active_pane" ]; then
  printf 'could not resolve the active pane in endpoint session %s\n' "$session_name" >&2
  exit 23
fi

"$toggle" "$args" "$active_pane"
REMOTE_TREEMUX
remote_status=$?
remote_output="$(cat "$remote_output_file")"
rm -f "$remote_output_file"
trap - EXIT

if [ "$remote_status" -ne 0 ]; then
  [ -n "$remote_output" ] || remote_output="remote Treemux failed on $worker (exit $remote_status)"
  show_error "$remote_output"
  exit "$remote_status"
fi

exit 0
