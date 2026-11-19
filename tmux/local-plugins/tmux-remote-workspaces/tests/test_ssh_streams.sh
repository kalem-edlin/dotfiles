#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# rw's long-lived ssh streams use a ControlMaster of their own (X4 smoke
# test on the real worker, 2026-11-18). Each remote pane holds two sessions
# (attach, agent-state watch); sshd's default MaxSessions is 10, so on the
# shared master five remote panes used every slot and each later short ssh
# (probe, switch, copy-mode, close) was refused by the master and paid a
# full connection. Checks: the option itself and its overrides; the real
# attach loop's attach and its state watch carry it; the loop's short
# probe and rw_ssh_batch do not; the restore wait carries it.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

stream_cp='ControlPath=~/.ssh/sockets/rw-stream-%C'

# --- the option ---------------------------------------------------------------------
rw_ssh_stream_opts
eq "streams get their own ControlPath by default" "${RW_SSH_STREAM_OPTS[*]}" "-o $stream_cp"
RW_SSH_STREAM_CONTROL_PATH=none rw_ssh_stream_opts
eq "RW_SSH_STREAM_CONTROL_PATH=none: a connection per stream" "${RW_SSH_STREAM_OPTS[*]}" "-o ControlPath=none"
RW_SSH_STREAM_CONTROL_PATH='' rw_ssh_stream_opts
eq "an empty override adds no option (ssh's configured master)" "${#RW_SSH_STREAM_OPTS[@]}" "0"

# --- the attach loop ------------------------------------------------------------------
# Every ssh's argv, then the same-host fake ssh.
cat >"$SANDBOX/ssh-argv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >>"$SANDBOX/ssh-argv.log"
printf '\n' >>"$SANDBOX/ssh-argv.log"
exec "$SANDBOX/bin/ssh" "\$@"
EOF
chmod +x "$SANDBOX/ssh-argv"
export RW_SSH_BIN="$SANDBOX/ssh-argv"
: >"$SANDBOX/ssh-argv.log"

ep=feed5678
rw_write_json_atomic "$(rw_endpoint_file "$ep")" "$(jq -nc --arg w "$FAKE_WORKER_HOME" \
  '{endpoint_id: "feed5678", worker: "fakeworker", workspace: {remote_path: $w, focus_path: $w}}')"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
printf 'pane_id=%%5\tpane_current_command=bash\t@rw-endpoint=%s\n' "$ep" >"$FAKE_TMUX_PANES"
TMUX_PANE=%5 "$RW_PLUGIN/scripts/attach-loop.sh" "$ep" >"$SANDBOX/loop.out" 2>&1 &
loop=$!
for _ in $(seq 1 40); do
  grep -q 'attach-session' "$SANDBOX/ssh-argv.log" && grep -q '@agent_pid' "$SANDBOX/ssh-argv.log" && break
  sleep 0.25
done
rw_write_tombstone "$ep" 1 "test"
rm -f "$(rw_endpoint_file "$ep")"
for _ in $(seq 1 40); do kill -0 "$loop" 2>/dev/null || break; sleep 0.25; done
kill "$loop" 2>/dev/null
wait "$loop" 2>/dev/null

check "the attach (ssh -t) uses the stream master" \
  bash -c "grep 'attach-session' '$SANDBOX/ssh-argv.log' | grep -qF -- '$stream_cp'"
check "the agent-state watch uses the stream master" \
  bash -c "grep '@agent_pid' '$SANDBOX/ssh-argv.log' | grep -qF -- '$stream_cp'"
check "the loop's short probe stays on the shared master" \
  bash -c "grep -v 'attach-session' '$SANDBOX/ssh-argv.log' | grep -v '@agent_pid' | grep -q . &&
    ! grep -v 'attach-session' '$SANDBOX/ssh-argv.log' | grep -v '@agent_pid' | grep -qF 'ControlPath='"

: >"$SANDBOX/ssh-argv.log"
rw_ssh_batch fakeworker 2 true
check "rw_ssh_batch (every short command) stays on the shared master" \
  bash -c "grep -q . '$SANDBOX/ssh-argv.log' && ! grep -qF 'ControlPath=' '$SANDBOX/ssh-argv.log'"

# --- the restore wait (can hold a session for minutes) ------------------------------------
: >"$SANDBOX/ssh-argv.log"
# shellcheck source=../scripts/attach-loop.sh
source "$RW_PLUGIN/scripts/attach-loop.sh"
ask_worker_to_restore_then_recheck fakeworker rw-x-sess >/dev/null 2>&1
check "the restore wait uses the stream master" grep -qF -- "$stream_cp" "$SANDBOX/ssh-argv.log"

finish
