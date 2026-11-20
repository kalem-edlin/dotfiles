#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# libexec/rw-push-file (contracts C1, C3, decision D2 in
# docs/tasks/drop-to-remote-paste.md): the D2 mapping, exit codes 0/1/2,
# output only after every copy, the ssh/scp option shapes, and quoting of
# hostile file names. Stub tmux (pane table), same-host fake ssh, fake scp.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

PUSH="$RW_PLUGIN/libexec/rw-push-file"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
export FAKE_SCP_LOG="$SANDBOX/scp.log"
printf 'pane_id=%%5\t@rw-endpoint=ep000001\npane_id=%%6\tpane_current_path=/x\n' >"$FAKE_TMUX_PANES"

# Fake scp: logs argv, copies <src> to the path after "host:". FAKE_SCP_FAIL=1
# fails every copy; FAKE_SCP_FAIL_ON=<substring> fails a matching source.
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
src="${args[0]}"
dst="${args[${#args[@]}-1]}"
case "$src" in *"${FAKE_SCP_FAIL_ON:-/nonexistent-never}"*) echo "scp: fake failure" >&2; exit 1 ;; esac
cp -- "$src" "${dst#*:}"
EOF
chmod +x "$SANDBOX/bin/scp"
export RW_SCP_BIN="$SANDBOX/bin/scp"

ws="$HOME/Developer/idol-app"
wws="$FAKE_WORKER_HOME/Developer/idol-app"
mkdir -p "$ws/assets" "$HOME/Desktop" "$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints" "$SANDBOX/outside/a" "$SANDBOX/outside/b"
jq -n --arg wh "$FAKE_WORKER_HOME" --arg fp "$ws" --arg rp "$wws" \
  '{endpoint_id: "ep000001", worker: "fakeworker", worker_home: $wh, workspace: {focus_path: $fp, remote_path: $rp}}' \
  >"$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints/ep000001.json"
echo png >"$ws/assets/shot.png"
echo desk >"$HOME/Desktop/note.txt"
echo out >"$SANDBOX/outside/a/same.txt"
echo out2 >"$SANDBOX/outside/b/same.txt"
weird="$HOME/Desktop/a b;\$(touch PWNED)'q\"*.png"
echo weird >"$weird"

# --- mapping (D2) -------------------------------------------------------------
out="$("$PUSH" %5 "$ws/assets/shot.png")"
eq "inside the workspace: exit 0" "$?" "0"
eq "inside the workspace: remote_path + path relative to focus_path" "$out" "$wws/assets/shot.png"
check "inside the workspace: the file is on the worker" cmp -s "$ws/assets/shot.png" "$wws/assets/shot.png"

out="$("$PUSH" %5 "$HOME/Desktop/note.txt")"
eq "elsewhere under home: worker_home + path relative to home" "$out" "$FAKE_WORKER_HOME/Desktop/note.txt"
check "elsewhere under home: the file is on the worker" cmp -s "$HOME/Desktop/note.txt" "$FAKE_WORKER_HOME/Desktop/note.txt"

out="$("$PUSH" %5 "$SANDBOX/outside/a/same.txt")"
eq "outside home: worker_home/rw-drops/<basename>" "$out" "$FAKE_WORKER_HOME/rw-drops/same.txt"
check "outside home: the file is on the worker" cmp -s "$SANDBOX/outside/a/same.txt" "$FAKE_WORKER_HOME/rw-drops/same.txt"

ln -s "$ws" "$HOME/link-to-app"
out="$("$PUSH" %5 "$HOME/link-to-app/assets/shot.png")"
eq "a symlinked laptop directory maps by its physical path" "$out" "$wws/assets/shot.png"

out="$("$PUSH" %5 "$ws/assets/shot.png" "$HOME/Desktop/note.txt" "$SANDBOX/outside/a/same.txt")"
eq "several files: one line each, in input order" "$out" "$wws/assets/shot.png
$FAKE_WORKER_HOME/Desktop/note.txt
$FAKE_WORKER_HOME/rw-drops/same.txt"

: >"$SANDBOX/scp.log"
: >"$FAKE_SSH_LOG"
out="$("$PUSH" %5 "$weird")"
eq "hostile file name: exit 0" "$?" "0"
eq "hostile file name: mapped verbatim" "$out" "$FAKE_WORKER_HOME/Desktop/a b;\$(touch PWNED)'q\"*.png"
check "hostile file name: copied byte for byte" cmp -s "$weird" "$FAKE_WORKER_HOME/Desktop/a b;\$(touch PWNED)'q\"*.png"
check "hostile file name: nothing ran on the worker" test ! -e "$FAKE_WORKER_HOME/PWNED"
check "hostile file name: nothing ran on the laptop" test ! -e "$HOME/PWNED"

# --- transport shapes (C3) -------------------------------------------------------
check "ssh: one call for the mkdir" test "$(wc -l <"$FAKE_SSH_LOG" | tr -d ' ')" = 1
check "ssh: runs mkdir -p" grep -q "mkdir -p -- '$FAKE_WORKER_HOME/Desktop'" "$FAKE_SSH_LOG"
check "scp: ControlMaster=no" grep -q -- "-o ControlMaster=no" "$SANDBOX/scp.log"
check "scp: BatchMode=yes" grep -q -- "-o BatchMode=yes" "$SANDBOX/scp.log"
check "scp: ConnectTimeout=5" grep -q -- "-o ConnectTimeout=5" "$SANDBOX/scp.log"
check "scp: the stream ControlPath" grep -q -- "-o ControlPath=~/.ssh/sockets/rw-stream-%C" "$SANDBOX/scp.log"
check "scp: SFTP mode (-s), so no remote shell parses the path" grep -q -- " -s -q -- " "$SANDBOX/scp.log"
: >"$FAKE_SSH_LOG"
cat >"$SANDBOX/bin/ssh-logopts" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SANDBOX_SSHARGS"
exec "$(dirname "$0")/ssh" "$@"
EOF
chmod +x "$SANDBOX/bin/ssh-logopts"
FAKE_SANDBOX_SSHARGS="$SANDBOX/sshargs" RW_SSH_BIN="$SANDBOX/bin/ssh-logopts" "$PUSH" %5 "$ws/assets/shot.png" >/dev/null
check "ssh: ControlMaster=no BatchMode=yes ConnectTimeout=5" \
  grep -q -- "-o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=5 fakeworker mkdir" "$SANDBOX/sshargs"

# --- exit 2: not a remote workspace pane ------------------------------------------
out="$("$PUSH" %6 "$ws/assets/shot.png")"
eq "a local pane: exit 2" "$?" "2"
eq "a local pane: prints nothing" "$out" ""
out="$("$PUSH" %77 "$ws/assets/shot.png")"
eq "an unknown pane: exit 2" "$?" "2"
printf 'pane_id=%%8\t@rw-endpoint=gone0001\n' >>"$FAKE_TMUX_PANES"
out="$("$PUSH" %8 "$ws/assets/shot.png")"
eq "an endpoint without a record: exit 2" "$?" "2"

# --- exit 1: failures, and nothing printed -----------------------------------------
out="$(FAKE_SCP_FAIL=1 "$PUSH" %5 "$ws/assets/shot.png" 2>/dev/null)"
eq "scp fails: exit 1" "$?" "1"
eq "scp fails: prints nothing" "$out" ""
out="$(FAKE_SCP_FAIL_ON=note.txt "$PUSH" %5 "$ws/assets/shot.png" "$HOME/Desktop/note.txt" 2>/dev/null)"
eq "second of two copies fails: exit 1" "$?" "1"
eq "second of two copies fails: prints nothing (no half list)" "$out" ""
touch "$FAKE_SSH_DOWN"
out="$("$PUSH" %5 "$ws/assets/shot.png" 2>/dev/null)"
eq "worker unreachable: exit 1" "$?" "1"
eq "worker unreachable: prints nothing" "$out" ""
rm -f "$FAKE_SSH_DOWN"
out="$("$PUSH" %5 "$ws/assets/missing.png" 2>/dev/null)"
eq "a missing file: exit 1" "$?" "1"
out="$("$PUSH" %5 "$ws/assets" 2>/dev/null)"
eq "a directory: exit 1" "$?" "1"
out="$("$PUSH" %5 "$SANDBOX/outside/a/same.txt" "$SANDBOX/outside/b/same.txt" 2>/dev/null)"
eq "two outside files with one basename: exit 1 (never overwrite)" "$?" "1"
eq "two outside files with one basename: prints nothing" "$out" ""
"$PUSH" %5 >/dev/null 2>&1
eq "usage: exit 64" "$?" "64"

# --- scripts/rw-paste-image.sh (prefix C-v) with a fake osascript ---------------------
# FAKE_CLIPBOARD_HEX set: the pasteboard holds that PNG; unset: no image.
cat >"$SANDBOX/bin/osascript" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_CLIPBOARD_HEX:-}" ] || { echo "execution error: Can't make some data into the expected type. (-1700)" >&2; exit 1; }
printf '\302\253data PNGf%s\302\273\n' "$FAKE_CLIPBOARD_HEX"
EOF
chmod +x "$SANDBOX/bin/osascript"
IMG="$RW_PLUGIN/scripts/rw-paste-image.sh"
png_hex="89504E470D0A1A0A0000000D4948445200000001"

: >"$FAKE_TMUX_LOG"
out="$(bash "$IMG" %5 2>&1)"
eq "paste-image, no image: exit 0" "$?" "0"
eq "paste-image, no image: prints nothing (run-shell would show it)" "$out" ""
check "paste-image, no image: one display-message" grep -q "^display-message -t %5 rw: no image on the clipboard" "$FAKE_TMUX_LOG"
check "paste-image, no image: nothing typed" bash -c "! grep -q '^send-keys' '$FAKE_TMUX_LOG'"

: >"$FAKE_TMUX_LOG"
out="$(FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 2>&1)"
eq "paste-image, remote pane: exit 0, prints nothing" "$?:$out" "0:"
clips=("$HOME/Pictures/rw-clips/"*.png)
clip="${clips[0]##*/}"
check "paste-image: saved as <UTC %Y%m%dT%H%M%SZ>.png" bash -c "[[ '$clip' =~ ^[0-9]{8}T[0-9]{6}Z\.png$ ]]"
check "paste-image: the saved bytes are the decoded PNG" \
  test "$(xxd -p "$HOME/Pictures/rw-clips/$clip" | tr -d '\n')" = "$(printf '%s' "$png_hex" | tr 'A-F' 'a-f')"
check "paste-image, remote pane: the image is on the worker under Pictures/rw-clips" \
  cmp -s "$HOME/Pictures/rw-clips/$clip" "$FAKE_WORKER_HOME/Pictures/rw-clips/$clip"
check "paste-image, remote pane: the worker path is typed literally" \
  grep -qxF "send-keys -t %5 -l -- $FAKE_WORKER_HOME/Pictures/rw-clips/$clip" "$FAKE_TMUX_LOG"

: >"$FAKE_TMUX_LOG"
rm -f "$HOME/Pictures/rw-clips/"*.png
FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %6 >/dev/null 2>&1
clips=("$HOME/Pictures/rw-clips/"*.png)
clip="${clips[0]##*/}"
check "paste-image, local pane: the laptop path is typed" \
  grep -qxF "send-keys -t %6 -l -- $HOME/Pictures/rw-clips/$clip" "$FAKE_TMUX_LOG"

: >"$FAKE_TMUX_LOG"
FAKE_SCP_FAIL=1 FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 >/dev/null 2>&1
check "paste-image, copy fails: one display-message" grep -q "^display-message -t %5 rw: copying the clipboard image to the worker failed" "$FAKE_TMUX_LOG"
check "paste-image, copy fails: nothing typed" bash -c "! grep -q '^send-keys' '$FAKE_TMUX_LOG'"

: >"$FAKE_TMUX_LOG"
FAKE_CLIPBOARD_HEX="0011223344" bash "$IMG" %5 >/dev/null 2>&1
check "paste-image, not a PNG: treated as no image" grep -q "^display-message -t %5 rw: no image on the clipboard" "$FAKE_TMUX_LOG"

finish
