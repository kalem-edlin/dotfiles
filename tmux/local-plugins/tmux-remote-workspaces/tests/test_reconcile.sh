#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# libexec/reconcile and reconcile-worker never close a session that is too
# young (an `rw open`/handoff may be between creating it and registering
# it), attached, or registered; only old, detached, unregistered sessions in
# this machine's namespace go.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

# A valid workspace-resurrect sidecar (reconcile refuses to run without one).
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
mkdir -p "$TMUX_RESURRECT_DIR"
echo snapshot >"$TMUX_RESURRECT_DIR/snap.txt"
ln -s snap.txt "$TMUX_RESURRECT_DIR/last"
printf '{"version":1,"saved_at":"%s"}\n' "$(rw_now_iso)" >"$TMUX_RESURRECT_DIR/snap.txt.workspace_state.json"

short="$(rw_machine_short_id)"
now="$(date +%s)"
export FAKE_TMUX_SESSIONS="$SANDBOX/sessions"
{
  echo "rw-$short-aaaa1111 $((now - 10)) 0"   # young, unregistered
  echo "rw-$short-bbbb2222 $((now - 1000)) 0" # old, unregistered: orphan
  echo "rw-$short-cccc3333 $((now - 1000)) 1" # old, attached
  echo "rw-$short-dddd4444 $((now - 1000)) 0" # old, registered
  echo "rw-ffffffff-eeee5555 $((now - 1000)) 0" # another machine's
  echo "work $((now - 1000)) 0"
} >"$FAKE_TMUX_SESSIONS"
rw_write_json_atomic "$(rw_endpoint_file dddd4444)" '{"endpoint_id":"dddd4444","worker":"fakeworker"}'

out="$("$RW_PLUGIN/libexec/reconcile" 2>/dev/null)"
check "reconcile ran" bash -c "grep -q 'closed=1' <<<'$out'"
check "old detached unregistered session closed" test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/bbbb2222.json"
check "young session (mid-create) left alone" test ! -e "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/aaaa1111.json"
check "attached session left alone" test ! -e "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/cccc3333.json"
check "registered session left alone" test -f "$(rw_endpoint_file dddd4444)"
check "only the orphan was killed" bash -c "[ \$(grep -c '^kill-session' '$FAKE_TMUX_LOG') -eq 1 ] && grep -q '^kill-session -t =rw-$short-bbbb2222' '$FAKE_TMUX_LOG'"

rm -rf "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones"
: >"$FAKE_TMUX_LOG"
"$RW_PLUGIN/libexec/reconcile-worker" --worker fakeworker >/dev/null 2>&1
check "reconcile-worker: same guards (young, attached, registered spared)" \
  bash -c "[ \$(grep -c '^kill-session' '$FAKE_TMUX_LOG') -eq 1 ] && grep -q 'bbbb2222' '$FAKE_TMUX_LOG'"

finish
