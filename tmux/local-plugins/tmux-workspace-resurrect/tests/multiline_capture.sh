#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/workspace-multiline-test.XXXXXX")"
SOCKET="workspace-multiline-test-$$"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

for command in jq python3 tmux; do
  command -v "$command" >/dev/null 2>&1 || exit 77
done

mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/resurrect"
jq -n '{capture:{neovim_sessions:false,agent_sessions:false,treemux:true},
  neovim_rpc_timeout_seconds:1}' >"$TEST_ROOT/config.json"

# Seed every path into the server environment before its first pane exists.
# No login shell or user startup file participates in this test.
env \
  TMUX_WORKSPACE_RESURRECT_STATE_DIR="$TEST_ROOT/state" \
  TMUX_RESURRECT_DIR="$TEST_ROOT/resurrect" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$TEST_ROOT/config.json" \
  tmux -L "$SOCKET" -f /dev/null new-session -d -s multiline 'sh -c "exec sleep 60"'
tmux -L "$SOCKET" split-window -d -t multiline:0 'sh -c "exec sleep 60"'

command_one=$'printf "first line\\n"\nprintf "second | line\\tvalue\\n"'
buffer_one=$'echo alpha\necho "beta | gamma"\nprintf "tab\\there\\n"'
command_two=$'one\ntwo\nthree'
tmux -L "$SOCKET" set-option -pt multiline:0.0 @workspace-last-command "$command_one"
tmux -L "$SOCKET" set-option -pt multiline:0.0 @workspace-pending-buffer "$buffer_one"
tmux -L "$SOCKET" set-option -pt multiline:0.0 @workspace-pending-cursor 17
tmux -L "$SOCKET" set-option -pt multiline:0.1 @workspace-last-command "$command_two"
main_pane="$(tmux -L "$SOCKET" display-message -pt multiline:0.0 -F '#{pane_id}')"
sidebar_pane="$(tmux -L "$SOCKET" display-message -pt multiline:0.1 -F '#{pane_id}')"
treemux_args=$'path="quoted"\\segment\nsecond\tfield'
tmux -L "$SOCKET" set-option -g "@-treemux-registered-pane-${main_pane}" "${sidebar_pane},${treemux_args}"

tmux -L "$SOCKET" run-shell "bash '$PLUGIN_DIR/scripts/save.sh'"
sidecar="$TEST_ROOT/resurrect/workspace_state.json"
jq -e --arg command "$command_one" --arg buffer "$buffer_one" --arg second "$command_two" \
  --arg treemux_args "$treemux_args" '
  (.panes | length) == 2 and
  .pane_coverage == {expected_count:2,captured_count:2,complete:true,logical_ids_unique:true} and
  ([.panes[].logical_id] | unique | length) == 2 and
  (.panes[] | select(.logical_id == "multiline:0.0") |
    .last_command == $command and .pending_buffer == $buffer and
    .selected_command == $buffer and .pending_cursor == 17) and
  (.panes[] | select(.logical_id == "multiline:0.1") |
    .last_command == $second and .selected_command == $second) and
  (.treemux == [{main_logical_id:"multiline:0.0",sidebar_logical_id:"multiline:0.1",args:$treemux_args}])
' "$sidecar" >/dev/null

printf 'multiline pane capture and complete logical-id coverage passed\n'
