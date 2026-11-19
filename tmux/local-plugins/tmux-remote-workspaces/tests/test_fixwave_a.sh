#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # literal tmux session ids ($1) and formats
# Regression tests for pane host switching fix wave A
# (docs/tasks/remote-owned-directories.md, "Changes recorded by fix wave A"),
# against the pane-aware tmux stub, the same-host fake ssh and fake agent
# adapters. No tmux server, no ssh.
#
#   1  rw reclaim releases only the record's endpoint panes, never a visit
#      pane of the root on another remote (and recomputes the chip)
#   2  a remote pane whose session is absent: refused while its remote is
#      restoring, refused when the endpoint records an agent
#   3  a switch takes the root lock (visits too) and refuses while a
#      background transfer of the root runs
#   4  owned or visit is decided after pending actions ran (a pending
#      forget); rw_owner_for_path (I2); rw_endpoint_open fails when the
#      record cannot take the endpoint
#   5  handoff adoption keeps the visit marker when the mirror push fails;
#      an owned switch whose mirror push fails is undone
#   6  rw switch --to local --force (I4) and the pending close on contact
#   7  remote to remote agent move: the respawn failure closes the source
#   8  remote to remote version gate compares the two remotes
#   9  rw_pane_remote_probe (I3): hard deadline; --dir-of resolves live
#  10  rw forget and pending reconciliation recompute the off-owner chip
#  I1  rw bg --root

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
: >"$FAKE_TMUX_PANES"
export RW_ADAPTERS_DIR="$SANDBOX/adapters"
mkdir -p "$RW_ADAPTERS_DIR"
cat >"$RW_ADAPTERS_DIR/claude" <<'ADAPTER'
#!/usr/bin/env bash
# Fake claude / pi adapter. versions: this machine is $FAKE_VER_LOCAL, each
# remote $FAKE_VER_<alias> (default 1.0); a remote older than this machine
# prints the JSON and exits 3, as the real adapters do.
prov="$(basename "$0")"
cmd="$1"; shift
printf 'adapter %s %s %s\n' "$prov" "$cmd" "$*" >>"${FAKE_EVENTS:-/dev/null}"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  detect) exit 1 ;;
  versions)
    w="$(arg --worker "$@")"
    v="FAKE_VER_${w//[^A-Za-z0-9_]/_}"
    wv="${!v:-1.0}" lv="${FAKE_VER_LOCAL:-1.0}"
    top="$(printf '%s\n%s\n' "$wv" "$lv" | sort -V | tail -n1)"
    if [ "$wv" = "$lv" ]; then pol=identical; elif [ "$top" = "$wv" ]; then pol=newer_worker; else
      jq -nc --arg l "$lv" --arg w "$wv" '{local: $l, worker: $w, policy: "blocked"}'
      echo "worker older" >&2
      exit 3
    fi
    jq -nc --arg l "$lv" --arg w "$wv" --arg p "$pol" '{local: $l, worker: $w, policy: $p}'
    ;;
  export)
    out="$(arg --out "$@")"; mkdir -p "$out"
    jq -nc --arg s "$(arg --session-id "$@")" --arg p "$prov" '{provider: $p, session_id: $s}' >"$out/manifest.json"
    ;;
  install) : ;;
  resume-cmd) printf 'cd %q && claudef --resume %s\n' "$(arg --dest-path "$@")" "$(arg --session-id "$@")" ;;
esac
ADAPTER
chmod +x "$RW_ADAPTERS_DIR/claude"
ln -s claude "$RW_ADAPTERS_DIR/pi"

jq '.workers += [{"alias": "fakeworker2", "platform": "darwin", "notes": "second test double"}]' \
  "$TMUX_REMOTE_WORKSPACES_CONFIG" >"$SANDBOX/config2.json"
mv "$SANDBOX/config2.json" "$TMUX_REMOTE_WORKSPACES_CONFIG"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
opt() { tr '\t' '\n' <"$FAKE_TMUX_PANES" | awk -v p="pane_id=$1" '/^pane_id=/ { cur = $0 } cur == p' | sed -n "s/^$2=//p" | head -n1; }
setp() { tmux set-option -pqt "$1" "$2" "$3"; }
ep_field() { rw_read_endpoint "$1" 2>/dev/null | jq -r "$2"; }
pane_line() { # <id> <path> [cmd]
  printf 'pane_id=%s\tpane_current_path=%s\tsession_id=$1\tsession_name=s1\twindow_index=0\tpane_index=%s\tpane_current_command=%s\tpane_pid=%s\n' \
    "$1" "$2" "${1#%}" "${3:-zsh}" "9999${1#%}" >>"$FAKE_TMUX_PANES"
}
remote() { setp "$1" @remote-host "$(opt "$1" @rw-worker)"; setp "$1" pane_title "$2"; }
tomb() { test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$1.json"; }
order() { # <first-pattern> <second-pattern>: line of first < line of second
  local a b
  a="$(grep -n -m1 -- "$1" "$FAKE_EVENTS" | cut -d: -f1)"
  b="$(grep -n -m1 -- "$2" "$FAKE_EVENTS" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
T=$'\t'
in_record() { jq -e --arg e "$2" '(.endpoints // []) | index($e)' "$(rw_owned_record_file "$1")" >/dev/null 2>&1; }
REFRESH="$RW_PLUGIN/scripts/rw-refresh-indicators.sh"
markers="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/visits"
H="$HOME" W="$FAKE_WORKER_HOME"
state_dir="$XDG_STATE_HOME/tmux-workspace-resurrect/agents/server-4242-1700000000"
mkdir -p "$state_dir"

# --- 1: reclaim and a visit pane on another remote ----------------------------------
r1="$H/Developer/reclaimed"
make_plain "$r1"
rid1="$(rw_root_id Developer/reclaimed)"
rw handoff --worker fakeworker --root "$r1" >/dev/null 2>&1
eq "1: setup: handoff" "$?" "0"
pane_line %1 "$r1"
pane_line %2 "$r1/data"
pane_line %3 "$r1"
rw switch --pane %1 --to fakeworker >/dev/null 2>&1
o1="$(opt %1 @rw-endpoint)"
rw switch --pane %2 --to fakeworker2 >/dev/null 2>&1
v2="$(opt %2 @rw-endpoint)"
eq "1: setup: an owned pane on the owner" "$(ep_field "$o1" .kind)" "owned"
eq "1: setup: a visit pane on the other remote carries the root id" "$(ep_field "$v2" .kind) $(opt %2 @rw-root-id)" "visit $rid1"
bash "$REFRESH" --pane %3
eq "1: setup: a local pane in the remote root is off-owner" "$(opt %3 @rw-off-owner)" "1"
rw reclaim --force "$r1" >/dev/null 2>&1
eq "1: reclaim: exit 0" "$?" "0"
eq "1: the owner's pane got its local shell back" "$(opt %1 @rw-endpoint)" ""
eq "1: the visit pane on the other remote is untouched" "$(opt %2 @rw-endpoint)" "$v2"
check "1: ... its endpoint still registered, never closed" bash -c "[ -f '$(rw_endpoint_file "$v2")' ] && [ ! -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$v2.json' ]"
check "1: ... and never respawned" bash -c "! grep -q '^tmux respawn-pane -k -t %2 -c .* exec' '$FAKE_EVENTS'"
eq "1: the chip of the root's panes was recomputed (finding 10)" "$(opt %3 @rw-off-owner)" ""
eq "1: rw_root_bound_panes lists only the given endpoints' panes" "$(rw_root_bound_panes "$rid1" "$v2")" "%2${T}$v2"
eq "1: ... and none for no endpoints, whatever @rw-root-id says" "$(rw_root_bound_panes "$rid1")" ""

# --- 2: the source session is absent ------------------------------------------------
p2="$H/Developer/p2"
mkdir -p "$p2" "$W/Developer/p2"
pane_line %4 "$p2"
rw switch --pane %4 --to fakeworker >/dev/null 2>&1
v4="$(opt %4 @rw-endpoint)"
remote %4 "$W/Developer/p2"
# The worker's boot restore wrapper, reporting $FAKE_RESTORE_STATE_FILE.
mkdir -p "$W/.config/tmux" "$W/.config/setup/templates"
printf '#!/bin/sh\ncase "$1" in --state) cat "%s" ;; *) exit 0 ;; esac\n' "$SANDBOX/restore-state" \
  >"$W/.config/setup/templates/tmux-resurrect-restore.sh"
chmod +x "$W/.config/setup/templates/tmux-resurrect-restore.sh"
export FAKE_REMOTE_ABSENT=1
echo restoring >"$SANDBOX/restore-state"
: >"$FAKE_EVENTS"
rw switch --pane %4 --to local >/dev/null 2>"$SANDBOX/err"
eq "2: session absent while its remote restores: exit 1" "$?" "1"
check "2: ... one rw: line saying so" bash -c "[ \$(wc -l <'$SANDBOX/err') -eq 1 ] && grep -q '^rw: .*restoring' '$SANDBOX/err'"
check "2: ... the endpoint was not closed" bash -c "! [ -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$v4.json' ] && [ -f '$(rw_endpoint_file "$v4")' ]"
eq "2: ... the pane is still on it" "$(opt %4 @rw-endpoint)" "$v4"
check "2: ... and was not respawned" bash -c "! grep -q '^tmux respawn-pane' '$FAKE_EVENTS'"
echo "incomplete /tmp/tmux-resurrect-1-restore-incomplete" >"$SANDBOX/restore-state"
rw switch --pane %4 --to local >/dev/null 2>"$SANDBOX/err"
eq "2: session absent after an incomplete restore: exit 1" "$?" "1"
echo ready >"$SANDBOX/restore-state"
rw_write_json_atomic "$(rw_endpoint_file "$v4")" "$(rw_read_endpoint "$v4" | jq -c '.agent = {provider: "claude", session_id: "s-4", state: "handed-off"}')"
rw switch --pane %4 --to local >/dev/null 2>"$SANDBOX/err"
eq "2: session absent, the endpoint records an agent: exit 1" "$?" "1"
check "2: ... one rw: line naming the agent" bash -c "[ \$(wc -l <'$SANDBOX/err') -eq 1 ] && grep -q '^rw: .*claude agent' '$SANDBOX/err'"
check "2: ... nothing closed" bash -c "! [ -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$v4.json' ]"
rw_write_json_atomic "$(rw_endpoint_file "$v4")" "$(rw_read_endpoint "$v4" | jq -c '.agent = {provider: null, session_id: null, state: null}')"
rw switch --pane %4 --to local >/dev/null 2>"$SANDBOX/err"
eq "2: session absent, remote ready, no agent: a bare shell, exit 0" "$?" "0"
check "2: ... the endpoint closed" tomb "$v4"
unset FAKE_REMOTE_ABSENT
rm -rf "$W/.config"

# --- 3: locks and background transfers -----------------------------------------------
p3="$H/Developer/p3"
mkdir -p "$p3" "$W/Developer/p3"
rid3="$(rw_root_id Developer/p3)"
pane_line %5 "$p3"
sleep 60 &
holder=$!
mkdir -p "$(rw_bg_dir)/$rid3"
echo "$holder" >"$(rw_bg_dir)/$rid3/pid"
jq -nc --arg r "$p3" '{verb: "handoff", root_local: $r}' >"$(rw_bg_dir)/$rid3/job.json"
: >"$FAKE_EVENTS"
rw switch --pane %5 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "3: a background transfer of the root runs: exit 7" "$?" "7"
check "3: ... one rw: line saying so" bash -c "[ \$(wc -l <'$SANDBOX/err') -eq 1 ] && grep -q '^rw: a background transfer of ~/Developer/p3 is running' '$SANDBOX/err'"
check "3: ... before anything was created" bash -c "! grep -q 'new-session' '$FAKE_EVENTS'"
eq "3: ... the pane untouched" "$(opt %5 @rw-endpoint)" ""
rm -rf "$(rw_bg_dir)/${rid3:?}"
mkdir -p "$(rw_root_lock_dir "$rid3")"
echo "$holder" >"$(rw_root_lock_dir "$rid3")/pid"
rw switch --pane %5 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "3: another rw operation holds the root (a visit switch too): exit 1" "$?" "1"
check "3: ... saying so" grep -q 'another rw operation on this root' "$SANDBOX/err"
rm -rf "$(rw_root_lock_dir "$rid3")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rw switch --pane %5 --to fakeworker >/dev/null 2>&1
eq "3: with neither, the visit switch runs" "$?" "0"
check "3: ... and released the lock" test ! -e "$(rw_root_lock_dir "$rid3")"

# --- 4: owned or visit, decided after pending actions --------------------------------
p4="$H/Developer/p4"
make_plain "$p4"
rid4="$(rw_root_id Developer/p4)"
rw handoff --worker fakeworker --root "$p4" >/dev/null 2>&1
eq "4: setup: handoff" "$?" "0"
eq "4: rw_owner_for_path (I2): root, worker, root_local" "$(rw_owner_for_path "$p4/data")" "$rid4	fakeworker	$p4"
rw_owned_record_write "$rid4" "$(rw_owned_record_read "$rid4" | jq -c '.pending = {action: "forget", reason: "test", at: "now"}')"
rw_owner_for_path "$p4/data" >/dev/null
eq "4: rw_owner_for_path: a pending forget does not count" "$?" "1"
pane_line %6 "$p4/data"
rw switch --pane %6 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "4: switch to the remote of a pending-forget root: exit 0" "$?" "0"
e6="$(opt %6 @rw-endpoint)"
check "4: the pending forget ran first (the record is gone)" test ! -e "$(rw_owned_record_file "$rid4")"
eq "4: so the pane is a visit, never an owned endpoint of a dead record" "$(ep_field "$e6" .kind)" "visit"
check "4: ... with its visit marker" test -f "$markers/$e6.json"
mirror_rec="$SANDBOX/mirror.json"
rw_record_new 12345 Developer/m "$H/Developer/m" plain fakeworker "$W/Developer/m" |
  jq -c '.owner = "worker" | .focus_machine_id = "another-machine"' >"$mirror_rec"
mkdir -p "$H/Developer/m"
rw_owned_record_write 12345 "$(cat "$mirror_rec")"
rw_owner_for_path "$H/Developer/m" >/dev/null
eq "4: rw_owner_for_path: another machine's mirror does not count" "$?" "1"
rw_owned_record_remove 12345
n_before="$(find "$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints" -name '*.json' | wc -l | tr -d ' ')"
rw_endpoint_open owned fakeworker "$W" id %6 99999 Developer/gone plain "$H/Developer/gone" "$W/Developer/gone" \
  "$H/Developer/gone" "$W" test >/dev/null 2>&1
eq "4: rw_endpoint_open owned with no record to join: fails" "$?" "1"
eq "4: ... and leaves nothing registered" "$(find "$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints" -name '*.json' | wc -l | tr -d ' ')" "$n_before"

# --- 5: mirror push failures -----------------------------------------------------------
p5="$H/Developer/p5"
make_plain "$p5"
rid5="$(rw_root_id Developer/p5)"
pane_line %7 "$p5/data"
rw switch --pane %7 --to fakeworker >/dev/null 2>&1
v7="$(opt %7 @rw-endpoint)"
check "5: setup: a visit pane with its marker" test -f "$markers/$v7.json"
# The worker's mirror cannot be written: record.json there is a directory.
mkdir -p "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$rid5/record.json/x"
rw handoff --worker fakeworker --root "$p5" >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "5: handoff with a failing mirror push: exit 0 (warned)" "$?" "0"
eq "5: the visit pane was adopted" "$(ep_field "$v7" .kind)" "owned"
check "5: ... into the record" in_record "$rid5" "$v7"
check "5: ... but keeps its visit marker, since no mirror lists it" test -f "$markers/$v7.json"
check "5: ... saying so" grep -q 'keep their visit markers' "$SANDBOX/err"
pane_line %8 "$p5"
: >"$FAKE_EVENTS"
rw switch --pane %8 --to fakeworker >/dev/null 2>"$SANDBOX/err"
eq "5: an owned switch whose mirror push fails: exit 1" "$?" "1"
check "5: ... saying so" grep -q 'ownership mirror' "$SANDBOX/err"
eq "5: ... the pane is untouched" "$(opt %8 @rw-endpoint)" ""
eq "5: ... the record lists only the adopted pane" "$(jq -c .endpoints "$(rw_owned_record_file "$rid5")")" "[\"$v7\"]"
check "5: ... and the new session was closed again" grep -q "kill-session -t '=rw-" "$FAKE_EVENTS"
rm -rf "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$rid5/record.json"
rw_mirror_push_from_record fakeworker "$W" "$rid5"

# --- 6: rw switch --to local --force (I4) ------------------------------------------------
p6="$H/Developer/p6"
mkdir -p "$p6" "$W/Developer/p6"
pane_line %10 "$p6"
rw switch --pane %10 --to fakeworker >/dev/null 2>&1
v10="$(opt %10 @rw-endpoint)"
remote %10 "$W/Developer/p6"
pane_line %11 "$p5/data"
rw switch --pane %11 --to fakeworker >/dev/null 2>&1
o11="$(opt %11 @rw-endpoint)"
eq "6: setup: an owned pane" "$(ep_field "$o11" .kind)" "owned"
remote %11 "$W/Developer/p5/data"
touch "$FAKE_SSH_DOWN"
rw switch --pane %10 --to local >/dev/null 2>"$SANDBOX/err"
eq "6: unreachable source without --force: exit 6" "$?" "6"
check "6: ... naming --force" grep -q -- '--force' "$SANDBOX/err"
eq "6: ... the pane untouched" "$(opt %10 @rw-endpoint)" "$v10"
rw switch --pane %10 --to fakeworker2 --force >/dev/null 2>&1
eq "6: --force toward a remote: usage, exit 64" "$?" "64"
: >"$FAKE_EVENTS"
out="$(rw switch --pane %10 --to local --force 2>"$SANDBOX/err")"
eq "6: --force: exit 0" "$?" "0"
check "6: ... the pane got a local shell in the mapped directory" grep -q "^tmux respawn-pane -k -t %10 -c $p6 exec" "$FAKE_EVENTS"
eq "6: ... its endpoint options are gone" "$(opt %10 @rw-endpoint)$(opt %10 @remote-host)" ""
eq "6: ... one rw: line" "$(printf '%s\n' "$out" | grep -c '^rw: ')" "1"
check "6: ... saying what still runs there stops on next contact" grep -q 'stopped when that remote is next reached' <<<"$out"
eq "6: the endpoint stays registered with a pending close" "$(ep_field "$v10" .pending.action)" "close"
check "6: ... not closed yet" bash -c "! [ -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$v10.json' ]"
rw switch --pane %11 --to local --force >/dev/null 2>&1
eq "6: --force on an owned pane: exit 0" "$?" "0"
check "6: ... it left the record" bash -c "! jq -e --arg e '$o11' '.endpoints | index(\$e)' '$(rw_owned_record_file "$rid5")' >/dev/null"
eq "6: ... pending close" "$(ep_field "$o11" .pending.action)" "close"
# A pane on a remote that is gone from config.json.
pane_line %12 "$p6"
rw_write_json_atomic "$(rw_endpoint_file e0000012)" "$(jq -nc --arg p "$p6" '{endpoint_id: "e0000012", kind: "visit", worker: "goneworker",
  workspace: {focus_path: $p, remote_path: "/x", root_local: $p, worker_root: "/x"}}')"
setp %12 @rw-endpoint e0000012
setp %12 @rw-worker goneworker
setp %12 @remote-host goneworker
rm -f "$FAKE_SSH_DOWN"
: >"$FAKE_SSH_LOG"
rw switch --pane %12 --to local >/dev/null 2>&1
eq "6: a remote no longer in config.json, without --force: exit 6" "$?" "6"
rw switch --pane %12 --to local --force >/dev/null 2>&1
eq "6: ... with --force: exit 0" "$?" "0"
check "6: ... never asked over ssh" bash -c "! grep -q '^goneworker' '$FAKE_SSH_LOG'"
# Next contact with fakeworker closes the two pending endpoints.
: >"$FAKE_EVENTS"
rw_reconcile_pending fakeworker "$W" 2>/dev/null; rw_root_unlock_all
check "6: on contact: the visit endpoint is closed" tomb "$v10"
check "6: ... its session killed there" grep -q "kill-session -t '=$(rw_session_name "$v10")'" "$FAKE_EVENTS"
check "6: ... its marker gone" test ! -e "$markers/$v10.json"
check "6: on contact: the owned endpoint is closed too" tomb "$o11"
check "6: ... and the mirror no longer lists it" \
  bash -c "! jq -e --arg e '$o11' '.endpoints | index(\$e)' '$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$rid5/record.json' >/dev/null"
check "6: the gone remote's endpoint stays pending" test -f "$(rw_endpoint_file e0000012)"

# --- 7 and 8: remote to remote with an agent -------------------------------------------
p7="$H/Developer/p7"
mkdir -p "$p7" "$W/Developer/p7"
pane_line %13 "$p7"
rw switch --pane %13 --to fakeworker >/dev/null 2>&1
v13="$(opt %13 @rw-endpoint)"
remote %13 "$W/Developer/p7"
echo "999990 999999 /x/.cache/claudef/bin/2.1.327 --resume live-7" >"$FAKE_PS_EXTRA"
jq -nc --arg cwd "$W/Developer/p7" '{tool: "claude", session_id: "live-7", cwd: $cwd}' >"$state_dir/pane-90.json"
export FAKE_TMUX_REMOTE_CMD=claude
export FAKE_VER_LOCAL=1.0 FAKE_VER_fakeworker=2.0 FAKE_VER_fakeworker2=1.0
: >"$FAKE_EVENTS"
rw switch --pane %13 --to fakeworker2 >/dev/null 2>"$SANDBOX/err"
eq "8: destination remote older than the source remote: exit 3" "$?" "3"
check "8: ... saying which" grep -q "destination remote's claude CLI (1.0) is older than the one (2.0)" "$SANDBOX/err"
check "8: ... nothing created" bash -c "! grep -q 'new-session' '$FAKE_EVENTS'"
eq "8: ... the pane untouched" "$(opt %13 @rw-endpoint)" "$v13"
# This machine newer than both remotes: no matter (the old gate refused).
export FAKE_VER_LOCAL=9.0 FAKE_VER_fakeworker=1.0 FAKE_VER_fakeworker2=1.0
export FAKE_RESPAWN_FAIL=1
: >"$FAKE_EVENTS"
rw switch --pane %13 --to fakeworker2 >/dev/null 2>"$SANDBOX/err"
eq "7: agent moved remote to remote, the respawn fails: exit 1" "$?" "1"
check "8: the gate compared the two remotes, not this machine" bash -c "! grep -q 'older' '$SANDBOX/err'"
n13="$(opt %13 @rw-endpoint)"
check "7: the pane is bound to the new endpoint" test -n "$n13" -a "$n13" != "$v13"
check "7: ... which stays registered (its agent runs there)" test -f "$(rw_endpoint_file "$n13")"
check "7: the source endpoint is closed, not leaked" tomb "$v13"
check "7: ... its session killed" grep -q "kill-session -t '=$(rw_session_name "$v13")'" "$FAKE_EVENTS"
check "7: ... after the source agent stopped" order "kill -TERM 999990" "kill-session -t '=$(rw_session_name "$v13")'"
unset FAKE_RESPAWN_FAIL FAKE_VER_LOCAL FAKE_VER_fakeworker FAKE_VER_fakeworker2
export FAKE_TMUX_REMOTE_CMD=zsh
: >"$FAKE_PS_EXTRA"
rm -f "$state_dir/pane-90.json"

# --- 9: the remote probe's hard deadline, and --dir-of -----------------------------------
pane_line %15 "$p7"
rw switch --pane %15 --to fakeworker >/dev/null 2>&1
remote %15 "$W/Developer/p7"
mkdir -p "$W/Developer/p7/deep"
eq "9: rw_pane_remote_probe: the live directory, mapped back, and the command" \
  "$(FAKE_REMOTE_CWD="$W/Developer/p7/deep" rw_pane_remote_probe %15)" "$p7/deep	zsh"
rw_pane_remote_probe %3 >/dev/null
eq "9: ... a local pane: exit 1" "$?" "1"
start=$SECONDS
FAKE_REMOTE_CWD="$W/Developer/p7/deep" FAKE_REMOTE_HANG=8 rw_pane_remote_probe %15 >/dev/null
eq "9: a remote that never answers: exit 6" "$?" "6"
check "9: ... at the status timeout, not when ssh gives up" test $((SECONDS - start)) -le 4
start=$SECONDS
eq "9: rw_pane_dir --live falls back to the title then" \
  "$(FAKE_REMOTE_CWD="$W/Developer/p7/deep" FAKE_REMOTE_HANG=8 rw_pane_dir %15 --live)" "$p7"
check "9: ... within the deadline" test $((SECONDS - start)) -le 4
pane_line %16 "$H"
FAKE_REMOTE_CWD="$W/Developer/p7/deep" rw switch --pane %16 --to fakeworker --dir-of %15 >/dev/null 2>&1
eq "9: --dir-of: exit 0" "$?" "0"
eq "9: ... in the source pane's live directory" "$(ep_field "$(opt %16 @rw-endpoint)" .workspace.focus_path)" "$p7/deep"
rw switch --pane %16 --to local --dir "$p7" --dir-of %15 >/dev/null 2>&1
eq "9: --dir and --dir-of together: exit 64" "$?" "64"

# --- 10: rw forget and pending reconciliation refresh the chip ------------------------------
p10="$H/Developer/p10"
make_plain "$p10"
rw handoff --worker fakeworker --root "$p10" >/dev/null 2>&1
pane_line %17 "$p10"
bash "$REFRESH" --pane %17
eq "10: setup: off-owner" "$(opt %17 @rw-off-owner)" "1"
touch "$FAKE_SSH_DOWN"
rw forget --force "$p10" >/dev/null 2>&1
eq "10: forget with the remote unreachable: exit 6" "$?" "6"
eq "10: ... the pending forget cleared the chip" "$(opt %17 @rw-off-owner)" ""
rm -f "$FAKE_SSH_DOWN"
setp %17 @rw-off-owner 1
rw_reconcile_pending fakeworker "$W" 2>/dev/null; rw_root_unlock_all
check "10: on contact the pending forget ran" test ! -e "$(rw_owned_record_file "$(rw_root_id Developer/p10)")"
eq "10: ... and recomputed the chip" "$(opt %17 @rw-off-owner)" ""
p10b="$H/Developer/p10b"
make_plain "$p10b"
rw handoff --worker fakeworker --root "$p10b" >/dev/null 2>&1
pane_line %18 "$p10b"
bash "$REFRESH" --pane %18
rw forget --force "$p10b" >/dev/null 2>&1
eq "10: forget: exit 0" "$?" "0"
eq "10: ... the chip recomputed" "$(opt %18 @rw-off-owner)" ""

# --- I1: rw bg --root ----------------------------------------------------------------------
export RW_BG_RW_BIN="$SANDBOX/fake-rw"
printf '#!/bin/sh\necho "$@" >>"%s"\n' "$SANDBOX/bg-args" >"$RW_BG_RW_BIN"
chmod +x "$RW_BG_RW_BIN"
: >"$SANDBOX/bg-args"
pi1="$H/Developer/i1"
mkdir -p "$pi1/sub"
pane_line %19 "$H"
out="$("$RW_PLUGIN/libexec/rw-bg" handoff --worker fakeworker --pane %19 --root "$pi1" 2>&1)"
eq "I1: bg handoff --root from a pane elsewhere: exit 0" "$?" "0"
wait_for 10 grep -q 'handoff' "$SANDBOX/bg-args"
eq "I1: ... the runner hands that root off" "$(head -n1 "$SANDBOX/bg-args")" "handoff --worker fakeworker --root $pi1 --pane %19"
"$RW_PLUGIN/libexec/rw-bg" handoff --worker fakeworker --pane %19 --root "$H/Developer/nope" >/dev/null 2>&1
eq "I1: ... a --root that does not exist: exit 7" "$?" "7"
"$RW_PLUGIN/libexec/rw-bg" handback --pane %19 --root "$pi1" >/dev/null 2>&1
eq "I1: bg handback --root of a root that is not remote: exit 7" "$?" "7"
pi2="$H/Developer/i2"
make_plain "$pi2"
rw handoff --worker fakeworker --root "$pi2" >/dev/null 2>&1
wait_for 10 bash -c "! ls '$(rw_bg_dir)'/* >/dev/null 2>&1"
: >"$SANDBOX/bg-args"
"$RW_PLUGIN/libexec/rw-bg" handback --pane %19 --root "$pi2" >/dev/null 2>&1
eq "I1: bg handback --root from a pane elsewhere: exit 0" "$?" "0"
wait_for 10 grep -q 'handback' "$SANDBOX/bg-args"
check "I1: ... the runner hands that root back" grep -q "^handback --root $pi2 --pane %19 --wait-idle" "$SANDBOX/bg-args"
wait_for 10 bash -c "! ls '$(rw_bg_dir)'/* >/dev/null 2>&1"

finish
