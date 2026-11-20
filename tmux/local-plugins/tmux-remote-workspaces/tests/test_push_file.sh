#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# libexec/rw-push-file (contracts C1, C3, C5, decision D2 in
# docs/tasks/drop-to-remote-paste.md): the D2 mapping, the C5 overwrite
# policy (identical skips, anything else goes to rw-drops, temp name then
# rename), the intercept scope, the transport order (shared master, stream
# master, direct; each check bounded), exit codes, output only after every
# copy, and hostile file names. Then scripts/rw-paste-image.sh (prefix C-v).
# Stub tmux (pane table), same-host fake ssh, fake sftp (paste_fakes.sh).

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=paste_fakes.sh
source "$RW_TEST_DIR/paste_fakes.sh"
paste_fakes_install

PUSH="$RW_PLUGIN/libexec/rw-push-file"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
printf 'pane_id=%%5\t@rw-endpoint=ep000001\tpane_current_command=zsh\tpane_in_mode=0\npane_id=%%6\tpane_current_path=/x\tpane_current_command=zsh\tpane_in_mode=0\n' >"$FAKE_TMUX_PANES"

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
weird="$HOME/Desktop/a b;\$(touch PWNED)'q*?[1].png"
echo weird >"$weird"
reset_logs() { : >"$FAKE_TRANSPORT_LOG"; : >"$FAKE_SFTP_LOG"; }
count() { grep -c "$1" "$2" | tr -d ' '; }

# --- mapping (D2): nothing at the target -> uploaded there ------------------------------
reset_logs
out="$("$PUSH" %5 "$ws/assets/shot.png")"
eq "inside the workspace: exit 0" "$?" "0"
eq "inside the workspace: remote_path + path relative to focus_path" "$out" "$wws/assets/shot.png"
check "inside the workspace: the file is on the worker" cmp -s "$ws/assets/shot.png" "$wws/assets/shot.png"
check "upload goes to a temporary .part name, then a rename into place" \
  grep -qE "^put	.*	$wws/assets/\.rw-drop-[^	]*\.part$" "$FAKE_SFTP_LOG"
check "  ... and the rename targets the final name" grep -qE "^rename	.*\.part	$wws/assets/shot\.png$" "$FAKE_SFTP_LOG"
check "no .part file is left behind" bash -c "! ls -a '$wws/assets' | grep -q part"
eq "one ssh (parents + target report) and one sftp batch" \
  "$(count '^ssh ' "$FAKE_TRANSPORT_LOG") $(count '^sftp ' "$FAKE_TRANSPORT_LOG")" "1 1"

out="$("$PUSH" %5 "$HOME/Desktop/note.txt")"
eq "elsewhere under home: worker_home + path relative to home" "$out" "$FAKE_WORKER_HOME/Desktop/note.txt"
check "elsewhere under home: the file is on the worker" cmp -s "$HOME/Desktop/note.txt" "$FAKE_WORKER_HOME/Desktop/note.txt"

out="$("$PUSH" %5 "$SANDBOX/outside/a/same.txt")"
eq "outside home (in scope): worker_home/rw-drops/<basename>" "$out" "$FAKE_WORKER_HOME/rw-drops/same.txt"
check "outside home: the file is on the worker" cmp -s "$SANDBOX/outside/a/same.txt" "$FAKE_WORKER_HOME/rw-drops/same.txt"

ln -s "$ws" "$HOME/link-to-app"
out="$("$PUSH" %5 "$HOME/link-to-app/assets/shot.png")"
eq "a symlinked laptop directory maps by its physical path" "$out" "$wws/assets/shot.png"

# --- overwrite policy (C5) -------------------------------------------------------------------
reset_logs
out="$("$PUSH" %5 "$ws/assets/shot.png")"
eq "identical file at the target: exit 0, the target path" "$?:$out" "0:$wws/assets/shot.png"
eq "identical file at the target: nothing uploaded (no sftp)" "$(count '^sftp ' "$FAKE_TRANSPORT_LOG")" "0"

echo "the worker's own edit" >"$wws/assets/shot.png"
out="$("$PUSH" %5 "$ws/assets/shot.png")"
eq "a different file at the target: exit 0" "$?" "0"
check "a different file at the target: goes to rw-drops/<stem>-<suffix>.png" \
  bash -c "[[ '$out' =~ ^$FAKE_WORKER_HOME/rw-drops/shot-[0-9]{8}T[0-9]{6}Z-[0-9]+\\.png$ ]]"
eq "a different file at the target: the worker's file is untouched" "$(cat "$wws/assets/shot.png")" "the worker's own edit"
check "a different file at the target: the laptop file is at the printed path" cmp -s "$ws/assets/shot.png" "$out"

mkdir -p "$ws/assets/dir.png" "$wws/assets/dir.png"
rmdir "$ws/assets/dir.png"
echo d >"$ws/assets/dir.png"
out="$("$PUSH" %5 "$ws/assets/dir.png")"
check "a directory at the target: goes to rw-drops, nothing put inside it" \
  bash -c "[[ '$out' == $FAKE_WORKER_HOME/rw-drops/dir-*.png ]] && [ -z \"\$(ls -A '$wws/assets/dir.png')\" ]"

mkdir -p "$HOME/Desktop/blocked"
echo b >"$HOME/Desktop/blocked/f.txt"
echo "a file where the parent should be" >"$FAKE_WORKER_HOME/Desktop/blocked"
out="$("$PUSH" %5 "$HOME/Desktop/blocked/f.txt")"
check "no usable parent on the worker: goes to rw-drops" bash -c "[[ '$out' == $FAKE_WORKER_HOME/rw-drops/f-*.txt ]]"

rm -rf "$FAKE_WORKER_HOME/rw-drops"
out="$("$PUSH" %5 "$SANDBOX/outside/a/same.txt" "$SANDBOX/outside/b/same.txt")"
eq "two outside files with one basename: exit 0" "$?" "0"
first="$(printf '%s\n' "$out" | sed -n 1p)"
second="$(printf '%s\n' "$out" | sed -n 2p)"
eq "  ... the first lands at rw-drops/<basename>" "$first" "$FAKE_WORKER_HOME/rw-drops/same.txt"
check "  ... the second gets a unique name, nothing is clobbered" \
  bash -c "[[ '$second' == $FAKE_WORKER_HOME/rw-drops/same-*.txt ]] && [ \"\$(cat '$first')\" = out ] && [ \"\$(cat '$second')\" = out2 ]"

reset_logs
out="$("$PUSH" %5 "$ws/assets/shot.png" "$HOME/Desktop/note.txt" "$SANDBOX/outside/a/same.txt")"
eq "several files: one line each, in input order" "$(printf '%s\n' "$out" | sed -n '2p;3p')" "$FAKE_WORKER_HOME/Desktop/note.txt
$FAKE_WORKER_HOME/rw-drops/same.txt"
eq "several files: still one ssh" "$(count '^ssh ' "$FAKE_TRANSPORT_LOG")" "1"

# --- hostile names -----------------------------------------------------------------------------
out="$("$PUSH" %5 "$weird")"
eq "hostile file name: exit 0" "$?" "0"
eq "hostile file name: mapped verbatim" "$out" "$FAKE_WORKER_HOME/Desktop/a b;\$(touch PWNED)'q*?[1].png"
check "hostile file name: copied byte for byte" cmp -s "$weird" "$FAKE_WORKER_HOME/Desktop/a b;\$(touch PWNED)'q*?[1].png"
check "hostile file name: nothing ran on the worker" test ! -e "$FAKE_WORKER_HOME/PWNED"
check "hostile file name: nothing ran on the laptop" test ! -e "$HOME/PWNED"
quoted="$HOME/Desktop/say \"hi\" \\ there.txt"
echo q >"$quoted"
out="$("$PUSH" %5 "$quoted")"
check "a name with \" or \\ (not expressible in the sftp batch): sanitized into rw-drops" \
  bash -c "[[ '${out//\'/}' == $FAKE_WORKER_HOME/rw-drops/say\ _hi_\ _\ there-*.txt ]] && cmp -s '${quoted//\'/}' '${out//\'/}'"

# --- scope (C5) -----------------------------------------------------------------------------------
reset_logs
out="$("$PUSH" %5 /etc/hosts)"
eq "outside the intercept scope (/etc/hosts): exit 3, prints nothing" "$?:$out" "3:"
eq "outside the scope: no transport at all" "$(wc -l <"$FAKE_TRANSPORT_LOG" | tr -d ' ')" "0"

# --- transport order (C5) -------------------------------------------------------------------------
reset_logs
FAKE_MASTER=shared "$PUSH" %5 "$HOME/Desktop/note.txt" >/dev/null
eq "shared master alive: only the shared master is checked" "$(grep '^check' "$FAKE_TRANSPORT_LOG")" "check shared"
check "shared master alive: no ControlPath override, ControlMaster=no" \
  bash -c "grep '^ssh ' '$FAKE_TRANSPORT_LOG' | grep -q -- '-o BatchMode=yes -o ControlMaster=no fakeworker' && ! grep -q ControlPath '$FAKE_TRANSPORT_LOG'"
reset_logs
FAKE_MASTER=stream "$PUSH" %5 "$HOME/Desktop/note.txt" >/dev/null
eq "stream master alive: shared checked, then stream" "$(grep '^check' "$FAKE_TRANSPORT_LOG" | tr '\n' '|')" "check shared|check ~/.ssh/sockets/rw-stream-%C|"
check "stream master alive: ssh uses the stream ControlPath" grep -q -- '^ssh .*-o ControlPath=~/.ssh/sockets/rw-stream-%C fakeworker' "$FAKE_TRANSPORT_LOG"
reset_logs
rm -f "$FAKE_WORKER_HOME/Desktop/note.txt"
"$PUSH" %5 "$HOME/Desktop/note.txt" >/dev/null
check "no master: a direct connection (ControlPath=none, ConnectTimeout=3)" \
  grep -q -- '^ssh .*-o ControlMaster=no -o ControlPath=none -o ConnectTimeout=3 fakeworker' "$FAKE_TRANSPORT_LOG"
check "no master: the sftp batch uses the same options" \
  grep -q -- '^sftp -q -b .* -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=3 fakeworker' "$FAKE_TRANSPORT_LOG"
reset_logs
t0=$(date +%s)
FAKE_CHECK_HANG=8 "$PUSH" %5 "$HOME/Desktop/note.txt" >/dev/null
rc=$?
dt=$(($(date +%s) - t0))
eq "wedged masters: each check is bounded, the push still succeeds (exit 0)" "$rc" "0"
check "wedged masters: done within 4 s (took ${dt}s)" test "$dt" -le 4

# --- exit 2: not a remote workspace pane ----------------------------------------------------------
out="$("$PUSH" %6 "$ws/assets/shot.png")"
eq "a local pane: exit 2, prints nothing" "$?:$out" "2:"
out="$("$PUSH" %77 "$ws/assets/shot.png")"
eq "an unknown pane: exit 2" "$?" "2"
printf 'pane_id=%%8\t@rw-endpoint=gone0001\n' >>"$FAKE_TMUX_PANES"
out="$("$PUSH" %8 "$ws/assets/shot.png")"
eq "an endpoint without a record: exit 2" "$?" "2"

# --- exit 1: failures, and nothing printed --------------------------------------------------------
echo new >"$HOME/Desktop/new1.txt"
out="$(FAKE_SFTP_FAIL=1 "$PUSH" %5 "$HOME/Desktop/new1.txt" 2>/dev/null)"
eq "sftp fails: exit 1, prints nothing" "$?:$out" "1:"
check "sftp fails: nothing at the final name" test ! -e "$FAKE_WORKER_HOME/Desktop/new1.txt"
touch "$FAKE_SSH_DOWN"
out="$("$PUSH" %5 "$HOME/Desktop/new1.txt" 2>/dev/null)"
eq "worker unreachable: exit 1, prints nothing" "$?:$out" "1:"
rm -f "$FAKE_SSH_DOWN"
out="$("$PUSH" %5 "$ws/assets/missing.png" 2>/dev/null)"
eq "a missing file: exit 1" "$?" "1"
out="$("$PUSH" %5 "$ws/assets" 2>/dev/null)"
eq "a directory: exit 1" "$?" "1"
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
clips_dir="$HOME/Pictures/rw-clips"

: >"$FAKE_TMUX_LOG"
out="$(bash "$IMG" %5 2>&1)"
eq "paste-image, no image: exit 0" "$?" "0"
eq "paste-image, no image: prints nothing (run-shell would show it)" "$out" ""
check "paste-image, no image: one display-message" grep -q "^display-message -t %5 rw: no image on the clipboard" "$FAKE_TMUX_LOG"
check "paste-image, no image: nothing pasted" bash -c "! grep -qE '^(send-keys|paste-buffer)' '$FAKE_TMUX_LOG'"

: >"$FAKE_TMUX_LOG"
out="$(FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 2>&1)"
eq "paste-image, remote pane: exit 0, prints nothing" "$?:$out" "0:"
clips=("$clips_dir/"*.png)
clip="${clips[0]##*/}"
check "paste-image: saved as <UTC %Y%m%dT%H%M%SZ>.png" bash -c "[[ '$clip' =~ ^[0-9]{8}T[0-9]{6}Z\\.png$ ]]"
check "paste-image: the saved bytes are the decoded PNG" \
  test "$(xxd -p "$clips_dir/$clip" | tr -d '\n')" = "$(printf '%s' "$png_hex" | tr 'A-F' 'a-f')"
check "paste-image, remote pane: the image is on the worker under Pictures/rw-clips" \
  cmp -s "$clips_dir/$clip" "$FAKE_WORKER_HOME/Pictures/rw-clips/$clip"
check "paste-image, remote pane: the worker path goes into a named buffer" \
  grep -qE "^set-buffer -b rw-clip-[0-9]+ -- $FAKE_WORKER_HOME/Pictures/rw-clips/$clip$" "$FAKE_TMUX_LOG"
check "paste-image, remote pane: pasted bracketed and the buffer deleted (paste-buffer -p -d)" \
  grep -qE "^paste-buffer -p -d -b rw-clip-[0-9]+ -t %5$" "$FAKE_TMUX_LOG"
check "paste-image: never send-keys" bash -c "! grep -q '^send-keys' '$FAKE_TMUX_LOG'"

rm -f "$clips_dir/"*.png
FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %6 >/dev/null 2>&1 &
FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %6 >/dev/null 2>&1 &
wait
clips=("$clips_dir/"*.png)
eq "paste-image: two presses in the same second keep two images" "${#clips[@]}" "2"

: >"$FAKE_TMUX_LOG"
rm -f "$clips_dir/"*.png
FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %6 >/dev/null 2>&1
clips=("$clips_dir/"*.png)
clip="${clips[0]##*/}"
check "paste-image, local pane: the laptop path is pasted" \
  grep -qE "^set-buffer -b rw-clip-[0-9]+ -- $clips_dir/$clip$" "$FAKE_TMUX_LOG"

: >"$FAKE_TMUX_LOG"
FAKE_SFTP_FAIL=1 FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 >/dev/null 2>&1
check "paste-image, copy fails: one display-message" grep -q "^display-message -t %5 rw: copying the clipboard image to the worker failed" "$FAKE_TMUX_LOG"
check "paste-image, copy fails: nothing pasted" bash -c "! grep -q '^set-buffer' '$FAKE_TMUX_LOG'"

: >"$FAKE_TMUX_LOG"
t0=$(date +%s)
RW_PASTE_IMAGE_TIMEOUT=1 FAKE_SFTP_SLEEP=31.4159 FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 >/dev/null 2>&1
dt=$(($(date +%s) - t0))
check "paste-image, hung copy: gives up at the bound (took ${dt}s)" test "$dt" -le 3
check "paste-image, hung copy: says it timed out" grep -q "^display-message -t %5 rw: copying the clipboard image to the worker timed out" "$FAKE_TMUX_LOG"
check "paste-image, hung copy: nothing pasted" bash -c "! grep -q '^set-buffer' '$FAKE_TMUX_LOG'"
check "paste-image, hung copy: the copy's process group was killed" bash -c "! pgrep -f 'sleep 31.4159' >/dev/null"

: >"$FAKE_TMUX_LOG"
# shellcheck disable=SC2016 # expanded by the hook's bash
FAKE_SFTP_HOOK='sed -i "" "s/pane_current_command=zsh/pane_current_command=nvim/" "$FAKE_TMUX_PANES"' \
  FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 >/dev/null 2>&1
check "paste-image, the pane's program changed during the copy: nothing pasted" bash -c "! grep -q '^set-buffer' '$FAKE_TMUX_LOG'"
check "  ... and it says so" grep -q "^display-message -t %5 rw: the pane changed while the image was copied" "$FAKE_TMUX_LOG"
sed -i '' 's/pane_current_command=nvim/pane_current_command=zsh/' "$FAKE_TMUX_PANES"

: >"$FAKE_TMUX_LOG"
sed -i '' 's/^\(pane_id=%5.*\)pane_in_mode=0/\1pane_in_mode=1/' "$FAKE_TMUX_PANES"
FAKE_CLIPBOARD_HEX="$png_hex" bash "$IMG" %5 >/dev/null 2>&1
check "paste-image, the pane is in a mode: nothing pasted" bash -c "! grep -q '^set-buffer' '$FAKE_TMUX_LOG'"
sed -i '' 's/pane_in_mode=1/pane_in_mode=0/' "$FAKE_TMUX_PANES"

: >"$FAKE_TMUX_LOG"
FAKE_CLIPBOARD_HEX="0011223344" bash "$IMG" %5 >/dev/null 2>&1
check "paste-image, not a PNG: treated as no image" grep -q "^display-message -t %5 rw: no image on the clipboard" "$FAKE_TMUX_LOG"

finish
