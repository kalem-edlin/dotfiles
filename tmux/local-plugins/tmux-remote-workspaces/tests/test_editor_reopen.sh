#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Editor panes come back on the other side (libexec/adapters/editor):
#
#   H  handoff: an nvim pane with a tmux-workspace-resurrect registration
#      reopens on the worker from its session file (root paths rewritten,
#      including the buffer names inside the embedded unsaved-buffer
#      snapshot, whose text is carried verbatim); a vim pane without one
#      reopens from its argv; a shell pane gets nothing typed
#   B  hand-back: an nvim running in the remote pane reopens in the laptop
#      pane after its local shell is back, from the worker's session file
#   S  the snapshot rewrite on its own (single- and double-quoted Lua
#      literals, a path outside the root, a sibling of the root, an
#      undecodable snapshot) and, with a real nvim, a headless restore of the
#      installed session in a sandbox: unsaved text back, buffers modified,
#      no swap-file prompt even with the source's stale swap file synced over
#   W  an editor whose reopen cannot be confirmed is a warning, never a
#      failed handoff; a stale registration (another editor's) falls back to
#      the argv, and a `-S <session>` argument is not replayed
#
# Against the pane-aware tmux stub, the fake ssh and the fake ps of lib.sh.
# No tmux server, no ssh, no real editor.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

export FAKE_EVENTS="$SANDBOX/events"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
export FAKE_PS_EXTRA="$SANDBOX/ps-extra"
# Only the editor adapter: no agent is detected in any pane.
export RW_ADAPTERS_DIR="$SANDBOX/adapters"
mkdir -p "$RW_ADAPTERS_DIR"
ln -s "$RW_PLUGIN/libexec/adapters/editor" "$RW_PLUGIN/libexec/adapters/common-adapter.sh" "$RW_ADAPTERS_DIR/"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
opt() { tr '\t' '\n' <"$FAKE_TMUX_PANES" | awk -v p="pane_id=$1" '/^pane_id=/ { cur = $0 } cur == p' | sed -n "s/^$2=//p" | head -n1; }
order() { # <first-pattern> <second-pattern>: line of first < line of second
  local a b
  a="$(grep -n -m1 -- "$1" "$FAKE_EVENTS" | cut -d: -f1)"
  b="$(grep -n -m1 -- "$2" "$FAKE_EVENTS" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

root="$HOME/Developer/edproj"
make_plain "$root"
wroot="$FAKE_WORKER_HOME/Developer/edproj"
id="$(rw_root_id Developer/edproj)"
wstate="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR"
fstate="$TMUX_REMOTE_WORKSPACES_STATE_DIR"

# The laptop nvim's own session file, as tmux_workspace_resurrect.lua
# publishes it: :mksession output plus two lines carrying buffer CONTENTS.
mkdir -p "$SANDBOX/nvim-state"
lsess="$SANDBOX/nvim-state/pane-_4-editor-1.vim"
SNAP="{\"version\":1,\"buffers\":[{\"name\":\"$root/data/a.csv\",\"lines\":[\"UNSAVED\",\"see $root/data/a.csv\"],\"modified\":true},{\"name\":\"/elsewhere/other.txt\",\"lines\":[\"keep\"],\"modified\":true}]}"
cat >"$lsess" <<EOF
let SessionLoad = 1
lua require('tmux_workspace_resurrect').prepare_restore(vim.json.decode('$SNAP'))
cd ~/Developer/edproj
badd +3 $root/data/a.csv
edit $root/README
lua require('tmux_workspace_resurrect').restore_snapshot(vim.json.decode('$SNAP'))
EOF
# snap_json <session file> <prepare_restore|restore_snapshot> -- the snapshot
# JSON carried by that line of an installed session file (long-bracket form).
snap_json() {
  sed -n "s/^lua require('tmux_workspace_resurrect')\.$2(vim\.json\.decode(\[=*\[\(.*\)\]=*\]))\$/\1/p" "$1"
}

{
  printf 'pane_id=%%4\tpane_current_path=%s\tsession_name=s1\twindow_index=0\tpane_index=0\tpane_current_command=nvim\tpane_pid=999995\t@workspace-nvim-owner-pid=999982\t@workspace-nvim-session=%s\n' "$root" "$lsess"
  printf 'pane_id=%%5\tpane_current_path=%s\tsession_name=s1\twindow_index=0\tpane_index=1\tpane_current_command=vim\tpane_pid=999994\n' "$root/data"
  printf 'pane_id=%%6\tpane_current_path=%s\tsession_name=s1\twindow_index=0\tpane_index=2\tpane_current_command=zsh\tpane_pid=999993\n' "$root"
} >"$FAKE_TMUX_PANES"
# nvim's TUI under the pane shell, and its embedded server (the registered
# owner); vim run with a path inside the root.
cat >"$FAKE_PS_EXTRA" <<EOF
999981 999995 nvim data/a.csv
999982 999981 nvim --embed data/a.csv
999971 999994 /usr/bin/vim -p a.csv $root/README
EOF

# --- H: handoff reopens the editors on the worker -------------------------------------
export FAKE_TMUX_REMOTE_CMD=nvim
: >"$FAKE_EVENTS"
rw handoff --worker fakeworker --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "H: handoff with editor panes: exit 0" "$?" "0"
eq "H: root is worker-owned" "$(jq -r .owner "$(rw_owned_record_file "$id")" 2>/dev/null)" "worker"
ep4="$(opt %4 @rw-endpoint)" ep5="$(opt %5 @rw-endpoint)" ep6="$(opt %6 @rw-endpoint)"
check "H: all three panes went remote" test -n "$ep4" -a -n "$ep5" -a -n "$ep6"
wsess="$wstate/editor-sessions/$ep4.vim"
check "H: the nvim session was written on the worker" test -f "$wsess"
eq "H: ... private (0600)" "$(stat -f '%Lp' "$wsess" 2>/dev/null || stat -c '%a' "$wsess" 2>/dev/null)" "600"
check "H: its paths point into the worker root" grep -qxF "badd +3 $wroot/data/a.csv" "$wsess"
check "H: ... every one of them (outside the snapshot's unsaved text)" bash -c "! grep -v tmux_workspace_resurrect '$wsess' | grep -qF '$root/'"
check "H: the home-relative cd is kept" grep -qxF "cd ~/Developer/edproj" "$wsess"
eq "H: both snapshot lines travelled" "$(grep -c "^lua require('tmux_workspace_resurrect')\.\(prepare_restore\|restore_snapshot\)(" "$wsess")" "2"
for fn in prepare_restore restore_snapshot; do
  eq "H: $fn: the buffer under the root is renamed to the worker root" "$(snap_json "$wsess" $fn | jq -r '.buffers[0].name')" "$wroot/data/a.csv"
  eq "H: $fn: the buffer outside the root keeps its path" "$(snap_json "$wsess" $fn | jq -r '.buffers[1].name')" "/elsewhere/other.txt"
  eq "H: $fn: the unsaved text travels verbatim (a path in the text is not rewritten)" "$(snap_json "$wsess" $fn | jq -c '.buffers[0].lines')" "[\"UNSAVED\",\"see $root/data/a.csv\"]"
  eq "H: $fn: the modified flag travels" "$(snap_json "$wsess" $fn | jq -c '[.buffers[].modified]')" "[true,true]"
done
check "H: nvim -S was typed into the remote pane" \
  grep -qxF "tmux send-keys -t $(rw_session_name "$ep4") cd $wroot && nvim -S $wsess Enter" "$FAKE_EVENTS"
eq "H: the endpoint records the reopen" "$(rw_read_endpoint "$ep4" | jq -r .editor.reopen_intent)" "cd $wroot && nvim -S $wsess"
check "H: vim reopened from its argv, in its own directory, root paths rewritten" \
  grep -qxF "tmux send-keys -t $(rw_session_name "$ep5") cd $wroot/data && vim -p a.csv $wroot/README Enter" "$FAKE_EVENTS"
check "H: nothing typed into the shell pane's session" bash -c "! grep -q '^tmux send-keys -t $(rw_session_name "$ep6") ' '$FAKE_EVENTS'"
eq "H: the shell pane's endpoint has no editor" "$(rw_read_endpoint "$ep6" | jq -r .editor)" "null"
check "H: no warning" bash -c "! grep -q 'editor' '$SANDBOX/err'"
check "H: the editor reopened before the laptop pane was replaced" \
  order "^tmux send-keys -t $(rw_session_name "$ep4") " "^tmux respawn-pane -k -t %4 "

# --- B: hand-back reopens the remote nvim in the laptop pane --------------------------------
# The remote pane (stub %90 under pid 999999) runs nvim, registered with a
# session file in the worker's own nvim state.
mkdir -p "$FAKE_WORKER_HOME/nvim-state"
rsess="$FAKE_WORKER_HOME/nvim-state/pane-_90-editor-1.vim"
RSNAP="{\"version\":1,\"buffers\":[{\"name\":\"$wroot/data/b.csv\",\"lines\":[\"REMOTE UNSAVED\"],\"modified\":true}]}"
cat >"$rsess" <<EOF
let SessionLoad = 1
lua require('tmux_workspace_resurrect').prepare_restore(vim.json.decode('$RSNAP'))
cd ~/Developer/edproj
badd +1 $wroot/data/b.csv
edit $wroot/data/b.csv
lua require('tmux_workspace_resurrect').restore_snapshot(vim.json.decode('$RSNAP'))
EOF
cat >"$FAKE_PS_EXTRA" <<EOF
999960 999999 nvim data/b.csv
999961 999960 nvim --embed data/b.csv
EOF
export FAKE_REMOTE_PANE_OPTS="$SANDBOX/remote-opts"
printf '@workspace-nvim-owner-pid=999961\n@workspace-nvim-session=%s\n' "$rsess" >"$FAKE_REMOTE_PANE_OPTS"
export FAKE_LOCAL_RESUME_OK=1
: >"$FAKE_EVENTS"
rw handback --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "B: hand-back with a remote editor: exit 0" "$?" "0"
check "B: root is local again" test ! -e "$(rw_owned_record_file "$id")"
lfile="$fstate/editor-sessions/$ep4.vim"
check "B: the remote nvim session was written here" test -f "$lfile"
check "B: its paths point into the laptop root" grep -qxF "badd +1 $root/data/b.csv" "$lfile"
check "B: ... every one of them" bash -c "! grep -qF '$wroot/' '$lfile'"
eq "B: both snapshot lines travelled" "$(grep -c "^lua require('tmux_workspace_resurrect')\.\(prepare_restore\|restore_snapshot\)(" "$lfile")" "2"
eq "B: the remote buffer is renamed to the laptop root" "$(snap_json "$lfile" restore_snapshot | jq -r '.buffers[0].name')" "$root/data/b.csv"
eq "B: its unsaved text and modified flag came back" "$(snap_json "$lfile" restore_snapshot | jq -c '[.buffers[0].lines, .buffers[0].modified]')" '[["REMOTE UNSAVED"],true]'
check "B: nvim -S was typed into the laptop pane" grep -qxF "tmux send-keys -t %4 cd $root && nvim -S $lfile Enter" "$FAKE_EVENTS"
check "B: ... after its local shell was back" order "^tmux respawn-pane -k -t %4 " "^tmux send-keys -t %4 cd "
check "B: ... in the endpoint's own directory for the other pane" \
  grep -qxF "tmux send-keys -t %5 cd $root/data && nvim -S $fstate/editor-sessions/$ep5.vim Enter" "$FAKE_EVENTS"
eq "B: the laptop pane runs the editor" "$(opt %4 pane_current_command)" "nvim"
check "B: no warning" bash -c "! grep -q 'editor' '$SANDBOX/err'"
check "B: the worker sessions were closed after the editors reopened" \
  order "^tmux send-keys -t %4 cd " "kill-session -t '=$(rw_session_name "$ep4")'"

# --- W: an unconfirmed reopen only warns; a stale registration uses the argv ---------------
unset FAKE_REMOTE_PANE_OPTS
root2="$HOME/Developer/edproj2"
make_plain "$root2"
wroot2="$FAKE_WORKER_HOME/Developer/edproj2"
id2="$(rw_root_id Developer/edproj2)"
printf 'pane_id=%%7\tpane_current_path=%s\tsession_name=s2\twindow_index=0\tpane_index=0\tpane_current_command=nvim\tpane_pid=999992\t@workspace-nvim-owner-pid=12345\t@workspace-nvim-session=%s\n' "$root2" "$lsess" >"$FAKE_TMUX_PANES"
echo "999950 999992 nvim -S /elsewhere/old.vim README" >"$FAKE_PS_EXTRA"
export FAKE_TMUX_REMOTE_CMD=zsh
: >"$FAKE_EVENTS"
rw handoff --worker fakeworker --root "$root2" >/dev/null 2>"$SANDBOX/err"
eq "W: handoff whose editor never shows up: still exit 0" "$?" "0"
eq "W: root is worker-owned" "$(jq -r .owner "$(rw_owned_record_file "$id2")" 2>/dev/null)" "worker"
ep7="$(opt %7 @rw-endpoint)"
check "W: the pane went remote" test -n "$ep7"
check "W: the warning names the command to run" grep -qF "could not confirm the editor of pane %7 reopened on the remote; in that pane run: cd $wroot2 && nvim README" "$SANDBOX/err"
check "W: a stale registration is not used (no session file)" test ! -e "$wstate/editor-sessions/$ep7.vim"
check "W: the -S argument was not replayed" grep -qxF "tmux send-keys -t $(rw_session_name "$ep7") cd $wroot2 && nvim README Enter" "$FAKE_EVENTS"

# --- S: the snapshot rewrite on its own -----------------------------------------------------
# `editor install` straight on a hand-made snapshot directory, no rw around it.
ED="$RW_PLUGIN/libexec/adapters/editor"
SRC="$SANDBOX/nvt/src" DST="$SANDBOX/nvt/dst" OTHER="$SANDBOX/nvt/other"
mkdir -p "$SANDBOX/nvt/snap" "$SRC" "$DST" "$OTHER"
cat >"$SANDBOX/nvt/snap/manifest.json" <<'EOF'
{"editor":"nvim","cwd":"","argline":"nvim","session_file":"session.vim"}
EOF
# A single-quoted literal (no apostrophe in the text), a double-quoted one
# (vim.inspect's spelling once the text has an apostrophe: \" and \\ escapes),
# a snapshot that cannot be decoded, and ordinary session lines.
cat >"$SANDBOX/nvt/snap/session.vim" <<'EOF'
let SessionLoad = 1
lua require('tmux_workspace_resurrect').prepare_restore(vim.json.decode('{"version":1,"buffers":[{"name":"@SRC@/a.txt","lines":["x"],"modified":true},{"name":"@SRC@/sp ace/b.txt","lines":["y"],"modified":false},{"name":"@SRC@2/c.txt","lines":["sibling"]},{"name":"@OTHER@/o.txt","lines":["z"]},{"name":"@SRC@","lines":["root itself"]},{"name":"oil://@SRC@/d","lines":[""],"views":[{"tab":1,"window":1,"cursor":[1,0]}]}]}'))
cd @SRC@
badd +1 @SRC@/a.txt
badd +1 @SRC@2/c.txt
edit @SRC@/sp\ ace/b.txt
lua require('tmux_workspace_resurrect').restore_snapshot(vim.json.decode("{\"version\":1,\"buffers\":[{\"name\":\"@SRC@/q.txt\",\"lines\":[\"it's\",\"back\\\\slash \\\\n\",\"@SRC@/q.txt\"],\"modified\":true}]}"))
lua require('tmux_workspace_resurrect').restore_snapshot(vim.json.decode('{not json'))
EOF
sed -i.bak -e "s#@SRC@#$SRC#g" -e "s#@OTHER@#$OTHER#g" "$SANDBOX/nvt/snap/session.vim"
rm -f "$SANDBOX/nvt/snap/session.vim.bak"
"$ED" install --snapshot "$SANDBOX/nvt/snap" --from-root "$SRC" --to-root "$DST" --dest-dir "$DST" \
  --dest-file "$SANDBOX/nvt/out/s.vim" >"$SANDBOX/nvt/cmd" 2>"$SANDBOX/nvt/err"
eq "S: install exit 0" "$?" "0"
sv="$SANDBOX/nvt/out/s.vim"
eq "S: prepare_restore: names under the root move, outside and sibling names stay" \
  "$(snap_json "$sv" prepare_restore | jq -c '[.buffers[].name]')" \
  "$(jq -nc --arg s "$SRC" --arg d "$DST" --arg o "$OTHER" '[$d + "/a.txt", $d + "/sp ace/b.txt", $s + "2/c.txt", $o + "/o.txt", $d, "oil://" + $d + "/d"]')"
eq "S: prepare_restore: texts, flags and views are untouched" \
  "$(snap_json "$sv" prepare_restore | jq -c '[[.buffers[].lines], .buffers[0].modified, .buffers[5].views]')" \
  '[[["x"],["y"],["sibling"],["z"],["root itself"],[""]],true,[{"tab":1,"window":1,"cursor":[1,0]}]]'
eq "S: a double-quoted literal decodes, rewrites and re-encodes" \
  "$(snap_json "$sv" restore_snapshot | jq -c '[.buffers[0].name, .buffers[0].lines]')" \
  "$(jq -nc --arg s "$SRC" --arg d "$DST" '[$d + "/q.txt", ["it'"'"'s", "back\\slash \\n", $s + "/q.txt"]]')"
eq "S: the snapshot that cannot be decoded is dropped, not shipped" "$(grep -c "^lua require('tmux_workspace_resurrect')\." "$sv")" "2"
check "S: ... with a warning" grep -q "could not be rewritten" "$SANDBOX/nvt/err"
check "S: ordinary lines: root rewritten (escaped spelling too), a sibling directory not" \
  bash -c "grep -qxF 'cd $DST' '$sv' && grep -qxF 'badd +1 $DST/a.txt' '$sv' && grep -qxF 'badd +1 ${SRC}2/c.txt' '$sv' && grep -qxF 'edit $DST/sp\\ ace/b.txt' '$sv'"
eq "S: the file is private (0600)" "$(stat -f '%Lp' "$sv" 2>/dev/null || stat -c '%a' "$sv" 2>/dev/null)" "600"
eq "S: it prints the reopen command" "$(cat "$SANDBOX/nvt/cmd")" "$(printf 'cd %q && nvim -S %q' "$DST" "$sv")"

# --- S (nvim): a headless restore of what install wrote ----------------------------------------
# A real nvim in a sandbox: its own HOME and XDG dirs, --clean, no TMUX in the
# environment, and the repo's module on the runtimepath. The source session is
# produced by the module's own publish_session (reached through the upvalues
# of M.save), so the line format is the real one; then `editor install`
# rewrites it and a second nvim sources it.
if command -v nvim >/dev/null 2>&1; then
  NV="$SANDBOX/nvt/nv"
  mkdir -p "$NV/home" "$NV/config" "$NV/data" "$NV/state" "$NV/cache"
  # nvim_start <args...> -- a sandboxed headless nvim in the background (pid
  # in NV_PID); nvim_sandboxed runs one to the end, killing it after 15 s
  # (an unanswered swap-file prompt would otherwise wait forever).
  nvim_start() {
    env -u TMUX -u TMUX_PANE -u NVIM -u NVIM_APPNAME -u AGENT_STATE_PANE \
      HOME="$NV/home" XDG_CONFIG_HOME="$NV/config" XDG_DATA_HOME="$NV/data" \
      XDG_STATE_HOME="$NV/state" XDG_CACHE_HOME="$NV/cache" \
      nvim --headless --clean --cmd "set rtp^=$RW_PLUGIN/../../../nvim" "$@" </dev/null >"$NV/nvim.out" 2>&1 &
    NV_PID=$!
  }
  nvim_sandboxed() {
    local i=0
    nvim_start "$@"
    while kill -0 "$NV_PID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$NV_PID" 2>/dev/null; then
      { kill -9 "$NV_PID" && wait "$NV_PID"; } 2>/dev/null
      return 124
    fi
    wait "$NV_PID"
  }
  printf 'disk A\n' >"$SRC/a.txt"
  printf 'disk A\n' >"$DST/a.txt" # the synced copy
  printf 'disk O\n' >"$OTHER/o.txt"
  cat >"$NV/make-source.lua" <<'EOF'
local src, other, out = os.getenv("ED_SRC"), os.getenv("ED_OTHER"), os.getenv("ED_OUT")
local esc = vim.fn.fnameescape
vim.cmd("edit " .. esc(src .. "/a.txt"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited A", "it's \"quoted\" \\ back", "mentions " .. src .. "/a.txt", "tab\there \195\169 \226\156\147 \1 end" })
vim.cmd("split " .. esc(src .. "/new.txt")) -- never saved: not on disk
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "brand new, never saved" })
vim.cmd("tabnew " .. esc(other .. "/o.txt"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "outside the root" })
vim.cmd("mksession! " .. esc(out .. ".mk"))
local function upvalue(fn, name)
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then return nil end
    if n == name then return v end
    i = i + 1
  end
end
local publish = upvalue(require("tmux_workspace_resurrect").save, "publish_session")
assert(publish, "publish_session not found behind M.save")
assert(publish(out, vim.fn.readfile(out .. ".mk")), "publish_session failed")
EOF
  cat >"$NV/dump.lua" <<'EOF'
local res = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
    res[#res + 1] = { name = vim.api.nvim_buf_get_name(b), lines = vim.api.nvim_buf_get_lines(b, 0, -1, false), modified = vim.bo[b].modified }
  end
end
vim.fn.writefile({ vim.json.encode(res) }, os.getenv("ED_RESULT"))
EOF
  mkdir -p "$NV/snap"
  cp "$SANDBOX/nvt/snap/manifest.json" "$NV/snap/manifest.json"
  ED_SRC="$SRC" ED_OTHER="$OTHER" ED_OUT="$NV/snap/session.vim" nvim_sandboxed -c "luafile $NV/make-source.lua" -c 'qa!'
  eq "S nvim: the source session was produced" "$?" "0"
  eq "S nvim: it carries the module's two snapshot lines" "$(grep -c "^lua require('tmux_workspace_resurrect')\.\(prepare_restore\|restore_snapshot\)(" "$NV/snap/session.vim")" "2"
  check "S nvim: ... and an apostrophe in the text made vim.inspect use the double-quoted spelling" \
    grep -q 'decode("{' "$NV/snap/session.vim"
  "$ED" install --snapshot "$NV/snap" --from-root "$SRC" --to-root "$DST" --dest-dir "$DST" --dest-file "$NV/out/restore.vim" >/dev/null 2>"$NV/err"
  eq "S nvim: install exit 0" "$?" "0"
  eq "S nvim: no warning" "$(cat "$NV/err")" ""
  check "S nvim: no path of the source root is left in the session (outside the unsaved text)" \
    bash -c "! grep -v tmux_workspace_resurrect '$NV/out/restore.vim' | grep -qF '$SRC'"
  # Another nvim holds the destination file open with unsaved changes, so a swap
  # file for it exists (a worker editor left over from an earlier reopen): the
  # restore must not stop at the E325 prompt. Headless nvim only prints E325
  # (a real TUI would wait for a key), so the control run, the same session
  # without its prepare_restore line, shows the holder really provokes it.
  nvim_start "$DST/a.txt" -c 'call setline(1, "dirty")' -c preserve -c 'sleep 60'
  holder="$NV_PID"
  wait_for 8 bash -c "ls '$NV/state/nvim/swap/' 2>/dev/null | grep -q 'a.txt.swp'"
  check "S nvim: a swap file of the destination file is in place" bash -c "ls '$NV/state/nvim/swap/' | grep -q 'a.txt.swp'"
  grep -v "prepare_restore" "$NV/out/restore.vim" >"$NV/control.vim"
  ED_RESULT="$NV/control.json" nvim_sandboxed -S "$NV/control.vim" -c "luafile $NV/dump.lua" -c 'qa!'
  check "S nvim: control: without prepare_restore the open file hits the swap prompt (E325)" grep -q E325 "$NV/nvim.out"
  ED_RESULT="$NV/result.json" nvim_sandboxed -S "$NV/out/restore.vim" -c "luafile $NV/dump.lua" -c 'qa!'
  eq "S nvim: the restore ran to the end (no swap prompt, no hang)" "$?" "0"
  check "S nvim: ... without an E325 message" bash -c "! grep -q E325 '$NV/nvim.out'"
  { kill -9 "$holder" && wait "$holder"; } 2>/dev/null
  res() { jq -c --arg n "$1" '[.[] | select(.name == $n)][0] | [.lines, .modified]' "$NV/result.json"; }
  eq "S nvim: the synced file comes back with the unsaved text, modified" "$(res "$DST/a.txt")" \
    "$(jq -nc --arg s "$SRC" '[["edited A", "it'"'"'s \"quoted\" \\ back", "mentions " + $s + "/a.txt", "tab\there é ✓ \u0001 end"], true]')"
  eq "S nvim: a buffer whose file does not exist on the destination, modified" "$(res "$DST/new.txt")" '[["brand new, never saved"],true]'
  eq "S nvim: a buffer outside the root keeps its path, text and flag" "$(res "$OTHER/o.txt")" '[["outside the root"],true]'
  eq "S nvim: no buffer is left under the source root" "$(jq -r --arg s "$SRC/" '[.[] | select(.name | startswith($s))] | length' "$NV/result.json")" "0"
  eq "S nvim: the disk copies were not written" "$(cat "$DST/a.txt" "$OTHER/o.txt" | tr '\n' ' ')" "disk A disk O "
  check "S nvim: the sandbox home stayed empty" bash -c "! ls '$NV/home' | grep -q ."
else
  printf 'skip S nvim: no nvim on PATH\n'
fi

finish
