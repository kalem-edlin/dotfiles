#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # literal tmux session ids ($1) and formats
# `rw switch` (pane host switching, CS1/CS2, S3-S5) against the pane-aware
# tmux stub, the same-host fake ssh and fake agent adapters. No tmux server,
# no ssh.
#
#   R  rw_pane_dir: a remote pane's live remote cwd (pane title) mapped back,
#      the endpoint focus path without one, a local pane's own path
#   S  a shell pane, both directions: a visit endpoint on a laptop-owned
#      root (nearest existing parent there, one line), back to this machine
#      (endpoint closed, marker gone); remote to another remote
#   O  to the remote that owns the root: an owned endpoint in the record;
#      back: out of the record
#   X  refusals (exit 7: already there, an unsupported program, local and
#      remote; an agent working; agent directory missing), unreachable (6)
#   C  claude and P pi agents, both directions: resumed and confirmed on the
#      destination before the source stops; a resume that does not confirm
#      undoes everything and never stops the source
#   E  editors, both directions
#   F  run inside the pane itself (splits, new windows): exec into the loop

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/roots.sh
source "$RW_PLUGIN/scripts/roots.sh"

export FAKE_EVENTS="$SANDBOX/events"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
export FAKE_PS_EXTRA="$SANDBOX/ps-extra"
: >"$FAKE_PS_EXTRA"
export RW_ADAPTERS_DIR="$SANDBOX/adapters"
mkdir -p "$RW_ADAPTERS_DIR"
cat >"$RW_ADAPTERS_DIR/claude" <<'ADAPTER'
#!/usr/bin/env bash
# Fake claude / pi adapter (the provider is this file's name): one local
# agent, $FAKE_AGENT_PROVIDER in $FAKE_AGENT_PANE.
prov="$(basename "$0")"
cmd="$1"; shift
printf 'adapter %s %s %s\n' "$prov" "$cmd" "$*" >>"${FAKE_EVENTS:-/dev/null}"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  detect)
    [ "$(arg --pane "$@")" = "${FAKE_AGENT_PANE:-}" ] && [ "${FAKE_AGENT_PROVIDER:-}" = "$prov" ] || exit 1
    jq -nc --arg p "$FAKE_AGENT_PROJECT" --arg prov "$prov" '{provider: $prov, session_id: ("sess-" + $prov), project_path: $p, mode_flags: ""}'
    ;;
  versions) echo '{"local":"1","worker":"1","policy":"identical"}' ;;
  export)
    out="$(arg --out "$@")"; mkdir -p "$out"
    jq -nc --arg s "$(arg --session-id "$@")" --arg p "$prov" '{provider: $p, session_id: $s}' >"$out/manifest.json"
    ;;
  install) : ;;
  resume-cmd)
    if [ "$prov" = claude ]; then
      printf 'cd %q && claudef --resume %s\n' "$(arg --dest-path "$@")" "$(arg --session-id "$@")"
    else
      printf 'cd %q && pif --session %s\n' "$(arg --dest-path "$@")" "$(arg --session-id "$@")"
    fi
    ;;
esac
ADAPTER
chmod +x "$RW_ADAPTERS_DIR/claude"
ln -s claude "$RW_ADAPTERS_DIR/pi"
ln -s "$RW_PLUGIN/libexec/adapters/editor" "$RW_PLUGIN/libexec/adapters/common-adapter.sh" "$RW_ADAPTERS_DIR/"

# A second remote, for remote-to-remote switches (the fake ssh serves both).
jq '.workers += [{"alias": "fakeworker2", "platform": "darwin", "notes": "second test double"}]' \
  "$TMUX_REMOTE_WORKSPACES_CONFIG" >"$SANDBOX/config2.json"
mv "$SANDBOX/config2.json" "$TMUX_REMOTE_WORKSPACES_CONFIG"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
opt() { tr '\t' '\n' <"$FAKE_TMUX_PANES" | awk -v p="pane_id=$1" '/^pane_id=/ { cur = $0 } cur == p' | sed -n "s/^$2=//p" | head -n1; }
setp() { tmux set-option -pqt "$1" "$2" "$3"; }
ep_field() { rw_read_endpoint "$1" 2>/dev/null | jq -r "$2"; }
order() { # <first-pattern> <second-pattern>: line of first < line of second
  local a b
  a="$(grep -n -m1 -- "$1" "$FAKE_EVENTS" | cut -d: -f1)"
  b="$(grep -n -m1 -- "$2" "$FAKE_EVENTS" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
pane_line() { # <id> <path> <cmd> <pid> [extra key=value ...]
  local id="$1" path="$2" cmd="$3" pid="$4"
  shift 4
  printf 'pane_id=%s\tpane_current_path=%s\tsession_id=$1\tsession_name=s1\twindow_index=0\tpane_index=%s\tpane_current_command=%s\tpane_pid=%s' \
    "$id" "$path" "${id#%}" "$cmd" "$pid"
  for kv in "$@"; do printf '\t%s' "$kv"; done
  printf '\n'
}
# remote <pane>: the pane's attach loop runs (what attach-loop.sh stamps),
# with its remote cwd as the pane title.
remote() { setp "$1" @remote-host "$(opt "$1" @rw-worker)"; setp "$1" pane_title "$2"; }
markers="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/visits"
H="$HOME" W="$FAKE_WORKER_HOME"

proj="$H/Developer/proj"
mkdir -p "$proj/sub/deep" "$W/Developer/proj/sub"
: >"$FAKE_TMUX_PANES"
{
  pane_line %1 "$proj/sub/deep" zsh 999981
  pane_line %2 "$proj" htop 999982
  pane_line %3 "$proj" zsh 999983
} >"$FAKE_TMUX_PANES"

# --- R: rw_pane_dir ----------------------------------------------------------------
eq "R: a local pane's directory is its own path" "$(rw_pane_dir %1)" "$proj/sub/deep"

# --- S: shell, this machine -> remote (visit) -------------------------------------
: >"$FAKE_EVENTS"
out="$(rw switch --pane %1 --to fakeworker 2>"$SANDBOX/err")"
eq "S: local shell to a remote: exit 0" "$?" "0"
ep1="$(opt %1 @rw-endpoint)"
check "S: the pane is bound to a new endpoint" test -n "$ep1"
eq "S: a root this machine owns gives a visit endpoint" "$(ep_field "$ep1" .kind)" "visit"
eq "S: ... carrying the enclosing root" "$(ep_field "$ep1" .root_rel)" "Developer/proj/sub/deep"
check "S: ... in no record" bash -c "! ls '$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned' >/dev/null 2>&1 || ! grep -rq '$ep1' '$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned'"
eq "S: the missing directory opens at its nearest existing parent there" "$(ep_field "$ep1" .workspace.remote_path)" "$W/Developer/proj/sub"
eq "S: ... with one line saying so" "$(printf '%s\n' "$out" | grep -c 'does not exist on that remote')" "1"
eq "S: the focus path is the pane's directory" "$(ep_field "$ep1" .workspace.focus_path)" "$proj/sub/deep"
check "S: the hidden session was created there" grep -q "^tmux new-session -d -s $(rw_session_name "$ep1") -c $W/Developer/proj/sub\$" "$FAKE_EVENTS"
check "S: the worker keeps a visit marker" test -f "$markers/$ep1.json"
eq "S: ... naming its session" "$(jq -r .session_name "$markers/$ep1.json")" "$(rw_session_name "$ep1")"
check "S: the pane became the attach loop in place" grep -q "^tmux respawn-pane -k -t %1 -c $proj/sub/deep .*attach-loop.sh $ep1 --fresh" "$FAKE_EVENTS"
eq "S: @rw-worker" "$(opt %1 @rw-worker)" "fakeworker"
eq "S: @rw-workspace" "$(opt %1 @rw-workspace)" "$W/Developer/proj/sub"
check "S: a switch event" grep -q '"event":"switch".*"outcome":"success"' "$TMUX_REMOTE_WORKSPACES_STATE_DIR/events.jsonl"
check "S: no host name in what it printed" bash -c "! grep -q fakeworker <<<'$out'"

# --- R: a remote pane ------------------------------------------------------------------
remote %1 "$W/Developer/proj"
eq "R: a remote pane's directory is its live remote cwd, mapped back" "$(rw_pane_dir %1)" "$proj"
setp %1 pane_title "$W/elsewhere/x"
eq "R: ... anywhere under the remote home" "$(rw_pane_dir %1)" "$H/elsewhere/x"
setp %1 pane_title "mini.local"
eq "R: a title that is no path falls back to the endpoint's focus path" "$(rw_pane_dir %1)" "$proj/sub/deep"
# X4: the pane is still in the parent it opened in, because its directory
# (sub/deep) does not exist on the remote: it is in that directory as far as
# this machine is concerned, so a switch back or a split keeps it.
setp %1 pane_title "$W/Developer/proj/sub"
eq "R: still in the parent it opened in (directory missing there): its focus path" "$(rw_pane_dir %1)" "$proj/sub/deep"
eq "R: ... also when the remote answers (--live)" "$(FAKE_REMOTE_CWD="$W/Developer/proj/sub" rw_pane_dir %1 --live)" "$proj/sub/deep"
setp %1 pane_title "$W/Developer/proj"
eq "R: --live asks the remote session first (the title can lag)" "$(FAKE_REMOTE_CWD="$W/Developer/proj/sub/deep" rw_pane_dir %1 --live)" "$proj/sub/deep"
eq "R: --live falls back to the title when the remote does not answer" "$(touch "$FAKE_SSH_DOWN"; rw_pane_dir %1 --live; rm -f "$FAKE_SSH_DOWN")" "$proj"

# --- X: refusals -------------------------------------------------------------------------
rw switch --pane %1 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "X: a pane already on that remote: exit 7" "$?" "7"
check "X: one rw: line" bash -c "[ \$(wc -l <'$SANDBOX/err') -eq 1 ] && grep -q '^rw: ' '$SANDBOX/err'"
rw switch --pane %3 --to local >/dev/null 2>&1
eq "X: a local pane to this machine: exit 7" "$?" "7"
: >"$FAKE_EVENTS"
rw switch --pane %2 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "X: a pane running something else (htop): exit 7" "$?" "7"
check "X: ... saying to quit it" bash -c "grep -q \"^rw: this pane runs 'htop'.*quit it first\" '$SANDBOX/err' && [ \$(wc -l <'$SANDBOX/err') -eq 1 ]"
check "X: ... before anything was created" bash -c "! grep -q 'new-session' '$FAKE_EVENTS'"
rw switch --pane %3 --to nosuch >/dev/null 2>&1
eq "X: an unknown remote: exit 64" "$?" "64"
touch "$FAKE_SSH_DOWN"
rw switch --pane %3 --to fakeworker >/dev/null 2>&1
eq "X: unreachable remote: exit 6" "$?" "6"
eq "X: ... the pane is untouched" "$(opt %3 @rw-endpoint)" ""
rm -f "$FAKE_SSH_DOWN"

# --- S: remote -> another remote ----------------------------------------------------------
: >"$FAKE_EVENTS"
rw switch --pane %1 --to fakeworker2 >/dev/null 2>"$SANDBOX/err"
eq "S: remote to another remote: exit 0" "$?" "0"
ep2="$(opt %1 @rw-endpoint)"
check "S: a new endpoint on the other remote" test -n "$ep2" -a "$ep2" != "$ep1"
eq "S: ... a visit there too" "$(ep_field "$ep2" '.kind + " " + .worker')" "visit fakeworker2"
eq "S: ... in the live directory" "$(ep_field "$ep2" .workspace.focus_path)" "$proj"
check "S: the old endpoint is closed" bash -c "[ -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$ep1.json' ] && [ ! -f '$(rw_endpoint_file "$ep1")' ]"
check "S: ... its session killed after the pane moved" order "^tmux respawn-pane -k -t %1 .*$ep2" "kill-session -t '=$(rw_session_name "$ep1")'"
check "S: ... and its marker gone" test ! -e "$markers/$ep1.json"

# --- S: remote -> this machine ---------------------------------------------------------------
remote %1 "$W/Developer/proj/sub"
: >"$FAKE_EVENTS"
out="$(rw switch --pane %1 --to local 2>"$SANDBOX/err")"
eq "S: remote shell to this machine: exit 0" "$?" "0"
check "S: the pane got a local shell in place, in the mapped directory" grep -q "^tmux respawn-pane -k -t %1 -c $proj/sub exec .* -l\$" "$FAKE_EVENTS"
eq "S: its endpoint options are gone" "$(opt %1 @rw-endpoint)$(opt %1 @remote-host)" ""
check "S: the endpoint is closed" test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$ep2.json"
check "S: ... its session killed" grep -q "kill-session -t '=$(rw_session_name "$ep2")'" "$FAKE_EVENTS"
check "S: ... and its marker gone" test ! -e "$markers/$ep2.json"

# A remote-only directory comes back to its nearest existing parent here.
rw switch --pane %1 --to fakeworker --dir "$proj" >/dev/null 2>&1
ep3="$(opt %1 @rw-endpoint)"
mkdir -p "$W/Developer/proj/only-remote"
remote %1 "$W/Developer/proj/only-remote"
out="$(rw switch --pane %1 --to local 2>/dev/null)"
eq "S: remote-only directory: exit 0" "$?" "0"
check "S: ... the shell starts at the nearest existing parent" grep -q "^tmux respawn-pane -k -t %1 -c $proj exec" "$FAKE_EVENTS"
eq "S: ... with one line saying so" "$(printf '%s\n' "$out" | grep -c 'does not exist on this machine')" "1"
check "S: ... and that endpoint closed" test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$ep3.json"

# X4 (real worker, 2026-11-18): a pane whose directory the remote lacks
# opens there in the nearest existing parent; switched back without a cd,
# it returns to the directory it left, not to that parent.
pane_line %9 "$proj/sub/deep" zsh 999989 >>"$FAKE_TMUX_PANES"
rw switch --pane %9 --to fakeworker >/dev/null 2>&1
ep9="$(opt %9 @rw-endpoint)"
eq "S: round trip: the remote side opened in the parent" "$(ep_field "$ep9" .workspace.remote_path)" "$W/Developer/proj/sub"
remote %9 "$W/Developer/proj/sub"
: >"$FAKE_EVENTS"
out="$(FAKE_REMOTE_CWD="$W/Developer/proj/sub" rw switch --pane %9 --to local 2>/dev/null)"
eq "S: round trip back: exit 0" "$?" "0"
check "S: ... the local shell is in the directory the pane left" grep -q "^tmux respawn-pane -k -t %9 -c $proj/sub/deep exec" "$FAKE_EVENTS"
eq "S: ... and says so" "$out" "rw: this pane runs on this machine again, in ~/Developer/proj/sub/deep."

# --- O: the remote that owns the root ------------------------------------------------------------
owned="$H/Developer/owned"
make_plain "$owned"
oid="$(rw_root_id Developer/owned)"
rw handoff --worker fakeworker --root "$owned" >/dev/null 2>&1
eq "O: setup: handoff exit 0" "$?" "0"
pane_line %4 "$owned/data" zsh 999984 >>"$FAKE_TMUX_PANES"
: >"$FAKE_EVENTS"
rw switch --pane %4 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "O: a frozen local pane to its owner: exit 0" "$?" "0"
ep4="$(opt %4 @rw-endpoint)"
eq "O: an owned endpoint" "$(ep_field "$ep4" '.kind + " " + .root_id')" "owned $oid"
check "O: ... listed in the record" bash -c "jq -e --arg e '$ep4' '.endpoints | index(\$e)' '$(rw_owned_record_file "$oid")' >/dev/null"
eq "O: ... in the worker copy's directory" "$(ep_field "$ep4" .workspace.remote_path)" "$W/Developer/owned/data"
check "O: ... no visit marker" test ! -e "$markers/$ep4.json"
eq "O: @rw-root-id" "$(opt %4 @rw-root-id)" "$oid"
remote %4 "$W/Developer/owned/data"
rw switch --pane %4 --to local >/dev/null 2>&1
eq "O: back to this machine: exit 0" "$?" "0"
check "O: the endpoint left the record" bash -c "! jq -e --arg e '$ep4' '.endpoints | index(\$e)' '$(rw_owned_record_file "$oid")' >/dev/null"
eq "O: the root is still remote" "$(jq -r .owner "$(rw_owned_record_file "$oid")")" "worker"

# --- C: claude, this machine -> remote ---------------------------------------------------------------
export FAKE_AGENT_PROVIDER=claude FAKE_AGENT_PANE=%3 FAKE_AGENT_PROJECT="$proj"
setp %3 @agent_state working
rw switch --pane %3 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "C: a working agent: exit 7" "$?" "7"
setp %3 @agent_state idle
export FAKE_AGENT_PROJECT="$proj/sub/deep"
: >"$FAKE_EVENTS"
rw switch --pane %3 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "C: agent directory missing on the remote: exit 7" "$?" "7"
check "C: ... saying so" grep -q "does not exist on that remote" "$SANDBOX/err"
check "C: ... nothing created, nothing stopped" bash -c "! grep -q 'new-session\|-F #{pane_pid}' '$FAKE_EVENTS'"
export FAKE_AGENT_PROJECT="$proj"

export FAKE_TMUX_REMOTE_CMD=zsh # the remote resume never shows up
: >"$FAKE_EVENTS"
rw switch --pane %3 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "C: remote resume unconfirmed: exit 1" "$?" "1"
check "C: ... the local agent was never stopped" bash -c "! grep -q '^tmux display-message -pt %3 -F #{pane_pid}' '$FAKE_EVENTS'"
check "C: ... the pane was not replaced" bash -c "! grep -q '^tmux respawn-pane -k -t %3' '$FAKE_EVENTS'"
eq "C: ... and carries no endpoint" "$(opt %3 @rw-endpoint)" ""
check "C: ... the new session was closed again" grep -q "kill-session -t '=rw-" "$FAKE_EVENTS"

export FAKE_TMUX_REMOTE_CMD=claude
: >"$FAKE_EVENTS"
rw switch --pane %3 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "C: claude to a remote: exit 0" "$?" "0"
ep5="$(opt %3 @rw-endpoint)"
check "C: the transcript was exported here and installed there" \
  bash -c "grep -q '^adapter claude export --session-id sess-claude --project-path $proj ' '$FAKE_EVENTS' && grep -q '^adapter claude install .*--dest-path $W/Developer/proj --worker fakeworker' '$FAKE_EVENTS'"
check "C: resumed in the new remote session" grep -q "^tmux send-keys -t $(rw_session_name "$ep5") cd $W/Developer/proj && claudef --resume sess-claude Enter" "$FAKE_EVENTS"
check "C: the local agent stopped only after the remote resume" order "^tmux send-keys -t $(rw_session_name "$ep5")" "^tmux display-message -pt %3 -F #{pane_pid}"
check "C: ... and before the pane became the attach loop" order "^tmux display-message -pt %3 -F #{pane_pid}" "^tmux respawn-pane -k -t %3"
eq "C: the endpoint records the agent" "$(ep_field "$ep5" '.agent.provider + " " + .agent.state + " " + .agent.project_path_worker')" "claude handed-off $W/Developer/proj"

# --- C: claude, remote -> this machine -----------------------------------------------------------------
remote %3 "$W/Developer/proj"
unset FAKE_AGENT_PANE
echo "999990 999999 /Users/someone/.cache/claudef/bin/2.1.327 --resume live-1" >"$FAKE_PS_EXTRA"
state_dir="$XDG_STATE_HOME/tmux-workspace-resurrect/agents/server-4242-1700000000"
mkdir -p "$state_dir"
jq -nc --arg cwd "$W/Developer/proj" '{tool: "claude", session_id: "live-1", cwd: $cwd}' >"$state_dir/pane-90.json"
export FAKE_LOCAL_RESUME_OK=0
: >"$FAKE_EVENTS"
rw switch --pane %3 --to local >/dev/null 2>"$SANDBOX/err"
eq "C: local resume unconfirmed: exit 1" "$?" "1"
check "C: ... the remote agent was never stopped" bash -c "! grep -q 'kill -TERM' '$FAKE_EVENTS'"
eq "C: ... the pane is back on its endpoint" "$(opt %3 @rw-endpoint)" "$ep5"
check "C: ... running its attach loop again" grep -q "^tmux respawn-pane -k -t %3 .*attach-loop.sh $ep5\$" "$FAKE_EVENTS"
check "C: ... the endpoint is still registered" test -f "$(rw_endpoint_file "$ep5")"
export FAKE_LOCAL_RESUME_OK=1
remote %3 "$W/Developer/proj"
: >"$FAKE_EVENTS"
rw switch --pane %3 --to local >/dev/null 2>"$SANDBOX/err"
eq "C: claude back to this machine: exit 0" "$?" "0"
check "C: the live remote session was exported from the remote" grep -q "^adapter claude export --session-id live-1 --project-path $W/Developer/proj .*--worker fakeworker" "$FAKE_EVENTS"
check "C: ... installed for this machine's path" grep -q "^adapter claude install --snapshot .* --dest-path $proj\$" "$FAKE_EVENTS"
check "C: resumed in the same pane after its local shell" order "^tmux respawn-pane -k -t %3 -c $proj exec" "^tmux send-keys -t %3 cd $proj && claudef --resume live-1 Enter"
check "C: the remote agent stopped only after the local resume" order "^tmux send-keys -t %3 cd $proj && claudef" "kill -TERM 999990"
check "C: the endpoint is closed" test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$ep5.json"
eq "C: the pane runs the agent here" "$(opt %3 pane_current_command)" "claude"
: >"$FAKE_PS_EXTRA"

# --- P: pi, both directions -------------------------------------------------------------------------------
setp %3 pane_current_command zsh
export FAKE_AGENT_PROVIDER=pi FAKE_AGENT_PANE=%3 FAKE_TMUX_REMOTE_CMD=pi
: >"$FAKE_EVENTS"
rw switch --pane %3 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "P: pi to a remote: exit 0" "$?" "0"
ep6="$(opt %3 @rw-endpoint)"
check "P: resumed there with pif" grep -q "^tmux send-keys -t $(rw_session_name "$ep6") cd $W/Developer/proj && pif --session sess-pi Enter" "$FAKE_EVENTS"
check "P: the local agent stopped after that" order "^tmux send-keys -t $(rw_session_name "$ep6")" "^tmux display-message -pt %3 -F #{pane_pid}"
eq "P: endpoint agent" "$(ep_field "$ep6" '.agent.provider + " " + .agent.state')" "pi handed-off"
remote %3 "$W/Developer/proj"
unset FAKE_AGENT_PANE
echo "999991 999999 node /opt/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js" >"$FAKE_PS_EXTRA"
jq -nc --arg cwd "$W/Developer/proj" '{tool: "pi", session_id: "pi-live", cwd: $cwd}' >"$state_dir/pane-90.json"
: >"$FAKE_EVENTS"
rw switch --pane %3 --to local >/dev/null 2>"$SANDBOX/err"
eq "P: pi back to this machine: exit 0" "$?" "0"
check "P: resumed here with pif" grep -q "^tmux send-keys -t %3 cd $proj && pif --session pi-live Enter" "$FAKE_EVENTS"
check "P: the remote agent stopped after that" order "^tmux send-keys -t %3 cd $proj && pif" "kill -TERM 999991"
eq "P: the pane runs pi here" "$(opt %3 pane_current_command)" "pi"
: >"$FAKE_PS_EXTRA"
rm -f "$state_dir/pane-90.json"
unset FAKE_AGENT_PROVIDER

# --- X: an unknown program on the remote side -------------------------------------------------------------
setp %3 pane_current_command zsh
rw switch --pane %3 --to fakeworker >/dev/null 2>&1
remote %3 "$W/Developer/proj"
export FAKE_TMUX_REMOTE_CMD=htop
rw switch --pane %3 --to local >/dev/null 2>"$SANDBOX/err"
eq "X: a remote pane running htop: exit 7" "$?" "7"
check "X: ... one rw: line" bash -c "[ \$(wc -l <'$SANDBOX/err') -eq 1 ] && grep -q \"^rw: this pane runs 'htop' on the remote\" '$SANDBOX/err'"
check "X: ... the pane is still remote" test -n "$(opt %3 @rw-endpoint)"

# --- E: editors, both directions ----------------------------------------------------------------------------------
pane_line %5 "$proj" nvim 999985 >>"$FAKE_TMUX_PANES"
echo "999970 999985 nvim README.md" >"$FAKE_PS_EXTRA"
export FAKE_TMUX_REMOTE_CMD=nvim
: >"$FAKE_EVENTS"
rw switch --pane %5 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "E: an editor to a remote: exit 0" "$?" "0"
ep7="$(opt %5 @rw-endpoint)"
check "E: reopened in the remote session from its argv" grep -q "^tmux send-keys -t $(rw_session_name "$ep7") cd $W/Developer/proj && nvim README.md Enter" "$FAKE_EVENTS"
check "E: ... before the pane was replaced" order "^tmux send-keys -t $(rw_session_name "$ep7")" "^tmux respawn-pane -k -t %5"
eq "E: the endpoint records the reopen" "$(ep_field "$ep7" .editor.reopen_intent)" "cd $W/Developer/proj && nvim README.md"
check "E: no warning" bash -c "! grep -q editor '$SANDBOX/err'"
remote %5 "$W/Developer/proj"
echo "999960 999999 nvim notes.txt" >"$FAKE_PS_EXTRA"
: >"$FAKE_EVENTS"
rw switch --pane %5 --to local >/dev/null 2>"$SANDBOX/err"
eq "E: an editor back to this machine: exit 0" "$?" "0"
check "E: reopened in the pane after its local shell" order "^tmux respawn-pane -k -t %5 -c $proj exec" "^tmux send-keys -t %5 cd $proj && nvim notes.txt Enter"
eq "E: the pane runs the editor" "$(opt %5 pane_current_command)" "nvim"
: >"$FAKE_PS_EXTRA"
export FAKE_TMUX_REMOTE_CMD=zsh

# --- F: inside the pane itself -----------------------------------------------------------------------------------------
pane_line %6 "$proj" bash 999986 >>"$FAKE_TMUX_PANES"
: >"$FAKE_EVENTS"
TMUX_PANE=%6 "$RW_PLUGIN/scripts/rw" switch --to fakeworker --dir "$proj/sub" >"$SANDBOX/loop.out" 2>&1 &
loop=$!
bound6() { [ -n "$(opt %6 @rw-endpoint)" ]; }
wait_for 20 bound6
ep8="$(opt %6 @rw-endpoint)"
check "F: bound to a new endpoint" test -n "$ep8"
eq "F: in the directory it was given" "$(ep_field "$ep8" .workspace.remote_path)" "$W/Developer/proj/sub"
wait_for 20 grep -q "attach" "$SANDBOX/loop.out"
check "F: the pane itself became the attach loop (exec, no respawn)" bash -c "grep -q 'rw: checking\|rw: attaching' '$SANDBOX/loop.out' && ! grep -q '^tmux respawn-pane -k -t %6' '$FAKE_EVENTS'"
rw_write_tombstone "$ep8" 1 test
rm -f "$(rw_endpoint_file "$ep8")"
for _ in $(seq 1 40); do kill -0 "$loop" 2>/dev/null || break; sleep 0.25; done
kill "$loop" 2>/dev/null
wait "$loop" 2>/dev/null

finish
