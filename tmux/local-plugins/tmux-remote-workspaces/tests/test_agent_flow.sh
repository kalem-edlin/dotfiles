#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Agent ordering and all-or-nothing rollback for handoff and hand-back
# (items 2, 3, 14 of the fe61a15 review), against the pane-aware tmux stub
# and a fake claude adapter (RW_ADAPTERS_DIR). No tmux server, no ssh.
#
#   2  the agent is stopped BEFORE the snapshot, so its last write travels
#      (both directions); a working agent is refused
#   14 a remote resume that fails rolls the whole handoff back: remote
#      sessions killed, local agent resumed, root stays local
#   3  a local resume that fails rolls the hand-back back: panes back on
#      their attach loops, remote agent resumed, root stays remote, nothing
#      pending, no endpoint closed

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

export FAKE_EVENTS="$SANDBOX/events"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
export RW_ADAPTERS_DIR="$SANDBOX/adapters"
mkdir -p "$RW_ADAPTERS_DIR"
cat >"$RW_ADAPTERS_DIR/claude" <<'ADAPTER'
#!/usr/bin/env bash
# Fake claude adapter: one agent, in $FAKE_AGENT_PANE.
cmd="$1"; shift
printf 'adapter %s %s\n' "$cmd" "$*" >>"${FAKE_EVENTS:-/dev/null}"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  detect)
    [ "$(arg --pane "$@")" = "${FAKE_AGENT_PANE:-}" ] || exit 1
    jq -nc --arg p "$FAKE_AGENT_PROJECT" '{provider: "claude", session_id: "sess-1", project_path: $p, mode_flags: ""}'
    ;;
  versions) echo '{"local":"1","worker":"1","policy":"identical"}' ;;
  export)
    out="$(arg --out "$@")"; mkdir -p "$out"
    echo '{"session":1}' >"$out/session.jsonl"
    echo '{"provider":"claude","session_id":"sess-1"}' >"$out/manifest.json"
    ;;
  install) : ;;
  resume-cmd) printf 'cd %q && claudef --resume %s\n' "$(arg --dest-path "$@")" "$(arg --session-id "$@")" ;;
esac
ADAPTER
chmod +x "$RW_ADAPTERS_DIR/claude"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
root="$HOME/Developer/agentproj"
make_plain "$root"
mkdir -p "$root/app"
export FAKE_AGENT_PANE=%1 FAKE_AGENT_PROJECT="$root/app"
wroot="$FAKE_WORKER_HOME/Developer/agentproj"
id="$(rw_root_id Developer/agentproj)"
panes() {
  printf 'pane_id=%%1\tpane_current_path=%s\tsession_name=s1\twindow_index=0\tpane_index=0\tpane_current_command=zsh\tpane_pid=999998\t@agent_state=%s\t@workspace-last-command=claudef\n' "$root/app" "${1:-idle}"
  printf 'pane_id=%%2\tpane_current_path=%s\tsession_name=s1\twindow_index=0\tpane_index=1\tpane_current_command=zsh\tpane_pid=999997\n' "$root"
}
order() { # <first-pattern> <second-pattern>: line of first < line of second
  local a b
  a="$(grep -n -m1 -- "$1" "$FAKE_EVENTS" | cut -d: -f1)"
  b="$(grep -n -m1 -- "$2" "$FAKE_EVENTS" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
opt() { tr '\t' '\n' <"$FAKE_TMUX_PANES" | awk -v p="pane_id=$1" '/^pane_id=/ { cur = $0 } cur == p' | sed -n "s/^$2=//p" | head -n1; }

# --- 2: a working agent is refused --------------------------------------------
panes working >"$FAKE_TMUX_PANES"
rw handoff --worker fakeworker --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "2: handoff with a working agent: exit 1" "$?" "1"
check "2: says it is working" grep -q "is working" "$SANDBOX/err"
check "2: nothing was synced" test ! -e "$wroot"

# --- 14: remote resume fails -> everything rolls back -----------------------------
panes idle >"$FAKE_TMUX_PANES"
: >"$FAKE_EVENTS"
export FAKE_AGENT_LASTWRITE="$root/app/agent.log" FAKE_TMUX_REMOTE_CMD=zsh FAKE_LOCAL_RESUME_OK=1
rw handoff --worker fakeworker --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "14: remote resume unverified: exit 1" "$?" "1"
check "14: says it rolled back" grep -q "Rolled back" "$SANDBOX/err"
check "14: the root stays local (no worker-owned record)" bash -c "! jq -e '.owner == \"worker\"' '$(rw_owned_record_file "$id")' >/dev/null 2>&1"
check "14: the remote sessions were killed" grep -q "^tmux kill-session -t =rw-" "$FAKE_EVENTS"
check "14: the local agent was resumed in its pane" grep -q "^tmux send-keys -t %1 cd .* && claudef --resume sess-1 Enter" "$FAKE_EVENTS"
eq "14: the pane carries no endpoint" "$(opt %1 @rw-endpoint)" ""
check "14: no pane was replaced" bash -c "! grep -q '^tmux respawn-pane' '$FAKE_EVENTS'"
eq "14: the worker mirror records the synced copy as focus-owned" \
  "$(jq -r .owner "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$id/record.json")" "focus"

# --- 2: handoff stops the agent before the snapshot ---------------------------------
panes idle >"$FAKE_TMUX_PANES"
: >"$FAKE_EVENTS"
rm -f "$root/app/agent.log"
export FAKE_TMUX_REMOTE_CMD=claude
rw handoff --worker fakeworker --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "2: handoff: exit 0" "$?" "0"
check "2: the local agent is stopped before the transfer" order "^tmux display-message -pt %1 -F #{pane_pid}" "rsync --server"
check "2: its transcript is exported after the transfer" order "rsync --server" "^adapter export"
eq "2: the agent's last write reached the worker copy" "$(cat "$wroot/app/agent.log" 2>/dev/null)" "last local write"
eq "2: root is worker-owned" "$(jq -r .owner "$(rw_owned_record_file "$id")")" "worker"
check "2: both panes were replaced by attach loops" bash -c "[ \$(grep -c '^tmux respawn-pane' '$FAKE_EVENTS') -eq 2 ]"
check "2: endpoint stamped on the agent pane" test -n "$(opt %1 @rw-endpoint)"
eq "2: @workspace-last-command cleared" "$(opt %1 @workspace-last-command)" ""
ep="$(opt %1 @rw-endpoint)"
eq "2: the endpoint records a handed-off agent" "$(rw_read_endpoint "$ep" | jq -r .agent.state)" "handed-off"

# --- 3: local resume fails -> the hand-back rolls back ----------------------------------
# (The laptop copy is frozen now: the fake local agent no longer writes.)
unset FAKE_AGENT_LASTWRITE
: >"$FAKE_EVENTS"
export FAKE_LOCAL_RESUME_OK=0 FAKE_REMOTE_LASTWRITE="$wroot/app/agent.log"
rw handback --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "3: local resume unverified: exit 1" "$?" "1"
check "3: says it rolled back" grep -q "Rolled back" "$SANDBOX/err"
eq "3: root stays worker-owned" "$(jq -r .owner "$(rw_owned_record_file "$id")")" "worker"
eq "3: nothing pending" "$(jq -r 'has("pending")' "$(rw_owned_record_file "$id")")" "false"
check "3: no endpoint was closed" bash -c "[ ! -d '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones' ] || [ -z \"\$(ls '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones')\" ]"
check "3: the agent pane is back on its attach loop" grep -q "^tmux respawn-pane -k -t %1 .*attach-loop.sh $ep" "$FAKE_EVENTS"
eq "3: and carries its endpoint again" "$(opt %1 @rw-endpoint)" "$ep"
check "3: the remote agent was resumed" grep -q "^tmux send-keys -t rw-.*-$ep cd .* && claudef --resume sess-1 Enter" "$FAKE_EVENTS"
check "3: the remote agent was stopped before the pull" order "list-panes -t =rw-.*-$ep -F #{pane_pid}" "rsync --server"

# --- 2: hand-back stops the remote agent before the pull ------------------------------------
: >"$FAKE_EVENTS"
export FAKE_LOCAL_RESUME_OK=1
rm -f "$wroot/app/agent.log"
rw handback --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "2: hand-back: exit 0" "$?" "0"
eq "2: the remote agent's last write reached the laptop copy" "$(cat "$root/app/agent.log" 2>/dev/null)" "last remote write"
check "2: the local agent resumed in the same pane" grep -q "^tmux send-keys -t %1 cd .* && claudef --resume sess-1 Enter" "$FAKE_EVENTS"
check "2: record deleted" test ! -e "$(rw_owned_record_file "$id")"
check "2: endpoint closed after every pane was back" order "^tmux send-keys -t %1 cd" "kill-session -t '=rw-.*-$ep'"

finish
