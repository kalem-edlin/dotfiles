#!/usr/bin/env bash

set -euo pipefail

# When symlinked as the isolated fake tmux-resurrect plugin's save script,
# publish a structurally valid but agent-error sidecar for the real verified
# save wrapper test below.
if [ "${WORKSPACE_TEST_FAKE_PLUGIN:-}" = "1" ]; then
  resurrect_dir="${TMUX_RESURRECT_OVERRIDE_DIR:-$(tmux show-option -gqv @resurrect-dir)}"
  snapshot="${TMUX_RESURRECT_OVERRIDE_FILE_PATH:-$resurrect_dir/fixture.txt}"
  printf 'pane\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\nstate\t0\t0\n' >"$snapshot"
  ln -sfn "$(basename "$snapshot")" "$resurrect_dir/last"
  temp_sidecar="$(mktemp "$resurrect_dir/.workspace-state.XXXXXX")"
  # Match the authoritative synthetic pane line above. Coverage is checked
  # against the snapshot identities, not the later live server.
  panes='[{"pane_id":"%0","logical_id":"0:0.0"}]'
  pane_count="$(jq 'length' <<<"$panes")"
  if [ "${WORKSPACE_TEST_FAKE_AGENT_ERRORS:-1}" = "1" ]; then
    agent_errors='[{"logical_id":"0:0.0","error":"missing hook"}]'
  else
    agent_errors='[]'
  fi
  jq -n --argjson panes "$panes" --argjson pane_count "$pane_count" \
    --argjson agent_errors "$agent_errors" --arg snapshot "$(basename "$snapshot")" \
    '{version:1,resurrect_snapshot:$snapshot,saved_at:"integration-test",
      panes:$panes,
      pane_coverage:{expected_count:$pane_count,captured_count:$pane_count,
        complete:true,logical_ids_unique:true},
      treemux:[],agent_capture_errors:$agent_errors}' >"$temp_sidecar"
  mv "$temp_sidecar" "$resurrect_dir/workspace_state.json"
  exit 0
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SAVE_SCRIPT="$PLUGIN_DIR/scripts/save.sh"
RESTORE_SCRIPT="$PLUGIN_DIR/scripts/restore.sh"
RECORDER="$PLUGIN_DIR/scripts/record-agent-session.sh"
COMMAND_HELPER="$PLUGIN_DIR/scripts/agent_command.py"
SOCKET="workspace-agent-resume-test-$$"
SOCKET_TWO="workspace-agent-resume-test-two-$$"
TEST_ROOT="$(mktemp -d /tmp/workspace-agent-resume-test.XXXXXX)"
STATE_DIR="$TEST_ROOT/state"
RESURRECT_DIR="$TEST_ROOT/resurrect"
CONFIG_FILE="$TEST_ROOT/config.json"
SIDECAR="$RESURRECT_DIR/workspace_state.json"
SERVER_TMUX=""

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  tmux -L "$SOCKET_TWO" kill-server 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

for command in jq python3 tmux zsh; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'missing test dependency: %s\n' "$command" >&2
    exit 1
  }
done

mkdir -p "$STATE_DIR" "$RESURRECT_DIR"
jq -n '{restore_timeout_seconds:10, restore_pane_timeout_seconds:2,
  neovim_rpc_timeout_seconds:1, capture:{shell_buffers:true,
  agent_sessions:true, neovim_sessions:false, treemux:false}}' >"$CONFIG_FILE"

fail() {
  printf 'agent resume integration failed: %s\n' "$*" >&2
  exit 1
}

new_pane() {
  local session="$1" launcher="$2" pane
  env TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
    TMUX_RESURRECT_DIR="$RESURRECT_DIR" \
    TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" \
    tmux -L "$SOCKET" new-session -d -s "$session" -c "$TEST_ROOT" 'sleep 600'
  pane="$(tmux -L "$SOCKET" display-message -p -t "$session:0.0" '#{pane_id}')"
  tmux -L "$SOCKET" set-option -p -t "$pane" @workspace-last-command "$launcher"
  printf '%s\n' "$pane"
}

record_agent() {
  local pane="$1" tool="$2" session_id="$3" cwd input
  cwd="$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{pane_current_path}')"
  input="$(jq -nc --arg session_id "$session_id" --arg cwd "$cwd" \
    --arg model 'integration-test-model' '{session_id:$session_id,cwd:$cwd,model:$model}')"
  # Invoke the production recorder with the private server identity. This
  # avoids asynchronous run-shell timing in the test harness.
  printf '%s' "$input" | env TMUX="$SERVER_TMUX" TMUX_PANE="$pane" \
    TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" "$RECORDER" "$tool"
}

assert_sidecar_command() {
  local pane="$1" expected="$2" source="$3" record
  record="$(jq -ce --arg pane "$pane" '.panes[] | select(.pane_id==$pane)' "$SIDECAR")" ||
    fail "missing sidecar pane $pane"
  [ "$(jq -r '.selected_command' <<<"$record")" = "$expected" ] ||
    fail "wrong selected command for $pane"
  [ "$(jq -r '.selected_source' <<<"$record")" = "$source" ] ||
    fail "wrong selected source for $pane"
}

assert_restore_buffer() {
  local pane="$1" expected="$2" captured attempt
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    captured="$(tmux -L "$SOCKET" capture-pane -p -t "$pane" -S -4 2>/dev/null | tr -d '\n\r' || true)"
    if [[ "$captured" == *"$expected"* ]]; then
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fail "restore did not place expected literal command in $pane"
}

start_clean_shell() {
  local pane="$1" attempt=0
  # A clean interactive zsh accepts the pasted command into its editable
  # buffer. Nothing is entered; capture-pane verifies it without launching
  # any agent application.
  tmux -L "$SOCKET" respawn-pane -k -t "$pane" 'zsh -f -i'
  # Clean zsh omits the production line-init hook that clears old pane input.
  tmux -L "$SOCKET" set-option -p -t "$pane" @workspace-pending-buffer ''
  tmux -L "$SOCKET" set-option -p -t "$pane" @workspace-pending-cursor 0
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if [ "$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)" = zsh ] &&
      [ "$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{bracket_paste_flag}' 2>/dev/null || true)" = 1 ]; then
      break
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ "$attempt" -lt 30 ] || fail "zsh/bracketed paste did not become ready in $pane"
}

# Production recorder -> save cases exercise focus and canonical launchers
# for Claude and Pi, with old Codex metadata retained as an exclusion fixture. Resume IDs are intentionally
# harmless unique test values, not real user sessions.
claudef_pane="$(new_pane claude-f 'claudef --model test-model --resume old-session')"
claude_pane="$(new_pane claude 'claude --model test-model --continue')"
pif_pane="$(new_pane pi-f 'pif --model test-model --session old-session')"
pi_pane="$(new_pane pi 'pi --model test-model --continue')"
codexf_pane="$(new_pane codex-f 'codexf --dangerously-bypass-approvals-and-sandbox --model test-model resume old-session')"
codex_pane="$(new_pane codex 'codex --model test-model resume old-session')"
stale_pane="$(new_pane stale-identity 'claudef --resume old-session')"
missing_pane="$(new_pane missing-record 'pif --session old-session')"
pending_pane="$(new_pane pending-buffer 'codexf old-session')"
server_pid="$(tmux -L "$SOCKET" display-message -p '#{pid}')"
socket_path="$(tmux -L "$SOCKET" display-message -p '#{socket_path}')"
SERVER_TMUX="$socket_path,$server_pid,0"

record_agent "$claudef_pane" claude 11111111-1111-4111-8111-111111111111
record_agent "$claude_pane" claude 22222222-2222-4222-8222-222222222222
record_agent "$pif_pane" pi 33333333-3333-4333-8333-333333333333
record_agent "$pi_pane" pi 44444444-4444-4444-8444-444444444444
record_agent "$stale_pane" claude 77777777-7777-4777-8777-777777777777

# Move a record to the legacy shared location and give it another pane's
# identity. Legacy fallback must reject it even though pane number, tool,
# session ID, and cwd otherwise match.
server_start="$(tmux -L "$SOCKET" display-message -p '#{start_time}')"
stale_file="$STATE_DIR/agents/server-$server_pid-$server_start/pane-${stale_pane#%}.json"
legacy_stale_file="$STATE_DIR/agents/pane-${stale_pane#%}.json"
jq '.pane_identity = "1:1:1"' "$stale_file" >"$legacy_stale_file"
rm "$stale_file"

# A second server deliberately reuses pane %0 and the same state root. Its
# hook record must neither overwrite nor be readable as the first server's.
env TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
  TMUX_RESURRECT_DIR="$RESURRECT_DIR" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" \
  tmux -L "$SOCKET_TWO" new-session -d -s collision -c "$TEST_ROOT" 'sleep 600'
other_pane="$(tmux -L "$SOCKET_TWO" display-message -p -t collision:0.0 '#{pane_id}')"
[ "$other_pane" = "$claudef_pane" ] || fail 'test servers did not reuse a pane ID'
other_pid="$(tmux -L "$SOCKET_TWO" display-message -p '#{pid}')"
other_start="$(tmux -L "$SOCKET_TWO" display-message -p '#{start_time}')"
other_socket_path="$(tmux -L "$SOCKET_TWO" display-message -p '#{socket_path}')"
other_tmux="$other_socket_path,$other_pid,0"
other_input="$(jq -nc --arg session_id '99999999-9999-4999-8999-999999999999' \
  --arg cwd "$TEST_ROOT" '{session_id:$session_id,cwd:$cwd}')"

# Omit the state-dir variable to simulate a hook that lost environment
# propagation. The recorder must recover the isolated setting from this
# server, never fall back to the user's production metadata directory.
printf '%s' "$other_input" | env -u TMUX_WORKSPACE_RESURRECT_STATE_DIR \
  TMUX="$other_tmux" TMUX_PANE="$other_pane" "$RECORDER" claude
main_file="$STATE_DIR/agents/server-$server_pid-$server_start/pane-${claudef_pane#%}.json"
other_file="$STATE_DIR/agents/server-$other_pid-$other_start/pane-${other_pane#%}.json"
[ -f "$main_file" ] && [ -f "$other_file" ] || fail 'server-scoped hook records were not created'
[ "$(jq -r .session_id "$main_file")" = 11111111-1111-4111-8111-111111111111 ] ||
  fail 'second server overwrote the first server record'
[ "$(jq -r .session_id "$other_file")" = 99999999-9999-4999-8999-999999999999 ] ||
  fail 'second server record crossed into another namespace'
common_script="$PLUGIN_DIR/scripts/common.sh"
resolved_main="$(env TMUX="$SERVER_TMUX" TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
  bash -c 'source "$1"; workspace_pane_state_file "$2"' _ "$common_script" "$claudef_pane")"
resolved_other="$(env TMUX="$other_tmux" TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
  bash -c 'source "$1"; workspace_pane_state_file "$2"' _ "$common_script" "$other_pane")"
[ "$resolved_main" = "$main_file" ] && [ "$resolved_other" = "$other_file" ] ||
  fail 'server-scoped reads crossed between reused pane IDs'

tmux -L "$SOCKET" set-option -p -t "$pending_pane" @workspace-pending-buffer 'echo pending-buffer-survives'
tmux -L "$SOCKET" set-option -p -t "$pending_pane" @workspace-pending-cursor 8

env TMUX="$SERVER_TMUX" TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
  TMUX_RESURRECT_DIR="$RESURRECT_DIR" TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" \
  bash "$SAVE_SCRIPT"

expected_claudef="$(python3 "$COMMAND_HELPER" resume claude 11111111-1111-4111-8111-111111111111 'claudef --model test-model --resume old-session')"
expected_claude="$(python3 "$COMMAND_HELPER" resume claude 22222222-2222-4222-8222-222222222222 'claude --model test-model --continue')"
expected_pif="$(python3 "$COMMAND_HELPER" resume pi 33333333-3333-4333-8333-333333333333 'pif --model test-model --session old-session')"
expected_pi="$(python3 "$COMMAND_HELPER" resume pi 44444444-4444-4444-8444-444444444444 'pi --model test-model --continue')"
assert_sidecar_command "$claudef_pane" "$expected_claudef" claude-session
assert_sidecar_command "$claude_pane" "$expected_claude" claude-session
assert_sidecar_command "$pif_pane" "$expected_pif" pi-session
assert_sidecar_command "$pi_pane" "$expected_pi" pi-session
assert_sidecar_command "$codexf_pane" '' ignored-agent
assert_sidecar_command "$codex_pane" '' ignored-agent
assert_sidecar_command "$stale_pane" '' agent-session-unavailable
assert_sidecar_command "$missing_pane" '' agent-session-unavailable
assert_sidecar_command "$pending_pane" 'echo pending-buffer-survives' pending-buffer
[ "$(jq -r --arg pane "$pending_pane" '.panes[]|select(.pane_id==$pane)|.pending_cursor' "$SIDECAR")" = 8 ] ||
  fail 'pending buffer cursor was not preserved'
[ "$(jq '.agent_capture_errors|length' "$SIDECAR")" = 2 ] ||
  fail 'expected stale and missing agent hook records to be reported'

# Recreate only these disposable test panes as empty shells, then queue the
# saved commands. Restore never receives Enter and no application is started.
# Simulate an older snapshot with an exact Codex resume and a raw last command.
jq --arg pane "$codexf_pane" --arg raw "$codex_pane" '
  (.panes[] | select(.pane_id == $pane)) |=
    (.selected_source = "codex-session" |
     .selected_command = "codexf --dangerously-bypass-approvals-and-sandbox resume old-session" |
     .agent = {tool:"codex",session_id:"old-session"}) |
  (.panes[] | select(.pane_id == $raw)) |=
    (.selected_source = "last-command" | .selected_command = "codex resume old-session")' \
  "$SIDECAR" >"$TEST_ROOT/legacy-sidecar.json"
mv "$TEST_ROOT/legacy-sidecar.json" "$SIDECAR"
for pane in "$claudef_pane" "$claude_pane" "$pif_pane" "$pi_pane" \
  "$codexf_pane" "$codex_pane" "$stale_pane" "$missing_pane" "$pending_pane"; do
  start_clean_shell "$pane"
done
env TMUX="$SERVER_TMUX" TMUX_WORKSPACE_RESURRECT_STATE_DIR="$STATE_DIR" \
  TMUX_RESURRECT_DIR="$RESURRECT_DIR" TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" \
  bash "$RESTORE_SCRIPT"

assert_restore_buffer "$claudef_pane" "$expected_claudef"
assert_restore_buffer "$claude_pane" "$expected_claude"
assert_restore_buffer "$pif_pane" "$expected_pif"
assert_restore_buffer "$pi_pane" "$expected_pi"
for pane in "$codexf_pane" "$codex_pane"; do
  [ -z "$(tmux -L "$SOCKET" show-option -pqv -t "$pane" @workspace-pending-buffer)" ] ||
    fail 'excluded old Codex command was queued'
  ! tmux -L "$SOCKET" capture-pane -p -t "$pane" | grep -q 'codex' ||
    fail 'excluded old Codex command was pasted'
done
assert_restore_buffer "$pending_pane" 'echo pending-buffer-survives'

# The production save wrapper must reject a validly shaped save with reported
# agent errors and leave its last-successful marker untouched. Its fake plugin
# still writes only inside the isolated resurrect directory.
WRAPPER="$PLUGIN_DIR/../../scripts/resurrect_save.sh"
FAKE_PLUGIN="$TEST_ROOT/fake-resurrect"
mkdir -p "$FAKE_PLUGIN/scripts"
ln -s "$TEST_DIR/agent_resume_integration.sh" "$FAKE_PLUGIN/scripts/save.sh"
chmod +x "$TEST_DIR/agent_resume_integration.sh"
tmux -L "$SOCKET" set-option -g @resurrect-dir "$RESURRECT_DIR"
marker="$RESURRECT_DIR/.last-successful-save"
printf '12345\n' >"$marker"
wrapper_stderr="$TEST_ROOT/wrapper-agent-errors.stderr"
if env TMUX="$SERVER_TMUX" TMUX_RESURRECT_SAVE_PLUGIN_DIR="$FAKE_PLUGIN" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" WORKSPACE_TEST_FAKE_PLUGIN=1 \
  WORKSPACE_TEST_FAKE_AGENT_ERRORS=1 bash "$WRAPPER" 2>"$wrapper_stderr"; then
  fail 'verified save wrapper accepted agent_capture_errors'
fi
grep -q 'lack verified resume IDs' "$wrapper_stderr" ||
  fail 'verified save wrapper rejection was not caused by agent_capture_errors'
[ "$(cat "$marker")" = 12345 ] || fail 'verified save wrapper changed its success marker on agent errors'

env TMUX="$SERVER_TMUX" TMUX_RESURRECT_SAVE_PLUGIN_DIR="$FAKE_PLUGIN" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$CONFIG_FILE" WORKSPACE_TEST_FAKE_PLUGIN=1 \
  WORKSPACE_TEST_FAKE_AGENT_ERRORS=0 bash "$WRAPPER" ||
  fail 'verified save wrapper rejected complete coverage without agent errors'
case "$(cat "$marker")" in
  '' | *[!0-9]* | 12345) fail 'verified save wrapper did not publish success marker' ;;
esac

printf 'agent resume integration passed: focus and canonical launchers, exact IDs, stale/missing records, pending buffers, and isolated restore queue\n'
