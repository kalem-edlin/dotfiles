#!/usr/bin/env bash
# Reconcile display-only pane metadata with actual attach-loop ownership.
# Endpoint intent may outlive or precede attachment; host/directory chips and
# workspace-resurrect skipping must only activate while attach-loop.sh really
# owns the local pane's process tree.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

processes="$(ps axo pid=,ppid=,command= 2>/dev/null || true)"
while IFS= read -r pane_id; do
  [ -n "$pane_id" ] || continue
  pane_pid="$(tmux display-message -pt "$pane_id" -F '#{pane_pid}' 2>/dev/null || true)"
  worker="$(rw_pane_get "$pane_id" @rw-worker)"
  if [ -n "$pane_pid" ] && [ -n "$worker" ] &&
    printf '%s\n' "$processes" |
      rw_ps_tree_matches '(^|/)attach-loop\.sh([[:space:]]|$)' "$pane_pid"; then
    rw_pane_set "$pane_id" @remote-host "$worker"
    rw_pane_set "$pane_id" @workspace-resurrect-skip "1"
  else
    rw_pane_unset "$pane_id" @remote-host
    rw_pane_unset "$pane_id" @workspace-resurrect-skip
  fi
done < <(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)
