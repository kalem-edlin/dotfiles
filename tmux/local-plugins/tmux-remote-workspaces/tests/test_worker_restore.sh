#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # literal tmux formats
# Worker restore as seen by the attach loop and the worker post-restore
# (C6): the probe's `restoring` state, the persisted server identity that
# decides an intentional close, the no-server restore recheck, and
# rw-worker-post-restore.sh. No real tmux, no ssh: lib.sh's fake ssh runs
# the worker side here, and a stateful fake tmux below (on PATH ahead of
# lib.sh's stub) plays the worker's server.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

REPO_TMUX="$(cd "$RW_PLUGIN/../.." && pwd -P)"
# The worker finds its boot restore wrapper through ~/.config/tmux.
mkdir -p "$FAKE_WORKER_HOME/.config"
ln -s "$REPO_TMUX" "$FAKE_WORKER_HOME/.config/tmux"

FT="$SANDBOX/fake-tmux"
mkdir -p "$FT" "$SANDBOX/fbin"
export FT
export TMUX_WORKSPACE_RESURRECT_STATE_DIR="$SANDBOX/ws-state"
export TMUX_RESURRECT_BOOT_TIME=1000
mkdir -p "$TMUX_WORKSPACE_RESURRECT_STATE_DIR"

cat >"$SANDBOX/fbin/tmux" <<'EOF'
#!/usr/bin/env bash
# Stateful fake worker server: $FT/server (up), $FT/sessions (names),
# $FT/start, $FT/pid, $FT/tmpdir (server TMPDIR; absent = none).
printf '%s\n' "$*" >>"$FT/calls"
while [ "${1:-}" = "-f" ] || [ "${1:-}" = "-L" ]; do shift 2; done
cmd="${1:-}"; shift
target="" fmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) target="${2#=}"; shift 2 ;;
    -F) fmt="$2"; shift 2 ;;
    -p | -g | -d | -q) shift ;;
    *) [ -z "$fmt" ] && fmt="$1"; shift ;;
  esac
done
up() { [ -e "$FT/server" ]; }
case "$cmd" in
  list-sessions) up || exit 1; cat "$FT/sessions" 2>/dev/null ;;
  has-session) up && grep -qx -- "$target" "$FT/sessions" 2>/dev/null ;;
  display-message)
    up || exit 1
    fmt="${fmt//'#{start_time}'/$(cat "$FT/start")}"
    printf '%s\n' "${fmt//'#{pid}'/$(cat "$FT/pid")}"
    ;;
  show-environment)
    if [ -e "$FT/tmpdir" ]; then printf 'TMPDIR=%s\n' "$(cat "$FT/tmpdir")"; else echo "unknown variable: TMPDIR" >&2; exit 1; fi
    ;;
  kill-session)
    grep -vx -- "$target" "$FT/sessions" >"$FT/s.tmp"; mv "$FT/s.tmp" "$FT/sessions"
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SANDBOX/fbin/tmux"
export PATH="$SANDBOX/fbin:$PATH"

server_up() { # server_up <start> <pid> <session>...
  : >"$FT/server"
  printf '%s\n' "$1" >"$FT/start"
  printf '%s\n' "$2" >"$FT/pid"
  shift 2
  printf '%s\n' "$@" | sed '/^$/d' >"$FT/sessions"
}
server_down() { rm -f "$FT/server" "$FT/sessions"; }

# shellcheck source=../scripts/attach-loop.sh
source "$RW_PLUGIN/scripts/attach-loop.sh"

S="rw-abcd1234-ep1"
lock="$TMUX_WORKSPACE_RESURRECT_STATE_DIR/boot-restore.lock"
probe() { remote_state fakeworker "$S"; }

# --- probe ------------------------------------------------------------------
server_down
eq "no server, no boot lock -> no-server" "$(probe)" "no-server"

sleep 30 &
holder=$!
mkdir -p "$lock"
printf '%s\n' "$holder" >"$lock/pid"
printf '%s\n' 1000 >"$lock/boot"
eq "no server, live boot lock -> restoring" "$(probe)" "restoring"
printf '%s\n' 999 >"$lock/boot"
eq "boot lock taken in an earlier boot is stale -> no-server" "$(probe)" "no-server"
printf '%s\n' 1000 >"$lock/boot"

server_up 500 77 _tmux_restore_boot
eq "only the bootstrap session -> restoring (not session-absent)" "$(probe)" "restoring"
rm -rf "$lock"

server_up 500 77 work
eq "server up, session absent, no restore -> session-absent with identity" "$(probe)" "session-absent 500 77"

export TMPDIR="$SANDBOX/caller-tmp"
mkdir -p "$TMPDIR" "$SANDBOX/server-tmp"
printf '%s\n' "$SANDBOX/server-tmp" >"$FT/tmpdir"
: >"$SANDBOX/server-tmp/tmux-resurrect-77-restore-incomplete"
eq "incomplete-restore marker (server TMPDIR) -> restoring" "$(probe)" "restoring"
rm -f "$SANDBOX/server-tmp/tmux-resurrect-77-restore-incomplete"
: >"$SANDBOX/caller-tmp/tmux-resurrect-77-restore-incomplete"
eq "marker under the caller's TMPDIR, not the server's, is ignored" "$(probe)" "session-absent 500 77"
rm -f "$SANDBOX/caller-tmp/tmux-resurrect-77-restore-incomplete"

server_up 500 77 work "$S"
eq "session present -> session-present with identity" "$(probe)" "session-present 500 77"

# --- intentional close vs rebuilt server ------------------------------------
E=ep1
eq "fresh loop, nothing recorded -> recreate, never close" "$(absent_verdict "$E" 500 77)" "recreate"
record_server_seen "$E" 500 77
eq "persisted identity file" "$(cat "$(rw_attach_seen_file "$E")")" "500 77"
eq "same server instance, session gone -> close" "$(absent_verdict "$E" 500 77)" "close"
eq "server restarted (new start/pid) -> recreate" "$(absent_verdict "$E" 900 88)" "recreate"
eq "pid recycled but new start time -> recreate" "$(absent_verdict "$E" 900 77)" "recreate"
eq "identity unknown (empty probe fields) -> recreate" "$(absent_verdict "$E" "" "")" "recreate"
forget_server_seen "$E"
check "forget removes the persisted identity" test ! -e "$(rw_attach_seen_file "$E")"
record_server_seen "$E" "" ""
check "an empty identity is never persisted" test ! -e "$(rw_attach_seen_file "$E")"

# --- no-server restore recheck -----------------------------------------------
cat >"$SANDBOX/ssh-argv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SANDBOX/ssh-argv.log"
exec "$SANDBOX/bin/ssh" "\$@"
EOF
chmod +x "$SANDBOX/ssh-argv"

server_down
mkdir -p "$lock"
printf '%s\n' "$holder" >"$lock/pid"
printf '%s\n' 1000 >"$lock/boot"
out="$(RW_SSH_BIN="$SANDBOX/ssh-argv" TMUX_RESURRECT_RESTORE_LOCK_TIMEOUT=1 \
  ask_worker_to_restore_then_recheck fakeworker "$S")"
eq "boot lock held past the wrapper's timeout -> restoring (no rebuild)" "$out" "restoring"
check "the restore ssh carries ServerAliveInterval" grep -q 'ServerAliveInterval=15' "$SANDBOX/ssh-argv.log"
check "the wrapper logged its lock timeout" grep -q 'timed out after 1s waiting for the boot lock' \
  "$TMUX_WORKSPACE_RESURRECT_STATE_DIR/boot-restore.log"
rm -rf "$lock"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

server_up 500 77 work "$S"
eq "live server with the session -> yes" "$(ask_worker_to_restore_then_recheck fakeworker "$S")" "yes"
server_up 500 77 work
eq "live server without the session, no restore -> no (rebuild)" \
  "$(ask_worker_to_restore_then_recheck fakeworker "$S")" "no"

# --- rw-worker-post-restore.sh -----------------------------------------------
POST="$RW_PLUGIN/scripts/rw-worker-post-restore.sh"
mirror="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/123"
mkdir -p "$mirror"
record='{"root_id":"123","root_rel":"Developer/x","owner":"worker","since":"2026-11-18T00:00:00Z","endpoints":["ep1","ep2"],"focus_machine_id":"abcd1234-0000-0000-0000-000000000000"}'
printf '%s' "$record" >"$mirror/record.json"

server_up 500 77 work
HOME="$FAKE_WORKER_HOME" bash "$POST" --hook >/dev/null
check "no rw-* sessions (a focus machine): nothing written" test ! -e "$mirror/restored.json"

: >"$FT/calls"
server_up 500 77 _tmux_restore_boot work "$S"
HOME="$FAKE_WORKER_HOME" bash "$POST" >/dev/null
eq "post-restore exits 0" "$?" "0"
check "bootstrap session dropped once others exist" bash -c "! grep -qx _tmux_restore_boot '$FT/sessions'"
for opt in "prefix None" "prefix2 None" "status off" "mouse off" "detach-on-destroy on"; do
  check "hidden option '$opt' set on $S" grep -q "set-option -t $S $opt" "$FT/calls"
done
eq "record.json is never rewritten" "$(cat "$mirror/record.json")" "$record"
eq "restored.json beside it lists the live endpoints" \
  "$(jq -c '.restored_endpoints' "$mirror/restored.json")" '["ep1"]'
eq "restored.json has restored_at" "$(jq -r '.restored_at | test("^20")' "$mirror/restored.json")" "true"

rm -f "$mirror/restored.json"
printf '%s\n' "abcd1234-0000-0000-0000-000000000000" >"$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/machine-id"
HOME="$FAKE_WORKER_HOME" bash "$POST" >/dev/null
check "a record naming this machine as focus is skipped" test ! -e "$mirror/restored.json"
rm -f "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/machine-id"

printf 'not json' >"$mirror/record.json"
HOME="$FAKE_WORKER_HOME" bash "$POST" --hook >/dev/null
eq "--hook exits 0 even when a record is unreadable" "$?" "0"
HOME="$FAKE_WORKER_HOME" bash "$POST" >/dev/null
check "without --hook an unreadable record is a failure" test "$?" -ne 0

server_down
HOME="$FAKE_WORKER_HOME" bash "$POST" --hook >/dev/null
eq "--hook with no server exits 0" "$?" "0"

finish
