#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
RESTORE_SCRIPT="$PLUGIN_DIR/scripts/restore.sh"
ZSH_INTEGRATION="$PLUGIN_DIR/../../../zsh/.zsh/tmux-workspace-resurrect.zsh"
SOCKET="workspace-restore-autolaunch-test-$$"
TEST_ROOT="$(mktemp -d /tmp/workspace-restore-autolaunch-test.XXXXXX)"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

for command in jq python3 tmux zsh; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'missing test dependency: %s\n' "$command" >&2
    exit 1
  }
done

fail() {
  printf 'restore autolaunch integration failed: %s\n' "$*" >&2
  exit 1
}

STATE_DIR="$TEST_ROOT/state"
RESURRECT_DIR="$TEST_ROOT/resurrect"
BIN_DIR="$TEST_ROOT/bin"
ZDOTDIR_CLEAN="$TEST_ROOT/zdotdir"
XDG_CONFIG_HOME="$TEST_ROOT/xdg-config"
XDG_DATA_HOME="$TEST_ROOT/xdg-data"
XDG_STATE_HOME="$TEST_ROOT/xdg-state"
CONFIG_FILE="$TEST_ROOT/config.json"
SIDECAR="$RESURRECT_DIR/workspace_state.json"
INVOCATIONS="$TEST_ROOT/invocations.tsv"
RESTORE_RESULT="$TEST_ROOT/restore-result"
mkdir -p "$STATE_DIR" "$RESURRECT_DIR" "$BIN_DIR" "$ZDOTDIR_CLEAN" \
  "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
: >"$INVOCATIONS"

# All allowlisted programs resolve to this harmless logger. It sleeps just
# long enough for restore to observe a non-shell live process, but cannot
# contact an agent service or open the user's editor configuration.
apply_stub="$BIN_DIR/workspace-test-stub"
# shellcheck disable=SC2016 # These lines are the literal body of the stub.
printf '%s\n' \
  '#!/bin/zsh -f' \
  'name=${0:t}' \
  'now=$(python3 -c '\''import time; print(time.time_ns() // 1000000)'\'')' \
  'printf '\''%s\t%s\t%s\n'\'' "$now" "$name" "$*" >>"$WORKSPACE_TEST_INVOCATIONS"' \
  'sleep 0.35' >"$apply_stub"
chmod +x "$apply_stub"
for name in claudef pif codexf nvim; do
  ln -s "$apply_stub" "$BIN_DIR/$name"
done

jq -n '{restore_timeout_seconds:20,restore_pane_timeout_seconds:3,
  restore_mode:"whitelist",
  restore_whitelist:{names:["claudef","pif","codexf","nvim"],delay_ms:500},
  capture:{shell_buffers:true,agent_sessions:true,neovim_sessions:true,treemux:false}}' \
  >"$CONFIG_FILE"

env PATH="$BIN_DIR:$PATH" ZDOTDIR="$ZDOTDIR_CLEAN" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
  NVIM_APPNAME=workspace-test-no-user-config WORKSPACE_TEST_INVOCATIONS="$INVOCATIONS" \
  TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
  TMUX_RESURRECT_DIR="$RESURRECT_DIR" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" \
  tmux -L "$SOCKET" new-session -d -s claude -c "$TEST_ROOT" 'zsh -f -i'

server_pid="$(tmux -L "$SOCKET" display-message -p '#{pid}')"
socket_path="$(tmux -L "$SOCKET" display-message -p '#{socket_path}')"
SERVER_TMUX="$socket_path,$server_pid,0"

new_test_pane() {
  local name="$1"
  env PATH="$BIN_DIR:$PATH" ZDOTDIR="$ZDOTDIR_CLEAN" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    NVIM_APPNAME=workspace-test-no-user-config WORKSPACE_TEST_INVOCATIONS="$INVOCATIONS" \
    TMUX="$SERVER_TMUX" tmux new-session -d -s "$name" -c "$TEST_ROOT" 'zsh -f -i'
}

for session in pi codex codex-pending codex-last nvim pending unknown exited live editing; do
  new_test_pane "$session"
done

pane_for() {
  tmux -L "$SOCKET" display-message -p -t "$1:0.0" '#{pane_id}'
}

logical_for() {
  tmux -L "$SOCKET" display-message -p -t "$1:0.0" \
    '#{session_name}:#{window_index}.#{pane_index}'
}

wait_for_shell() {
  local pane="$1" attempt=0
  while [ "$attempt" -lt 50 ]; do
    if [ "$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{pane_current_command}')" = zsh ] &&
      [ "$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{bracket_paste_flag}')" = 1 ]; then
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fail "clean zsh did not become ready in $pane"
}

install_dump_widget() {
  local session="$1" pane prefix setup attempt=0
  pane="$(pane_for "$session")"
  prefix="$TEST_ROOT/$session"
  setup="path=('$BIN_DIR' \$path); rehash; WORKSPACE_TEST_DUMP='$prefix'; dump_workspace_buffer() { print -rn -- \"\$BUFFER\" >\"\${WORKSPACE_TEST_DUMP}.buffer\"; print -rn -- \"\$CURSOR\" >\"\${WORKSPACE_TEST_DUMP}.cursor\"; }; zle -N dump_workspace_buffer; bindkey '^X^D' dump_workspace_buffer; source '$ZSH_INTEGRATION'; stub_ok=1; for stub in claudef pif codexf nvim; do [[ \$(whence -p \$stub) == '$BIN_DIR/'\$stub ]] || stub_ok=0; done; (( stub_ok )) && print ready >'$prefix.ready'"
  tmux -L "$SOCKET" send-keys -t "$pane" -l "$setup"
  tmux -L "$SOCKET" send-keys -t "$pane" Enter
  while [ "$attempt" -lt 30 ] && [ ! -f "$prefix.ready" ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -f "$prefix.ready" ] || fail "stub PATH verification failed in $session"
}

for session in claude pi codex codex-pending codex-last nvim pending unknown exited live editing; do
  wait_for_shell "$(pane_for "$session")"
  install_dump_widget "$session"
done

CLAUDE_ID='11111111-1111-4111-8111-111111111111'
PI_ID='22222222-2222-4222-8222-222222222222'
CODEX_ID='33333333-3333-4333-8333-333333333333'
EXITED_ID='44444444-4444-4444-8444-444444444444'
EDITING_ID='55555555-5555-4555-8555-555555555555'
NVIM_SESSION="$TEST_ROOT/nvim sessions/exact Session.vim"
mkdir -p "$(dirname "$NVIM_SESSION")"
printf 'integration test session\n' >"$NVIM_SESSION"
PENDING=$'claudef --resume MUST-NOT-RUN\nprintf "still pending"\n\n'
PENDING_CURSOR=13
UNKNOWN='printf "queued unknown command"'

record() {
  local session="$1" current="$2" source="$3" selected="$4" pending="$5" cursor="$6"
  local agent_json="${7:-null}" nvim_json="${8:-null}"
  jq -nc --arg pane_id "$(pane_for "$session")" \
    --arg logical_id "$(logical_for "$session")" --arg current_command "$current" \
    --arg selected_source "$source" --arg selected_command "$selected" \
    --arg pending_buffer "$pending" --argjson pending_cursor "$cursor" \
    --argjson agent "$agent_json" --argjson neovim "$nvim_json" \
    '{pane_id:$pane_id,logical_id:$logical_id,current_command:$current_command,
      selected_source:$selected_source,selected_command:$selected_command,
      pending_buffer:$pending_buffer,pending_cursor:$pending_cursor,
      agent:$agent,neovim:$neovim}'
}

panes_json="$TEST_ROOT/panes.jsonl"
: >"$panes_json"
{
  record claude claudef claude-session "claudef --resume $CLAUDE_ID" '' 0 \
    "$(jq -nc --arg id "$CLAUDE_ID" '{tool:"claude",session_id:$id}')"
  record pi pif pi-session "pif --session $PI_ID" '' 0 \
    "$(jq -nc --arg id "$PI_ID" '{tool:"pi",session_id:$id}')"
  record codex codexf codex-session "codexf resume $CODEX_ID" '' 0 \
    "$(jq -nc --arg id "$CODEX_ID" '{tool:"codex",session_id:$id}')"
  record codex-pending zsh pending-buffer 'codexf resume pending-MUST-NOT-RUN' 'codexf resume pending-MUST-NOT-RUN' 9
  record codex-last zsh last-command 'cd /tmp && codex resume last-MUST-NOT-RUN' '' 0
  record nvim nvim neovim-session "nvim -S '$NVIM_SESSION'" '' 0 null \
    "$(jq -nc --arg path "$NVIM_SESSION" '{session_file:$path}')"
  record pending zsh pending-buffer "$PENDING" "$PENDING" "$PENDING_CURSOR"
  record unknown zsh last-command "$UNKNOWN" '' 0
  record exited zsh claude-session "claudef --resume $EXITED_ID" '' 0 \
    "$(jq -nc --arg id "$EXITED_ID" '{tool:"claude",session_id:$id}')"
  record live claudef claude-session 'claudef --resume live-must-not-run' '' 0 \
    "$(jq -nc '{tool:"claude",session_id:"live-must-not-run"}')"
  record editing claudef claude-session "claudef --resume $EDITING_ID" '' 0 \
    "$(jq -nc --arg id "$EDITING_ID" '{tool:"claude",session_id:$id}')"
} >>"$panes_json"

jq -s --arg saved_at 'integration-test' \
  '{version:1,resurrect_snapshot:"last",saved_at:$saved_at,panes:.,treemux:[]}' \
  "$panes_json" >"$SIDECAR"

# A non-shell foreground process represents an agent that survived restore.
# The restore must not paste into or relaunch this pane.
tmux -L "$SOCKET" send-keys -t "$(pane_for live)" -l 'sleep 30'
tmux -L "$SOCKET" send-keys -t "$(pane_for live)" Enter
sleep 0.1
[ "$(tmux -L "$SOCKET" display-message -p -t "$(pane_for live)" '#{pane_current_command}')" != zsh ] ||
  fail 'live-pane fixture did not start its foreground process'

# The shell has user input newer than the snapshot. Even though the saved
# record itself is launch-eligible, restore must neither append nor press
# Enter in this live editable buffer.
LIVE_EDIT='echo user-is-editing'
tmux -L "$SOCKET" set-option -p -t "$(pane_for editing)" @workspace-pending-buffer "$LIVE_EDIT"
tmux -L "$SOCKET" send-keys -t "$(pane_for editing)" -l "$LIVE_EDIT"

run_restore() {
  env PATH="$BIN_DIR:$PATH" WORKSPACE_TEST_INVOCATIONS="$INVOCATIONS" \
    TMUX="$SERVER_TMUX" TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
    TMUX_RESURRECT_DIR="$RESURRECT_DIR" TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" \
    TMUX_WORKSPACE_RESTORE_RESULT_FILE="$RESTORE_RESULT" \
    bash "$RESTORE_SCRIPT"
}

run_restore
[ "$(cat "$RESTORE_RESULT" 2>/dev/null || true)" = success ] ||
  fail 'intentional live-pane skips incorrectly failed the restore result guard'

attempt=0
while [ "$attempt" -lt 80 ] && [ "$(wc -l <"$INVOCATIONS" | tr -d ' ')" -lt 3 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$(wc -l <"$INVOCATIONS" | tr -d ' ')" = 3 ] ||
  fail "expected exactly three allowlisted launches; observed: $(tr '\n' ';' <"$INVOCATIONS"); nvim pane: $(tmux -L "$SOCKET" capture-pane -p -t "$(pane_for nvim)" -S -5 | tr '\n' '|')"

grep -Fq $'claudef\t--resume '"$CLAUDE_ID" "$INVOCATIONS" || fail 'Claude exact resume ID was not launched'
grep -Fq $'pif\t--session '"$PI_ID" "$INVOCATIONS" || fail 'Pi exact session ID was not launched'
! grep -Fq 'codexf' "$INVOCATIONS" || fail 'excluded Codex was launched'
grep -Fq $'nvim\t-S '"$NVIM_SESSION" "$INVOCATIONS" || fail 'Neovim exact session path was not launched'
! grep -Fq 'MUST-NOT-RUN' "$INVOCATIONS" || fail 'pending allowlisted text executed'
! grep -Fq "$EXITED_ID" "$INVOCATIONS" || fail 'exited agent was incorrectly relaunched'
! grep -Fq 'live-must-not-run' "$INVOCATIONS" || fail 'already-running pane was relaunched'
! grep -Fq "$EDITING_ID" "$INVOCATIONS" || fail 'live shell input was entered to launch an agent'

# Launches are serialized in sidecar order with at least a 500 ms start gap.
awk -F '\t' 'NR > 1 && $1 - previous < 450 { exit 1 } { previous=$1 }' "$INVOCATIONS" ||
  fail 'allowlisted launches were not staggered by 500 ms'

dump_and_assert() {
  local session="$1" expected="$2" cursor="$3" pane expected_file
  pane="$(pane_for "$session")"
  rm -f "$TEST_ROOT/$session.buffer" "$TEST_ROOT/$session.cursor"
  tmux -L "$SOCKET" send-keys -t "$pane" C-x C-d
  attempt=0
  while [ "$attempt" -lt 30 ] && [ ! -f "$TEST_ROOT/$session.buffer" ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -f "$TEST_ROOT/$session.buffer" ] || fail "ZLE dump widget did not run for $session: $(tmux -L "$SOCKET" capture-pane -p -t "$pane" -S -5 | tr '\n' '|')"
  expected_file="$TEST_ROOT/$session.expected"
  printf '%s' "$expected" >"$expected_file"
  cmp -s "$expected_file" "$TEST_ROOT/$session.buffer" || fail "$session buffer changed byte-for-byte"
  [ "$(cat "$TEST_ROOT/$session.cursor")" = "$cursor" ] ||
    fail "$session cursor was not restored: expected $cursor, observed $(cat "$TEST_ROOT/$session.cursor")"
}

for session in codex codex-pending codex-last; do
  pane="$(pane_for "$session")"
  [ -z "$(tmux -L "$SOCKET" show-option -pqv -t "$pane" @workspace-pending-buffer)" ] ||
    fail "excluded Codex command was queued in $session"
  ! tmux -L "$SOCKET" capture-pane -p -t "$pane" -S -2 | grep -q 'resume' ||
    fail "excluded Codex command was pasted in $session"
done
dump_and_assert pending "$PENDING" "$PENDING_CURSOR"
dump_and_assert unknown "$UNKNOWN" "${#UNKNOWN}"
exited_command="claudef --resume $EXITED_ID"
dump_and_assert exited "$exited_command" "${#exited_command}"
dump_and_assert editing "$LIVE_EDIT" "${#LIVE_EDIT}"

# Re-running restore against the same panes must not execute the same restore
# keys again or append duplicate text to a pane's editable command line.
run_restore
sleep 2
[ "$(wc -l <"$INVOCATIONS" | tr -d ' ')" = 3 ] || fail 're-restore launched a duplicate command'
dump_and_assert pending "$PENDING" "$PENDING_CURSOR"
dump_and_assert unknown "$UNKNOWN" "${#UNKNOWN}"

printf 'restore autolaunch integration passed: exact IDs/path, stagger, pending bytes/cursor, queue policy, live skip, and rerestore dedupe\n'
