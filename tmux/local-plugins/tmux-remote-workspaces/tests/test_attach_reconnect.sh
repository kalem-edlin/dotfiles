#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# F: an attach loop that reattaches logs a `reconnect` event at the moment
# it reattaches (not only when that attachment later ends). Runs the real
# attach loop against the fake worker (stub tmux: the session is present,
# each attach returns at once), then stops it with a tombstone.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

ep=feed1234
rw_write_json_atomic "$(rw_endpoint_file "$ep")" "$(jq -nc --arg w "$FAKE_WORKER_HOME" \
  '{endpoint_id: "feed1234", worker: "fakeworker", workspace: {remote_path: $w, focus_path: $w}}')"
# The laptop pane still carries the endpoint (else the loop treats it as
# handed back and becomes a local shell).
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
printf 'pane_id=%%5\tpane_current_command=bash\t@rw-endpoint=%s\n' "$ep" >"$FAKE_TMUX_PANES"
TMUX_PANE=%5 "$RW_PLUGIN/scripts/attach-loop.sh" "$ep" >"$SANDBOX/loop.out" 2>&1 &
loop=$!
events="$TMUX_REMOTE_WORKSPACES_STATE_DIR/events.jsonl"
for _ in $(seq 1 40); do
  grep -q '"event":"reconnect","endpoint":"feed1234".*"outcome":"attached"' "$events" 2>/dev/null && break
  sleep 0.25
done
check "a reattach logs reconnect/attached when it happens" \
  grep -q '"event":"reconnect","endpoint":"feed1234".*"outcome":"attached"' "$events"
rw_write_tombstone "$ep" 1 "test"
rm -f "$(rw_endpoint_file "$ep")"
for _ in $(seq 1 40); do kill -0 "$loop" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$loop" 2>/dev/null; then
  kill "$loop" 2>/dev/null
  bad "the loop stops on the tombstone"
else
  ok "the loop stops on the tombstone"
fi
wait "$loop" 2>/dev/null
finish
