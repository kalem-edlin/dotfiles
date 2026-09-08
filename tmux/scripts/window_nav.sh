#!/usr/bin/env bash
# Navigate windows while turning boundary errors into dismissible dialogs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
direction="${1:?window_nav: next or previous required}"
pane_id="${2:?window_nav: pane id required}"
session_id="$(tmux display-message -pt "$pane_id" -F '#{session_id}' 2>/dev/null || true)"

case "$direction" in
  next) command_name="next-window"; message="No next window." ;;
  previous) command_name="previous-window"; message="No previous window." ;;
  *) printf 'window_nav: unknown direction: %s\n' "$direction" >&2; exit 64 ;;
esac

if [ -n "$session_id" ] && tmux "$command_name" -t "$session_id" 2>/dev/null; then
  exit 0
fi

"$SCRIPT_DIR/dialog.sh" --pane "$pane_id" --title "Tmux navigation" -- "$message"
