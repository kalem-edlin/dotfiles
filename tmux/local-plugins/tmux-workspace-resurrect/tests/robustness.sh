#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
NVIM_MODULE="$REPO_DIR/nvim/lua/tmux_workspace_resurrect.lua"
SAVE_SCRIPT="$PLUGIN_DIR/scripts/save.sh"
SOCKET="workspace-resurrect-test-$$"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/workspace-resurrect-test.XXXXXX")"
STOPPED_PID=""

cleanup() {
  if [ -n "$STOPPED_PID" ]; then
    kill -CONT "$STOPPED_PID" 2>/dev/null || true
  fi
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

for command in jq nvim tmux; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'missing test dependency: %s\n' "$command" >&2
    exit 1
  }
done

wait_for_owner() {
  local target="$1" owner="" attempt=0
  while [ "$attempt" -lt 20 ]; do
    owner="$(tmux -L "$SOCKET" show-option -pt "$target" -qv @workspace-nvim-owner-pid 2>/dev/null || true)"
    if [ -n "$owner" ]; then
      printf '%s\n' "$owner"
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/resurrect"
env TMUX_WORKSPACE_RESURRECT_STATE_DIR="$TEST_ROOT/state" \
  TMUX_RESURRECT_DIR="$TEST_ROOT/resurrect" \
  tmux -L "$SOCKET" -f /dev/null new-session -d -s test \
  "env -u NVIM nvim --clean '+lua dofile(\"$NVIM_MODULE\").setup()'"

owner="$(wait_for_owner test:0.0)"
server="$(tmux -L "$SOCKET" show-option -pt test:0.0 -qv @workspace-nvim-server)"
kill -0 "$owner"
[ -S "$server" ]

tmux -L "$SOCKET" new-window -d -t test -n nested \
  "env NVIM=/tmp/parent.sock nvim --clean '+lua dofile(\"$NVIM_MODULE\").setup()'"
sleep 0.3
[ -z "$(tmux -L "$SOCKET" show-option -pt test:nested -qv @workspace-nvim-owner-pid 2>/dev/null || true)" ]

tmux -L "$SOCKET" send-keys -t test:0.0 Escape ':doautocmd VimLeavePre' Enter
sleep 0.3
[ -z "$(tmux -L "$SOCKET" show-option -pt test:0.0 -qv @workspace-nvim-owner-pid 2>/dev/null || true)" ]

tmux -L "$SOCKET" new-window -d -t test -n timeout \
  "env -u NVIM nvim --clean '+lua dofile(\"$NVIM_MODULE\").setup()'"
STOPPED_PID="$(wait_for_owner test:timeout)"
kill -STOP "$STOPPED_PID"

started="$(date +%s)"
tmux -L "$SOCKET" run-shell \
  "TMUX_WORKSPACE_RESURRECT_STATE_DIR='$TEST_ROOT/state' TMUX_RESURRECT_DIR='$TEST_ROOT/resurrect' bash '$SAVE_SCRIPT'"
duration=$(($(date +%s) - started))

[ "$duration" -le 8 ]
[ -z "$(tmux -L "$SOCKET" show-option -pt test:timeout -qv @workspace-nvim-server 2>/dev/null || true)" ]
jq -e '.version == 1 and (.panes | length) == 3' \
  "$TEST_ROOT/resurrect/workspace_state.json" >/dev/null
grep -q 'Neovim RPC timed out after 3s' \
  "$TEST_ROOT/state/workspace-resurrect.log"

# A transport-level success is not a persisted editor snapshot. A save()
# false return must fail the save without replacing the prior sidecar.
tmux -L "$SOCKET" new-window -d -t test -n refusing \
  "env -u NVIM nvim --clean '+lua local m=dofile(\"$NVIM_MODULE\"); m.setup(); package.loaded.tmux_workspace_resurrect={save=function() return false end}'"
wait_for_owner test:refusing >/dev/null
server_context="$(tmux -L "$SOCKET" display-message -p '#{socket_path},#{pid},0')"
before_sidecar="$(cksum "$TEST_ROOT/resurrect/workspace_state.json")"
if env TMUX="$server_context" TMUX_WORKSPACE_RESURRECT_STATE_DIR="$TEST_ROOT/state" \
  TMUX_RESURRECT_DIR="$TEST_ROOT/resurrect" bash "$SAVE_SCRIPT" >"$TEST_ROOT/refused.log" 2>&1; then
  printf 'save accepted a false Neovim persistence acknowledgement\n' >&2
  exit 1
fi
[ "$(cksum "$TEST_ROOT/resurrect/workspace_state.json")" = "$before_sidecar" ]
grep -q 'Neovim could not persist buffers' "$TEST_ROOT/refused.log"

printf 'workspace-resurrect timeout and false-acknowledgement tests passed (timeout stage %ss)\n' "$duration"
