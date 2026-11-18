#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Editor panes come back on the other side (libexec/adapters/editor):
#
#   H  handoff: an nvim pane with a tmux-workspace-resurrect registration
#      reopens on the worker from its session file (root paths rewritten,
#      the embedded unsaved-buffer snapshot dropped); a vim pane without one
#      reopens from its argv; a shell pane gets nothing typed
#   B  hand-back: an nvim running in the remote pane reopens in the laptop
#      pane after its local shell is back, from the worker's session file
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
cat >"$lsess" <<EOF
let SessionLoad = 1
lua require('tmux_workspace_resurrect').prepare_restore(vim.json.decode('{"version":1,"buffers":[{"name":"x","lines":["UNSAVED"]}]}'))
cd ~/Developer/edproj
badd +3 $root/data/a.csv
edit $root/README
lua require('tmux_workspace_resurrect').restore_snapshot(vim.json.decode('{"version":1,"buffers":[{"name":"x","lines":["UNSAVED"]}]}'))
EOF

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
check "H: ... every one of them" bash -c "! grep -qF '$root/' '$wsess'"
check "H: the home-relative cd is kept" grep -qxF "cd ~/Developer/edproj" "$wsess"
check "H: unsaved buffer contents did not travel" bash -c "! grep -q 'UNSAVED\\|tmux_workspace_resurrect' '$wsess'"
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
cat >"$rsess" <<EOF
let SessionLoad = 1
lua require('tmux_workspace_resurrect').prepare_restore(vim.json.decode('{"version":1,"buffers":[]}'))
cd ~/Developer/edproj
badd +1 $wroot/data/b.csv
edit $wroot/data/b.csv
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
check "B: unsaved buffer contents did not travel" bash -c "! grep -q 'tmux_workspace_resurrect' '$lfile'"
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

finish
