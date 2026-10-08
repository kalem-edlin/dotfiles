#!/usr/bin/env bash

set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/workspace-scale-test.XXXXXX")"
SOCKET="workspace-scale-test-$$"
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$ROOT"; }
trap cleanup EXIT

mkdir -p "$ROOT/state" "$ROOT/resurrect"
jq -n '{capture:{neovim_sessions:false,agent_sessions:false,treemux:true}}' >"$ROOT/config.json"
env TMUX_WORKSPACE_RESURRECT_STATE_DIR="$ROOT/state" TMUX_RESURRECT_DIR="$ROOT/resurrect" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$ROOT/config.json" \
  tmux -L "$SOCKET" -f /dev/null new-session -d -s scale 'exec sleep 60'
for index in $(seq 1 67); do
  tmux -L "$SOCKET" new-window -d -t scale -n "w$index" 'exec sleep 60'
done
first="$(tmux -L "$SOCKET" display-message -pt scale:0.0 -F '#{pane_id}')"
last="$(tmux -L "$SOCKET" display-message -pt scale:67.0 -F '#{pane_id}')"
args=$'quoted="value"\\path\nsecond\tline'
tmux -L "$SOCKET" set-option -g "@-treemux-registered-pane-${first}" "${last},${args}"
tmux -L "$SOCKET" run-shell "bash '$PLUGIN_DIR/scripts/save.sh'"
jq -e --arg args "$args" '
  (.panes | length) == 68 and .pane_coverage.expected_count == 68 and
  (.treemux | length) == 1 and .treemux[0].args == $args
' "$ROOT/resurrect/workspace_state.json" >/dev/null
printf '68-pane batched capture passed\n'
