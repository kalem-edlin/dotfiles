#!/usr/bin/env bash
# Backs `prefix c` (tmux.reset.conf; contract CS4, D21). A new window follows
# the host of the pane it was invoked from, like rw-split.sh does for splits:
#
#   remote pane (its attach loop runs: @remote-host, owned or off-owner)
#       -> a new window in the same session whose pane runs `rw switch` to the
#          same remote, in the source pane's live directory (rw_pane_dir): an
#          owned endpoint when that remote owns the directory (the `rw open`
#          path), a visit endpoint otherwise. If the remote cannot be reached
#          the window keeps a local shell.
#   local pane
#       -> `new-window -c "#{pane_current_path}"`, as the binding did before.
#
# The picker's own new-window action (prefix o, then w) follows the owner
# instead; it does not use this script.
#
# Usage: rw-new-window.sh [pane-id]   (default: $TMUX_PANE, else the active pane)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

pane_id="${1:-${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)}}"
[ -n "$pane_id" ] || { tmux new-window; exit 0; }

session_id="$(tmux display-message -pt "$pane_id" -F '#{session_id}' 2>/dev/null || true)"
current_path="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
target=()
[ -n "$session_id" ] && target=(-t "$session_id:")

endpoint="$(rw_pane_get "$pane_id" @rw-endpoint)"
worker="$(rw_pane_get "$pane_id" @remote-host)"

if [ -n "$endpoint" ] && [ -n "$worker" ]; then
  dir="$(rw_pane_dir "$pane_id" --live)"
  cmd="$(printf '%q switch --to %q --dir %q' "$SCRIPT_DIR/rw" "$worker" "$dir")"
  tmux new-window ${target[@]+"${target[@]}"} -c "$(rw_local_existing_dir "$dir")" \
    "$cmd; exec \${SHELL:-/bin/sh} -l"
  exit 0
fi

if [ -n "$current_path" ]; then
  tmux new-window ${target[@]+"${target[@]}"} -c "$current_path"
else
  tmux new-window ${target[@]+"${target[@]}"}
fi
