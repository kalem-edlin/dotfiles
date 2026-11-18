#!/usr/bin/env bash
# Worker boot restore wrapper (setup/templates/tmux-resurrect-restore.sh)
# against the real guarded restore (scripts/resurrect_restore.sh) and the
# real verified save (scripts/resurrect_save.sh), with a stateful fake tmux
# and a fake upstream tmux-resurrect. No tmux server is ever contacted.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_DIR="$(cd "$TMUX_DIR/.." && pwd)"
WRAPPER="$REPO_DIR/setup/templates/tmux-resurrect-restore.sh"
SAVE_WRAPPER="$TMUX_DIR/scripts/resurrect_save.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/boot-restore-test.XXXXXX")"
holders=()
cleanup() {
  local p
  for p in ${holders[@]+"${holders[@]}"}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] && { echo "kept $TEST_ROOT"; return; }; rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '     got:  %s\n     want: %s\n' "$2" "$3"; fi; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

FT="$TEST_ROOT/ft"
BIN="$TEST_ROOT/bin"
PLUGIN="$TEST_ROOT/plugin"
mkdir -p "$FT" "$BIN" "$PLUGIN/scripts" "$TEST_ROOT/resurrect" "$TEST_ROOT/state" "$TEST_ROOT/tmp" "$TEST_ROOT/server-tmp"
export FT

cat >"$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
# Stateful fake server: $FT/server (up), $FT/sessions, $FT/pid.
printf '%s\n' "$*" >>"$FT/calls"
while [ "${1:-}" = "-f" ] || [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; do shift 2; done
cmd="${1:-}"; shift
target="" fmt="" name=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) target="${2#=}"; shift 2 ;;
    -s) name="$2"; shift 2 ;;
    -c) shift 2 ;;
    -F) fmt="$2"; shift 2 ;;
    -*) shift ;;
    *) [ -z "$fmt" ] && fmt="$1"; shift ;;
  esac
done
up() { [ -e "$FT/server" ]; }
case "$cmd" in
  new-session)
    if ! up; then
      : >"$FT/server"; : >"$FT/sessions"
      if [ "${FAKE_CONTINUUM:-0}" = 1 ]; then
        ( sleep 0.5
          # Continuum runs inside the server, with the server's TMPDIR.
          TMPDIR="$FAKE_SERVER_TMPDIR" TMUX="$FT/socket,$(cat "$FT/pid"),0" \
            bash "$FAKE_GUARDED" >>"$FT/continuum.log" 2>&1 ) &
      fi
    fi
    printf '%s\n' "$name" >>"$FT/sessions"
    ;;
  list-sessions) up || exit 1; [ -s "$FT/sessions" ] || exit 1; cat "$FT/sessions" ;;
  has-session) up && grep -qx -- "$target" "$FT/sessions" ;;
  kill-session)
    grep -vx -- "$target" "$FT/sessions" >"$FT/s.tmp"; mv "$FT/s.tmp" "$FT/sessions"
    [ -s "$FT/sessions" ] || rm -f "$FT/server"
    ;;
  display-message)
    up || exit 1
    fmt="${fmt//'#{socket_path}'/$FT/socket}"
    printf '%s\n' "${fmt//'#{pid}'/$(cat "$FT/pid")}"
    ;;
  show-environment) printf 'TMPDIR=%s\n' "$FAKE_SERVER_TMPDIR" ;;
  show-option)
    case "${fmt}" in
      @resurrect-dir) printf '%s\n' "$FAKE_RESURRECT_DIR" ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF

# Fake upstream restore: $FAKE_MODE ok | fail-empty | fail-partial. It must
# run with TMUX naming the server (the real one creates sessions through it).
cat >"$PLUGIN/scripts/restore.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${TMUX:-<unset>}" >>"$FT/restore-tmux-env"
[ -n "${TMUX:-}" ] || exit 3
case "${FAKE_MODE:-ok}" in
  ok)
    printf '%s\n' work rw-abcd1234-ep1 >>"$FT/sessions"
    printf 'success\n' >"$TMUX_WORKSPACE_RESTORE_RESULT_FILE"
    ;;
  fail-empty) exit 1 ;;
  fail-partial) printf '%s\n' work >>"$FT/sessions"; exit 1 ;;
esac
EOF
cat >"$PLUGIN/scripts/save.sh" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
cat >"$TEST_ROOT/post-restore.sh" <<'EOF'
#!/usr/bin/env bash
printf 'post-restore\n' >>"$FT/post"
EOF
chmod +x "$BIN/tmux" "$PLUGIN/scripts/restore.sh" "$PLUGIN/scripts/save.sh" "$TEST_ROOT/post-restore.sh"
ln -s last-snapshot.txt "$TEST_ROOT/resurrect/last"
: >"$TEST_ROOT/resurrect/last-snapshot.txt"

export PATH="$BIN:$PATH"
export TMPDIR="$TEST_ROOT/tmp"
export FAKE_SERVER_TMPDIR="$TEST_ROOT/server-tmp"
export FAKE_RESURRECT_DIR="$TEST_ROOT/resurrect"
export FAKE_GUARDED="$TMUX_DIR/scripts/resurrect_restore.sh"
export TMUX_RESURRECT_RESTORE_TMUX_BIN="$BIN/tmux"
export TMUX_RESURRECT_SAVE_TMUX_BIN="$BIN/tmux"
export TMUX_RESURRECT_RESTORE_PLUGIN_DIR="$PLUGIN"
export TMUX_RESURRECT_SAVE_PLUGIN_DIR="$PLUGIN"
export TMUX_RESURRECT_GUARDED_RESTORE_SCRIPT="$FAKE_GUARDED"
export TMUX_RESURRECT_RW_POST_RESTORE_SCRIPT="$TEST_ROOT/post-restore.sh"
export TMUX_RESURRECT_RESTORE_TMUX_CONF="$TEST_ROOT/none.conf"
export TMUX_RESURRECT_RESTORE_DIR="$TEST_ROOT/resurrect"
export TMUX_WORKSPACE_RESURRECT_STATE_DIR="$TEST_ROOT/state"
export TMUX_RESURRECT_RESTORE_CONTINUUM_WAIT=0
export TMUX_RESURRECT_BOOT_TIME=1000
export TMUX_RESURRECT_SAVE_TIMEOUT_SECONDS=30
unset TMUX TMUX_PANE

LOCK="$TEST_ROOT/state/boot-restore.lock"
marker() { printf '%s/tmux-resurrect-%s-restore-incomplete\n' "$FAKE_SERVER_TMPDIR" "$(cat "$FT/pid")"; }
reset_server() { # reset_server <pid> [session...]
  rm -f "$FT/server" "$FT/sessions" "$FT/post" "$FT/restore-tmux-env" "$FT/calls"
  printf '%s\n' "$1" >"$FT/pid"
  shift
  if [ "$#" -gt 0 ]; then : >"$FT/server"; printf '%s\n' "$@" >"$FT/sessions"; fi
}
sessions() { tr '\n' ' ' <"$FT/sessions" 2>/dev/null | sed 's/ $//'; }
run() { "$WRAPPER"; }

# 1. No server: start one, restore here (no Continuum), drop the bootstrap
#    session, run the post-restore.
reset_server 4201
run
eq "1: no server -> exit 0" "$?" "0"
eq "1: restored sessions, bootstrap session gone" "$(sessions)" "work rw-abcd1234-ep1"
check "1: marker cleared" test ! -e "$(marker)"
check "1: restore ran with TMUX naming the server" grep -q "^$FT/socket,4201,0$" "$FT/restore-tmux-env"
eq "1: post-restore ran once" "$(wc -l <"$FT/post" | tr -d ' ')" "1"
check "1: boot lock released" test ! -e "$LOCK"

# 2. Live server with sessions: no-op.
rm -f "$FT/post" "$FT/restore-tmux-env"
run
eq "2: live server -> exit 0" "$?" "0"
check "2: no restore ran" test ! -e "$FT/restore-tmux-env"
check "2: no post-restore" test ! -e "$FT/post"

# 3. Continuum restores: the wrapper waits for it instead of racing.
reset_server 4203
FAKE_CONTINUUM=1 TMUX_RESURRECT_RESTORE_CONTINUUM_WAIT=5 run
eq "3: Continuum restore -> exit 0" "$?" "0"
eq "3: exactly one restore ran" "$(wc -l <"$FT/restore-tmux-env" | tr -d ' ')" "1"
eq "3: sessions" "$(sessions)" "work rw-abcd1234-ep1"
check "3: post-restore ran" test -e "$FT/post"

# 4. Live server holding only the bootstrap session with an incomplete
#    marker (a restore died before restoring anything): restore again.
reset_server 4204 _tmux_restore_boot
printf 'x\n' >"$(marker)"
run
eq "4: bootstrap-only server is restored -> exit 0" "$?" "0"
eq "4: sessions" "$(sessions)" "work rw-abcd1234-ep1"
check "4: marker cleared" test ! -e "$(marker)"

# 5. A restore that fails without restoring anything is retried, then given
#    up; the bootstrap server is stopped.
reset_server 4205
FAKE_MODE=fail-empty run
eq "5: failing restore -> exit 1" "$?" "1"
eq "5: two guarded restore attempts" "$(wc -l <"$FT/restore-tmux-env" | tr -d ' ')" "2"
check "5: bootstrap server stopped" test ! -e "$FT/server"

# 6. A partial restore is never restored over; saves stay blocked.
reset_server 4206
FAKE_MODE=fail-partial run
eq "6: partial restore -> exit 1" "$?" "1"
eq "6: one attempt only" "$(wc -l <"$FT/restore-tmux-env" | tr -d ' ')" "1"
check "6: marker kept" test -e "$(marker)"
FAKE_MODE=fail-partial run
eq "6: rerun on the partial server -> exit 1, no restore over it" "$?:$(wc -l <"$FT/restore-tmux-env" | tr -d ' ')" "1:1"
"$WRAPPER" --restoring
eq "6: --restoring reports the incomplete restore" "$?" "0"

# 7. Boot lock: a live owner from this boot blocks (exit 75, --restoring
#    true, saves refused); one from an earlier boot is stale.
reset_server 4207 work
sleep 30 &
holder=$!
holders+=("$holder")
mkdir -p "$LOCK"
printf '%s\n' "$holder" >"$LOCK/pid"
printf '%s\n' 1000 >"$LOCK/boot"
TMUX_RESURRECT_RESTORE_LOCK_TIMEOUT=1 run
eq "7: live boot lock past the timeout -> exit 75" "$?" "75"
"$WRAPPER" --restoring
eq "7: --restoring with a live boot lock" "$?" "0"
"$SAVE_WRAPPER" 2>"$TEST_ROOT/save.err"
check "7: verified save refuses during a boot restore" grep -q 'boot restore in progress' "$TEST_ROOT/save.err"
printf '%s\n' 999 >"$LOCK/boot"
"$WRAPPER" --restoring
eq "7: lock from an earlier boot (pid alive, recycled) is not live" "$?" "1"
"$SAVE_WRAPPER" 2>"$TEST_ROOT/save.err"
check "7: save ignores a lock from an earlier boot" bash -c "! grep -q 'boot restore in progress' '$TEST_ROOT/save.err'"
run
eq "7: wrapper reclaims the earlier-boot lock -> exit 0" "$?" "0"
check "7: stale lock replaced and released" test ! -e "$LOCK"

# 8. The verified save names its lifecycle paths from the SERVER's TMPDIR.
reset_server 4208 work
: >"$FAKE_SERVER_TMPDIR/tmux-resurrect-4208-restore-incomplete"
"$SAVE_WRAPPER" 2>"$TEST_ROOT/save.err"
check "8: save sees the marker under the server's TMPDIR" grep -q 'restore is incomplete' "$TEST_ROOT/save.err"
rm -f "$FAKE_SERVER_TMPDIR/tmux-resurrect-4208-restore-incomplete"
: >"$TMPDIR/tmux-resurrect-4208-restore-incomplete"
"$SAVE_WRAPPER" 2>"$TEST_ROOT/save.err"
check "8: a marker under the caller's own TMPDIR is not the server's" bash -c "! grep -q 'restore is incomplete' '$TEST_ROOT/save.err'"

# 9. No snapshot: nothing starts.
reset_server 4209
TMUX_RESURRECT_RESTORE_DIR="$TEST_ROOT/empty" run
eq "9: no snapshot -> exit 0" "$?" "0"
check "9: no server started" test ! -e "$FT/server"

printf 'boot_restore_test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
