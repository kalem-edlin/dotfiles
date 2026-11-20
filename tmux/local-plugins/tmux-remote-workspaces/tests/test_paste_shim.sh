#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# libexec/rw-paste-shim (contracts C1, C2, C4 in
# docs/tasks/drop-to-remote-paste.md), headless: the "terminal" is a pty the
# test holds, the child is a fake `tmux` that records every byte it reads,
# the pane lookup and display-message answer from environment variables,
# and scp is a fake. No tmux server, no ssh, no network.
#
# The cases live in paste_shim_driver.py (it needs ptys); this file builds
# the sandbox and the fakes, lints the new files (C4), and runs it.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

SHIM="$RW_PLUGIN/libexec/rw-paste-shim"
REPO="$(cd "$RW_PLUGIN/../../.." && pwd)"

# --- lint (C4) ----------------------------------------------------------------
check "py_compile: rw-paste-shim" /usr/bin/python3 -c \
  'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$SHIM"
for f in "$RW_PLUGIN/libexec/rw-push-file" "$RW_PLUGIN/scripts/rw-paste-image.sh" \
  "$RW_TEST_DIR/test_paste_shim.sh" "$RW_TEST_DIR/test_push_file.sh"; do
  check "bash -n: ${f#"$RW_PLUGIN"/}" bash -n "$f"
  if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # expanded by the inner bash
    check "shellcheck: ${f#"$RW_PLUGIN"/}" bash -c 'cd "$(dirname "$1")" && shellcheck -x "$(basename "$1")"' _ "$f"
  fi
done
check "zsh -n: zsh/.zsh/tmux-paste-shim.zsh" zsh -n "$REPO/zsh/.zsh/tmux-paste-shim.zsh"

# --- fakes ------------------------------------------------------------------------
export FAKE_MESSAGES="$SANDBOX/messages.log"
export FAKE_LOOKUP_TTYS="$SANDBOX/lookups.log"
export FAKE_CHILD="$SANDBOX/fake_child.py"
export FAKE_SCP_LOG="$SANDBOX/scp.log"

# The only tmux any of this sees. As a client command (new/attach) it
# becomes the fake child; display-message -p answers the pane lookup from
# FAKE_PANE / FAKE_ENDPOINT (FAKE_LOOKUP_SLEEP / FAKE_LOOKUP_RC for a slow
# or failing server); display-message without -p appends to FAKE_MESSAGES.
cat >"$SANDBOX/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  display-message)
    shift
    p=0 t=""
    while [ $# -gt 1 ]; do
      case "$1" in
        -p) p=1; shift ;;
        -t | -c) t="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    if [ "$p" = 1 ]; then
      case "$t" in
        /dev/*)
          printf '%s\n' "$t" >>"$FAKE_LOOKUP_TTYS"
          [ -n "${FAKE_LOOKUP_SLEEP:-}" ] && sleep "$FAKE_LOOKUP_SLEEP"
          [ "${FAKE_LOOKUP_RC:-0}" = 0 ] || exit "$FAKE_LOOKUP_RC"
          ;;
      esac
      f="$1"
      f="${f//"#{pane_id}"/${FAKE_PANE:-%5}}"
      f="${f//"#{@rw-endpoint}"/${FAKE_ENDPOINT:-}}"
      printf '%s\n' "$f"
    else
      printf '%s\t%s\n' "$t" "$1" >>"$FAKE_MESSAGES"
    fi
    ;;
  '' | new | new-session | attach | attach-session | a | at)
    exec /usr/bin/python3 "$FAKE_CHILD"
    ;;
esac
exit 0
EOF

# The fake tmux client: raw mode on its tty, records every byte it reads to
# FAKE_RECV, prints READY, optionally TICK every FAKE_CHILD_TICK seconds
# (output that must keep flowing while a copy is pending), exits with
# FAKE_CHILD_EXIT once it has read the sentinel NUL "QUIT", and on NUL "STOP"
# sends itself SIGTSTP like tmux suspend-client, then prints RESUMED.
cat >"$FAKE_CHILD" <<'EOF'
import os, select, signal, sys, tty
with open(os.environ["FAKE_CHILD_TTY_FILE"], "w") as f:
    f.write(os.ttyname(0))
with open(os.environ["FAKE_CHILD_TTY_FILE"] + ".env", "w") as f:
    f.write(os.environ.get("RW_PASTE_SHIM", ""))
tty.setraw(0)
os.write(1, b"READY\r\n")
tick = float(os.environ.get("FAKE_CHILD_TICK") or 0)
fd = os.open(os.environ["FAKE_RECV"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
tail = b""
while True:
    r, _, _ = select.select([0], [], [], tick if tick > 0 else None)
    if not r:
        os.write(1, b"TICK")
        continue
    try:
        d = os.read(0, 65536)
    except OSError:
        break
    if not d:
        break
    os.write(fd, d)
    tail = (tail + d)[-5:]
    if tail == b"\x00QUIT":
        sys.exit(int(os.environ.get("FAKE_CHILD_EXIT") or 0))
    if tail == b"\x00STOP":  # what tmux suspend-client does
        os.kill(os.getpid(), signal.SIGTSTP)
        os.write(1, b"RESUMED")
EOF

cat >"$SANDBOX/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SCP_LOG:-/dev/null}"
[ -n "${FAKE_SCP_SLEEP:-}" ] && sleep "$FAKE_SCP_SLEEP"
[ "${FAKE_SCP_FAIL:-0}" = 1 ] && { echo "scp: fake failure" >&2; exit 1; }
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; args+=("$@"); break ;;
    -*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
cp -- "${args[0]}" "${args[${#args[@]}-1]#*:}"
EOF
chmod +x "$SANDBOX/bin/tmux" "$SANDBOX/bin/scp"
export RW_SCP_BIN="$SANDBOX/bin/scp"

ws="$HOME/Developer/idol-app"
mkdir -p "$ws/assets" "$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints"
jq -n --arg wh "$FAKE_WORKER_HOME" --arg fp "$ws" --arg rp "$FAKE_WORKER_HOME/Developer/idol-app" \
  '{endpoint_id: "ep000001", worker: "fakeworker", worker_home: $wh, workspace: {focus_path: $fp, remote_path: $rp}}' \
  >"$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints/ep000001.json"
export SANDBOX WS="$ws"

/usr/bin/python3 "$RW_TEST_DIR/paste_shim_driver.py" "$SHIM"
driver=$?
[ "$driver" -eq 0 ] || bad "paste_shim_driver.py: exit $driver (see FAIL lines above)"
[ "$driver" -ne 0 ] || ok "paste_shim_driver.py: every case passed"

finish
