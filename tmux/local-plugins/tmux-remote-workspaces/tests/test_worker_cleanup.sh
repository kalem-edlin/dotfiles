#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# D: after a worker restore, rw-worker-post-restore.sh kills every RESTORED
# rw-* session (one named in the snapshot) whose endpoint no worker-owned
# mirror lists; sessions not in the snapshot (rw creating one right now) and
# owned ones stay. Closing endpoints asks the worker for a verified save.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

fid="0a1b2c3d-1111-2222-3333-444455556666" # the focus machine, as mirrors name it
mid="0a1b2c3d"
mirrors="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned"
mkdir -p "$mirrors/1" "$mirrors/2"
jq -nc --arg f "$fid" '{root_id: "1", owner: "worker", focus_machine_id: $f, endpoints: ["aaaa0001"]}' >"$mirrors/1/record.json"
jq -nc --arg f "$fid" '{root_id: "2", owner: "focus", focus_machine_id: $f, endpoints: ["bbbb0002"]}' >"$mirrors/2/record.json"

export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
mkdir -p "$TMUX_RESURRECT_DIR"
{
  printf 'pane\trw-%s-aaaa0001\t0\t1\t:*\t0\t:/w\t1\tzsh\t:\n' "$mid"
  printf 'pane\trw-%s-bbbb0002\t0\t1\t:*\t0\t:/w\t1\tclaude\t:\n' "$mid"
  printf 'window\trw-d157af95-ff8d1617\t0\t:zsh\t1\t:*\tlayout\t:\n'
  printf 'pane\twork\t0\t1\t:*\t0\t:/w\t1\tzsh\t:\n'
} >"$TMUX_RESURRECT_DIR/snap.txt"
ln -s snap.txt "$TMUX_RESURRECT_DIR/last"

now="$(date +%s)"
export FAKE_TMUX_SESSIONS="$SANDBOX/sessions"
{
  echo "rw-$mid-aaaa0001 $now 0"     # restored, owned by the worker
  echo "rw-$mid-bbbb0002 $now 0"     # restored, handed back (mirror owner focus)
  echo "rw-d157af95-ff8d1617 $now 0" # restored, no mirror at all
  echo "rw-$mid-cccc0003 $now 0"     # being created by rw open right now
  echo "work $now 0"
} >"$FAKE_TMUX_SESSIONS"

out="$("$RW_PLUGIN/scripts/rw-worker-post-restore.sh" 2>&1)"
killed="$(sed -n 's/^kill-session -t =//p' "$FAKE_TMUX_LOG" | sort | paste -sd, -)"
eq "D: restored sessions no worker-owned mirror lists are killed" "$killed" "rw-$mid-bbbb0002,rw-d157af95-ff8d1617"
check "D: and each is logged" bash -c "[ \$(grep -c 'killed restored session' <<<'$out') -eq 2 ]"
check "D: the owned session stays" bash -c "! grep -q 'kill-session -t =rw-$mid-aaaa0001' '$FAKE_TMUX_LOG'"
check "D: a session not in the snapshot (being created) stays" bash -c "! grep -q 'cccc0003' <<<'$killed'"
check "D: non-rw sessions stay" bash -c "! grep -q 'kill-session -t =work' '$FAKE_TMUX_LOG'"

# Closing an endpoint asks the worker (which still has sessions) for a save.
rw_write_json_atomic "$(rw_endpoint_file dddd0004)" '{"endpoint_id":"dddd0004","worker":"fakeworker"}'
: >"$SANDBOX/worker-saves.log"
"$RW_PLUGIN/scripts/rw" close --endpoint dddd0004 >/dev/null 2>&1
eq "D: rw close asked the worker for a verified save" "$(cat "$SANDBOX/worker-saves.log")" "save-requested"
check "D: the save is requested only while sessions remain" bash -c "grep -q 'if tmux list-sessions' '$FAKE_SSH_LOG'"

finish
