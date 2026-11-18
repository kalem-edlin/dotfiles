#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # literal tmux formats and worker-side programs
# B3: no rw command waits on the worker save trigger, and a tmux server on
# the worker is only ever started through its boot restore wrapper
# (setup/templates/tmux-resurrect-restore.sh), never by a bare new-session.
#
# Laptop-side tmux is lib.sh's stub. The worker side gets a stateful fake
# tmux (on PATH only inside the fake ssh) whose server, sessions and
# Continuum attempt are files under $FT, and fake guarded restore / upstream
# restore / post-restore scripts, so the real wrapper runs end to end.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"
rw() { "$RW_PLUGIN/scripts/rw" "$@"; }

# ===========================================================================
# Defect 1: the save trigger is fire and forget at both ends.
# ===========================================================================

SAVES="$SANDBOX/worker-saves.log"
export RW_WORKER_SAVE_TRIGGER="sleep 5; echo save-requested >>'$SAVES'"

# An ssh that records when it returned: the remote end must not wait for the
# trigger either.
cat >"$SANDBOX/ssh-timed" <<EOF
#!/usr/bin/env bash
"$SANDBOX/bin/ssh" "\$@"
rc=\$?
echo done >>"$SANDBOX/ssh-returned"
exit \$rc
EOF
chmod +x "$SANDBOX/ssh-timed"

t0="$(rw_now_epoch)"
RW_SSH_BIN="$SANDBOX/ssh-timed" rw_worker_request_save fakeworker
ms="$(rw_elapsed_ms "$t0")"
check "request_save returns at once with a 5 s trigger (${ms} ms)" test "$ms" -lt 1000
check "the remote shell returns before the trigger ends" wait_for 3 test -s "$SANDBOX/ssh-returned"
check "  (the trigger is still running then)" test ! -s "$SAVES"
check "the trigger still runs to completion, detached" wait_for 10 test -s "$SAVES"
check "the trigger runs in the background under nohup" grep -q 'nohup sh -c' "$FAKE_SSH_LOG"
: >"$SAVES"

plain="$HOME/Developer/slowsave"
make_plain "$plain"

t0="$(rw_now_epoch)"
rw handoff --worker fakeworker --root "$plain" >/dev/null 2>"$SANDBOX/err"
rc=$?
ms="$(rw_elapsed_ms "$t0")"
eq "handoff with a slow save trigger: exit 0" "$rc" "0"
check "handoff does not wait for the save trigger (${ms} ms)" test "$ms" -lt 4000
check "  (its save request had not finished when it returned)" test ! -s "$SAVES"

t0="$(rw_now_epoch)"
rw open --pane %9 --root "$plain" >/dev/null 2>"$SANDBOX/err"
rc=$?
ms="$(rw_elapsed_ms "$t0")"
eq "open with a slow save trigger: exit 0" "$rc" "0"
check "open does not wait for the save trigger (${ms} ms)" test "$ms" -lt 4000
check "  (its save request had not finished when it returned)" test ! -s "$SAVES"

ep="$(rw_owned_record_read "$(rw_root_id Developer/slowsave)" | jq -r '.endpoints[0]')"
t0="$(rw_now_epoch)"
rw close --endpoint "$ep" >/dev/null 2>&1
rc=$?
ms="$(rw_elapsed_ms "$t0")"
eq "close with a slow save trigger: exit 0" "$rc" "0"
check "close does not wait for the save trigger (${ms} ms)" test "$ms" -lt 4000
check "the requests land later" wait_for 10 test -s "$SAVES"
export RW_WORKER_SAVE_TRIGGER="echo save-requested >>'$SAVES'"

# ===========================================================================
# Defect 2: the worker server starts only through the boot restore wrapper.
# ===========================================================================

REPO_TMUX="$(cd "$RW_PLUGIN/../.." && pwd -P)"
mkdir -p "$FAKE_WORKER_HOME/.config"
ln -s "$REPO_TMUX" "$FAKE_WORKER_HOME/.config/tmux"

FT="$SANDBOX/ft"
mkdir -p "$FT" "$SANDBOX/fbin" "$SANDBOX/server-tmp" "$SANDBOX/snap" "$SANDBOX/plugin/scripts" "$SANDBOX/ws-state"
export FT
export TMUX_WORKSPACE_RESURRECT_STATE_DIR="$SANDBOX/ws-state"
export TMUX_RESURRECT_BOOT_TIME=1000
export TMUX_RESURRECT_RESTORE_DIR="$SANDBOX/snap"
export TMUX_RESURRECT_RESTORE_PLUGIN_DIR="$SANDBOX/plugin"
export TMUX_RESURRECT_GUARDED_RESTORE_SCRIPT="$SANDBOX/guarded-restore"
export TMUX_RESURRECT_RW_POST_RESTORE_SCRIPT="$SANDBOX/post-restore"
export TMUX_RESURRECT_RESTORE_CONTINUUM_WAIT=2
export TMUX_RESURRECT_MARKER_DIRS="$SANDBOX/server-tmp"
export RW_WORKER_START_TIMEOUT=5
printf '%s\n' "$SANDBOX/server-tmp" >"$FT/tmpdir"
printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/plugin/scripts/restore.sh"
printf '#!/bin/sh\necho post-restore >>"$FT/calls"\n' >"$SANDBOX/post-restore"
chmod +x "$SANDBOX/plugin/scripts/restore.sh" "$SANDBOX/post-restore"
MARKER="$SANDBOX/server-tmp/tmux-resurrect-4242-restore-incomplete"

# Worker tmux. A server start that loads a config (-f) plays Continuum's
# restore-on-start: with $FT/continuum = fail it leaves the marker the way a
# guarded restore into a server it did not expect does.
cat >"$SANDBOX/fbin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FT/calls"
conf=""
while [ "${1:-}" = "-f" ] || [ "${1:-}" = "-L" ]; do [ "$1" = -f ] && conf="$2"; shift 2; done
cmd="${1:-}"; shift
target="" fmt="" name="" dash_p=0
while [ $# -gt 0 ]; do
  case "$1" in
    -t) target="${2#=}"; shift 2 ;;
    -s) name="$2"; shift 2 ;;
    -c | -F) shift 2 ;;
    -p) dash_p=1; shift ;;
    -*) shift ;;
    *) [ -z "$fmt" ] && fmt="$1"; shift ;;
  esac
done
up() { [ -e "$FT/server" ]; }
marker="$(cat "$FT/tmpdir")/tmux-resurrect-4242-restore-incomplete"
case "$cmd" in
  list-sessions) up || exit 1; cat "$FT/sessions" ;;
  has-session) up && grep -qx -- "$target" "$FT/sessions" ;;
  new-session)
    if ! up; then
      : >"$FT/server"; : >"$FT/sessions"
      echo "server-start conf=${conf:-none} first=$name" >>"$FT/calls"
      [ -n "$conf" ] && [ "$(cat "$FT/continuum" 2>/dev/null)" = fail ] &&
        echo "restore started by pid 1 did not complete" >"$marker"
    fi
    grep -qx -- "$name" "$FT/sessions" && exit 1
    printf '%s\n' "$name" >>"$FT/sessions"
    ;;
  kill-session)
    up || exit 1
    grep -vx -- "$target" "$FT/sessions" >"$FT/s.tmp"; mv "$FT/s.tmp" "$FT/sessions"
    [ -s "$FT/sessions" ] || rm -f "$FT/server"
    ;;
  display-message)
    up || exit 1
    fmt="${fmt//'#{pid}'/4242}"; fmt="${fmt//'#{start_time}'/1700000000}"
    printf '%s\n' "${fmt//'#{socket_path}'/$FT/sock}"
    ;;
  show-environment) printf 'TMPDIR=%s\n' "$(cat "$FT/tmpdir")" ;;
  *) up || exit 1 ;;
esac
EOF
# Guarded restore: $FT/restore = ok (sessions from the snapshot), fail
# (nothing), partial (one session, then a failure).
cat >"$SANDBOX/guarded-restore" <<'EOF'
#!/usr/bin/env bash
marker="${TMPDIR:-/nonexistent}/tmux-resurrect-4242-restore-incomplete"
echo "guarded-restore mode=$(cat "$FT/restore")" >>"$FT/calls"
echo "restore started by pid $$" >"$marker"
case "$(cat "$FT/restore")" in
  ok) printf '%s\n' work rw-old >>"$FT/sessions"; rm -f "$marker" ;;
  partial) echo work >>"$FT/sessions"; echo "restore started by pid $$ did not complete" >"$marker"; exit 1 ;;
  *) echo "restore started by pid $$ did not complete" >"$marker"; exit 1 ;;
esac
EOF
chmod +x "$SANDBOX/fbin/tmux" "$SANDBOX/guarded-restore"

# The fake ssh, with the worker's tmux first on PATH (laptop calls keep the
# stub).
cat >"$SANDBOX/ssh-worker" <<EOF
#!/usr/bin/env bash
PATH="$SANDBOX/fbin:\$PATH" exec "$SANDBOX/bin/ssh" "\$@"
EOF
chmod +x "$SANDBOX/ssh-worker"
export RW_SSH_BIN="$SANDBOX/ssh-worker"

server_down() { rm -f "$FT/server" "$FT/sessions" "$MARKER"; : >"$FT/calls"; }
calls() { cat "$FT/calls"; }
line_of() { grep -n -- "$1" "$FT/calls" | head -n 1 | cut -d: -f1; }
has() { grep -qx -- "$1" "$FT/sessions" 2>/dev/null; }

S1="rw-aaaa0001-bbbb0001"
WD="$FAKE_WORKER_HOME"

# --- no server, snapshot restores -------------------------------------------
server_down
echo ok >"$FT/restore"
: >"$SANDBOX/snap/last"
echo fail >"$FT/continuum"
: >"$FAKE_SSH_LOG"
# Garbage the wrapper sweeps: a marker of a server that is gone, and one of
# a live process that is not tmux.
sleep 30 &
not_tmux=$!
bash -c 'exit 0' &
dead=$!
wait "$dead"
: >"$SANDBOX/server-tmp/tmux-resurrect-$dead-restore-incomplete"
: >"$SANDBOX/server-tmp/tmux-resurrect-$not_tmux-restore-incomplete"

rw_create_remote_session fakeworker "$S1" "$WD" 3
eq "no server: session created through the wrapper (exit 0)" "$?" "0"
check "the creation ssh ran the wrapper with --start <session> <dir>" grep -q -- "--start" "$FAKE_SSH_LOG"
eq "the server was started by the wrapper, with tmux.conf, on the bootstrap session" \
  "$(grep '^server-start' "$FT/calls" | sed 's/conf=.*first=/first=/')" "server-start first=_tmux_restore_boot"
check "  and with the worker's tmux.conf (-f)" bash -c "grep '^server-start' '$FT/calls' | grep -q 'conf=.*tmux.conf'"
check "the guarded restore ran before the session was created" \
  test "$(line_of 'guarded-restore')" -lt "$(line_of "new-session -d -s $S1")"
check "the session was never the server's first session" bash -c "! grep -q 'first=$S1' '$FT/calls'"
check "the session exists" has "$S1"
check "the restored sessions exist" has work
check "the bootstrap session is gone" bash -c "! grep -qx _tmux_restore_boot '$FT/sessions'"
check "no incomplete-restore marker is left" test ! -e "$MARKER"
check "the worker post-restore ran" grep -qx post-restore "$FT/calls"
check "hidden options applied" grep -q "set-option -t $S1 status off" "$FT/calls"
check "a dead server's marker was swept" test ! -e "$SANDBOX/server-tmp/tmux-resurrect-$dead-restore-incomplete"
check "a non-tmux pid's marker was swept" test ! -e "$SANDBOX/server-tmp/tmux-resurrect-$not_tmux-restore-incomplete"
check "the sweep is logged" grep -q 'removed stale incomplete-restore marker' "$TMUX_WORKSPACE_RESURRECT_STATE_DIR/boot-restore.log"
kill "$not_tmux" 2>/dev/null
wait "$not_tmux" 2>/dev/null

# --- live server: plain create, no wrapper run ------------------------------
: >"$FT/calls"
rw_create_remote_session fakeworker rw-aaaa0001-bbbb0002 "$WD" 3
eq "live server: create succeeds" "$?" "0"
check "live server: no server start" bash -c "! grep -q '^server-start' '$FT/calls'"
check "live server: the session is created directly" grep -q "^new-session -d -s rw-aaaa0001-bbbb0002" "$FT/calls"

# --- live server whose last restore did not complete -------------------------
echo "restore started by pid 9 did not complete" >"$MARKER"
: >"$FT/calls"
rw_create_remote_session fakeworker rw-aaaa0001-bbbb0003 "$WD" 3
check "incomplete restore: creation refused" test "$?" -ne 0
check "  the error names the marker" grep -q "$MARKER" <<<"$RW_WORKER_SERVER_ERROR"
check "  and the remedy" grep -q 'run the guarded restore (prefix C-M-r) or restart the tmux server' <<<"$RW_WORKER_SERVER_ERROR"
check "  nothing created" bash -c "! grep -q '^new-session' '$FT/calls'"
eq "wrapper --state reports it" \
  "$(PATH="$SANDBOX/fbin:$PATH" HOME="$FAKE_WORKER_HOME" "$REPO_TMUX/../setup/templates/tmux-resurrect-restore.sh" --state)" "incomplete $MARKER"
rm -f "$MARKER"
eq "wrapper --state: ready" "$(PATH="$SANDBOX/fbin:$PATH" "$REPO_TMUX/../setup/templates/tmux-resurrect-restore.sh" --state)" "ready"

# --- no server, the restore fails ---------------------------------------------
server_down
echo fail >"$FT/restore"
rw_create_remote_session fakeworker "$S1" "$WD" 3
check "failed restore, no server left: creation refused" test "$?" -ne 0
check "  the error points at the boot restore log" grep -q 'boot-restore.log' <<<"$RW_WORKER_SERVER_ERROR"
check "  no bare new-session of the endpoint" bash -c "! grep -q 'new-session -d -s $S1' '$FT/calls'"
eq "wrapper --state with no server: none" "$(PATH="$SANDBOX/fbin:$PATH" "$REPO_TMUX/../setup/templates/tmux-resurrect-restore.sh" --state)" "none"

server_down
echo partial >"$FT/restore"
rw_create_remote_session fakeworker "$S1" "$WD" 3
check "partial restore: creation refused" test "$?" -ne 0
printf "DEBUG err=%s\n" "$RW_WORKER_SERVER_ERROR"; check "  the error names the marker and the remedy" \
  bash -c "grep -q '$MARKER' <<<\"\$1\" && grep -q 'prefix C-M-r' <<<\"\$1\"" _ "$RW_WORKER_SERVER_ERROR"
check "  the endpoint session was not created" bash -c "! grep -qx '$S1' '$FT/sessions'"

# --- the commands refuse with the message -------------------------------------
proj="$HOME/Developer/refused"
make_plain "$proj"
rw handoff --worker fakeworker --root "$proj" >/dev/null 2>"$SANDBOX/err"; cat "$SANDBOX/err"
eq "handoff onto a server with an incomplete restore: exit 1" "$?" "1"
check "  one rw: line naming the marker and the remedy" \
  bash -c "grep -q '$MARKER' '$SANDBOX/err' && grep -q 'prefix C-M-r' '$SANDBOX/err' && grep -q 'nothing was moved' '$SANDBOX/err'"
check "  the root stays local (no record)" bash -c "! '$RW_PLUGIN/scripts/rw' status --json | jq -e '.[] | select(.root_rel == \"Developer/refused\")' >/dev/null"
check "  nothing was copied to the worker" test ! -e "$FAKE_WORKER_HOME/Developer/refused"

server_down
echo fail >"$FT/restore"
rw handoff --worker fakeworker --root "$proj" >/dev/null 2>"$SANDBOX/err"; cat "$SANDBOX/err"
eq "handoff when the boot restore fails: exit 1" "$?" "1"
check "  says so before anything moves" bash -c "grep -q 'did not bring its tmux server up' '$SANDBOX/err' && grep -q 'nothing was moved' '$SANDBOX/err'"

# rw open on a root the worker owns (handed off while the server was fine).
server_down
echo ok >"$FT/restore"
rw handoff --worker fakeworker --root "$proj" >/dev/null 2>"$SANDBOX/err"; cat "$SANDBOX/err"
eq "handoff once the restore works: exit 0" "$?" "0"
server_down
echo partial >"$FT/restore"
rw open --pane %9 --root "$proj" >/dev/null 2>"$SANDBOX/err"
eq "open onto a server whose restore did not complete: exit 1" "$?" "1"
check "  one rw: line naming the marker and the remedy" \
  bash -c "grep -q '$MARKER' '$SANDBOX/err' && grep -q 'prefix C-M-r' '$SANDBOX/err' && [ \$(wc -l <'$SANDBOX/err') -eq 1 ]"
eq "  no endpoint was recorded" "$(rw_owned_record_read "$(rw_root_id Developer/refused)" | jq -c '.endpoints')" "[]"

# --- no snapshot: --start still brings a server up -----------------------------
server_down
rm -f "$SANDBOX/snap/last"
echo fail >"$FT/continuum"
rw_create_remote_session fakeworker "$S1" "$WD" 3
eq "no snapshot: the session is created" "$?" "0"
check "  through a wrapper-started server (tmux.conf, bootstrap first)" \
  bash -c "grep '^server-start' '$FT/calls' | grep -q 'conf=.*tmux.conf first=_tmux_restore_boot'"
check "  the marker Continuum's empty restore left is removed" test ! -e "$MARKER"
check "  the bootstrap session is gone, the endpoint stays" bash -c "[ \"\$(cat '$FT/sessions')\" = '$S1' ]"
check "  logged" grep -q "Continuum's restore found no snapshot" "$TMUX_WORKSPACE_RESURRECT_STATE_DIR/boot-restore.log"

server_down
rw_worker_ensure_server fakeworker
eq "ensure only, no snapshot: fine, and no server is started" "$?$(test -e "$FT/server" && echo up)" "0"

# --- an old wrapper (no --state/--start) -------------------------------------
mkdir -p "$SANDBOX/oldrepo/setup/templates" "$SANDBOX/oldrepo/tmux"
printf '#!/bin/sh\nfor a; do case "$a" in --*) [ "$a" = --restoring ] && exit 1; echo "unknown argument: $a" >&2; exit 2 ;; esac; done\nexit 0\n' \
  >"$SANDBOX/oldrepo/setup/templates/tmux-resurrect-restore.sh"
chmod +x "$SANDBOX/oldrepo/setup/templates/tmux-resurrect-restore.sh"
rm "$FAKE_WORKER_HOME/.config/tmux"
ln -s "$SANDBOX/oldrepo/tmux" "$FAKE_WORKER_HOME/.config/tmux"
server_down
rw_create_remote_session fakeworker "$S1" "$WD" 3
check "an old wrapper that cannot start a server: refused" test "$?" -ne 0
check "  asks for a dotfiles update" grep -q 'update its dotfiles checkout' <<<"$RW_WORKER_SERVER_ERROR"
check "  no bare server start" bash -c "! grep -q '^server-start' '$FT/calls'"
: >"$FT/server"
: >"$FT/sessions"
rw_create_remote_session fakeworker "$S1" "$WD" 3
eq "an old wrapper with a live server: created as before" "$?" "0"
rm "$FAKE_WORKER_HOME/.config/tmux"
mkdir -p "$SANDBOX/norepo"
ln -s "$SANDBOX/norepo" "$FAKE_WORKER_HOME/.config/tmux"
server_down
rw_create_remote_session fakeworker "$S1" "$WD" 3
check "no wrapper at all and no server: refused" test "$?" -ne 0
check "  no bare server start" bash -c "! grep -q '^server-start' '$FT/calls'"

# --- rw doctor's worker report --------------------------------------------------
rm "$FAKE_WORKER_HOME/.config/tmux"
ln -s "$REPO_TMUX" "$FAKE_WORKER_HOME/.config/tmux"
server_down
: >"$FT/server"
echo work >"$FT/sessions"
echo "restore started by pid 9 did not complete" >"$MARKER"
: >"$SANDBOX/server-tmp/tmux-resurrect-$dead-restore-incomplete"
report="$(TMPDIR="$SANDBOX/server-tmp" "$RW_SSH_BIN" fakeworker "sh -c $(rw_shquote "$(rw_worker_restore_report_sh)")")"
eq "doctor report: state of the live server" "$(sed -n 's/^state //p' <<<"$report")" "incomplete $MARKER"
check "doctor report: a dead server's marker is listed as stale" grep -q "^stale .*tmux-resurrect-$dead-restore-incomplete" <<<"$report"
check "doctor report: the live server's marker is not" bash -c "! grep -q '^stale .*-4242-' <<<\"\$1\"" _ "$report"
check "doctor report is read only" test -e "$SANDBOX/server-tmp/tmux-resurrect-$dead-restore-incomplete"

finish
