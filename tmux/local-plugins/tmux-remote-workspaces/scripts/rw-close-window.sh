#!/usr/bin/env bash
# Intentional window close for the `&` binding: tears down every remote
# endpoint owned by panes in this window (initial-plan.md, "Endpoint lifetime
# follows user intent" -- "An intentional local window close must close the
# remote endpoints owned by that window"), then kills the window itself.
#
# Reuses rw-close.sh per pane (--no-kill-pane, since kill-window below closes
# every pane anyway) so endpoint teardown has exactly one implementation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

window_id="${1:-}"
if [ -z "$window_id" ]; then
  window_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
fi
[ -n "$window_id" ] || rw_die "rw close-window: could not determine target window"

while IFS= read -r pane_id; do
  [ -n "$pane_id" ] || continue
  endpoint="$(rw_pane_get "$pane_id" @rw-endpoint)"
  [ -n "$endpoint" ] || continue
  # </dev/null: rw-close.sh reaches ssh, which otherwise inherits this
  # loop's stdin (the process-substitution pipe) and eats the remaining
  # pane-id lines -- only the first endpoint in the window ever closed.
  "$SCRIPT_DIR/rw-close.sh" --pane "$pane_id" --no-kill-pane --reason "window-close" </dev/null || true
done < <(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null)

tmux kill-window -t "$window_id" 2>/dev/null || true
