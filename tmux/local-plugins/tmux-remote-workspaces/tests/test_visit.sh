#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # literal tmux session ids ($1) and formats
# Visit endpoints (soft-switched panes, CS2) outside `rw switch` itself:
#
#   K  keys: prefix c (rw-new-window.sh) and the splits (rw-split.sh) follow
#      the pane host, an off-owner remote pane included: `rw switch` to the
#      same remote in the source pane's live directory; a local pane gets a
#      plain local window
#   L  laptop restore: a visit endpoint is matched and reattached like an
#      owned one (rw_restore_match)
#   W  worker restore: rw-worker-post-restore.sh keeps a restored visit
#      session (its marker names it) and re-applies its hidden options
#   G  reconcile and reconcile-worker never close a registered visit
#      endpoint, which no record lists
#   A  handoff adopts a visit pane already on that remote in the root as an
#      owned pane (no second session); a visit pane on another remote stays;
#      hand-back moves the record's panes (the adopted one too) and leaves
#      the other visit pane where it is
#
# Against the pane-aware tmux stub and the same-host fake ssh. No tmux
# server, no ssh.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/roots.sh
source "$RW_PLUGIN/scripts/roots.sh"
# shellcheck source=../scripts/rw-post-restore.sh
source "$RW_PLUGIN/scripts/rw-post-restore.sh"

export FAKE_EVENTS="$SANDBOX/events"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
jq '.workers += [{"alias": "fakeworker2", "platform": "darwin", "notes": "second test double"}]' \
  "$TMUX_REMOTE_WORKSPACES_CONFIG" >"$SANDBOX/config2.json"
mv "$SANDBOX/config2.json" "$TMUX_REMOTE_WORKSPACES_CONFIG"
# Only the editor adapter: no agent is detected anywhere.
export RW_ADAPTERS_DIR="$SANDBOX/adapters"
mkdir -p "$RW_ADAPTERS_DIR"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
opt() { tr '\t' '\n' <"$FAKE_TMUX_PANES" | awk -v p="pane_id=$1" '/^pane_id=/ { cur = $0 } cur == p' | sed -n "s/^$2=//p" | head -n1; }
setp() { tmux set-option -pqt "$1" "$2" "$3"; }
ep_field() { rw_read_endpoint "$1" 2>/dev/null | jq -r "$2"; }
pane_line() { # <id> <path> <cmd> <pid> <window>
  printf 'pane_id=%s\tpane_current_path=%s\tsession_id=$1\tsession_name=s1\twindow_index=%s\tpane_index=0\tpane_current_command=%s\tpane_pid=%s\tpane_width=161\n' \
    "$1" "$2" "$5" "$3" "$4"
}
remote() { setp "$1" @remote-host "$(opt "$1" @rw-worker)"; setp "$1" pane_title "$2"; }
H="$HOME" W="$FAKE_WORKER_HOME"
markers="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/visits"

proj="$H/Developer/vproj"
make_plain "$proj"
mkdir -p "$W/Developer/vproj/data"
{
  pane_line %1 "$proj/data" zsh 999981 1
  pane_line %2 "$proj" zsh 999982 2
  pane_line %3 "$proj" zsh 999983 3
} >"$FAKE_TMUX_PANES"

rw switch --pane %1 --to fakeworker >/dev/null 2>&1
v1="$(opt %1 @rw-endpoint)"
eq "setup: %1 is a visit pane on the remote" "$(ep_field "$v1" '.kind + " " + .worker')" "visit fakeworker"
rw switch --pane %2 --to fakeworker2 >/dev/null 2>&1
v2="$(opt %2 @rw-endpoint)"
eq "setup: %2 is a visit pane on the other remote" "$(ep_field "$v2" '.kind + " " + .worker')" "visit fakeworker2"
remote %1 "$W/Developer/vproj/data/sub"
mkdir -p "$W/Developer/vproj/data/sub"

# --- K: prefix c and splits follow the pane host ------------------------------------------
: >"$FAKE_TMUX_LOG"
: >"$FAKE_SSH_LOG"
"$RW_PLUGIN/scripts/rw-new-window.sh" %1
nw="$(grep '^new-window' "$FAKE_TMUX_LOG")"
check "K: prefix c on a visit pane: a new window in the pane's session" grep -q '^new-window -t \$1: ' <<<"$nw"
check "K: ... whose pane switches to the same remote, in the source pane's live directory" \
  grep -qF "$RW_PLUGIN/scripts/rw switch --to fakeworker --dir-of %1; exec \${SHELL:-/bin/sh} -l" <<<"$nw"
check "K: ... starting from the nearest local directory of its title" grep -qF -- "-c $proj/data " <<<"$nw"
check "K: ... and the key never waited on ssh (fix wave A, finding 9)" test ! -s "$FAKE_SSH_LOG"
: >"$FAKE_TMUX_LOG"
"$RW_PLUGIN/scripts/rw-split.sh" v %1
sp="$(grep '^split-window' "$FAKE_TMUX_LOG")"
check "K: a split of a visit pane switches to the same remote too" \
  grep -qF "split-window -v -c $proj/data -t %1 $RW_PLUGIN/scripts/rw switch --to fakeworker --dir-of %1; exec" <<<"$sp"
check "K: ... with no ssh before the pane exists" test ! -s "$FAKE_SSH_LOG"
check "K: prefix e acts on the pane the key was pressed in" \
  grep -q "^bind e run-shell -b \"tmux display-popup -c '#{client_name}' .*rw-picker.sh pick '#{pane_id}'" "$RW_PLUGIN/../../tmux.reset.conf"
: >"$FAKE_TMUX_LOG"
"$RW_PLUGIN/scripts/rw-split.sh" h %3
check "K: a split of a local pane stays local" grep -qx "split-window -h -l 60 -c $proj -t %3" "$FAKE_TMUX_LOG"
: >"$FAKE_TMUX_LOG"
"$RW_PLUGIN/scripts/rw-new-window.sh" %3
check "K: prefix c on a local pane is a plain local window" grep -qx "new-window -t \$1: -c $proj" "$FAKE_TMUX_LOG"
check "K: the binding runs the script only for a remote pane" \
  grep -q "^bind c if-shell -F '#{@remote-host}' 'run-shell \".*rw-new-window.sh #{pane_id} || true\"' 'new-window -c \"#{pane_current_path}\"'\$" "$RW_PLUGIN/../../tmux.reset.conf"

# The new pane's own `rw switch` (run inside it) gives a visit endpoint in
# that directory: covered in test_switch.sh (F).

# --- L: laptop restore ----------------------------------------------------------------------
jq -s '.' "$(rw_endpoint_file "$v1")" >"$SANDBOX/eps.json"
printf '%%7 $1 1 0 - - - s1:zsh\n' >"$SANDBOX/dump"
match="$(rw_restore_match "$SANDBOX/eps.json" "$SANDBOX/dump" "" "")"
eq "L: a visit endpoint is reattached by endpoint id like an owned one" \
  "$(jq -r '.outcome + " " + .pane_id' <<<"$match")" "reattach %7"

# --- W: worker restore -----------------------------------------------------------------------
mid="$(rw_machine_short_id)"
export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
mkdir -p "$TMUX_RESURRECT_DIR"
{
  printf 'pane\t%s\t0\t1\t:*\t0\t:/w\t1\tzsh\t:\n' "$(rw_session_name "$v1")"
  printf 'pane\trw-%s-dead0001\t0\t1\t:*\t0\t:/w\t1\tzsh\t:\n' "$mid"
} >"$TMUX_RESURRECT_DIR/snap.txt"
ln -s snap.txt "$TMUX_RESURRECT_DIR/last"
export FAKE_TMUX_SESSIONS="$SANDBOX/sessions"
now="$(date +%s)"
printf '%s %s 0\nrw-%s-dead0001 %s 0\n' "$(rw_session_name "$v1")" "$now" "$mid" "$now" >"$FAKE_TMUX_SESSIONS"
# The worker post-restore runs on the worker: there this machine's id is a
# foreign focus machine id.
mv "$(rw_machine_id_file)" "$SANDBOX/machine-id.focus"
: >"$FAKE_TMUX_LOG"
out="$("$RW_PLUGIN/scripts/rw-worker-post-restore.sh" 2>&1)"
mv "$SANDBOX/machine-id.focus" "$(rw_machine_id_file)"
check "W: the restored visit session stays" bash -c "! grep -q 'kill-session -t =$(rw_session_name "$v1")' '$FAKE_TMUX_LOG'"
check "W: a restored session nothing names is still killed" grep -q "kill-session -t =rw-$mid-dead0001" "$FAKE_TMUX_LOG"
check "W: the visit session gets its hidden options back" grep -q "^set-option -t $(rw_session_name "$v1") prefix None\$" "$FAKE_TMUX_LOG"
check "W: ... status off" grep -q "^set-option -t $(rw_session_name "$v1") status off\$" "$FAKE_TMUX_LOG"
unset FAKE_TMUX_SESSIONS

# --- G: reconcile ------------------------------------------------------------------------------
printf '{"version":1,"saved_at":"%s"}\n' "$(rw_now_iso)" >"$TMUX_RESURRECT_DIR/snap.txt.workspace_state.json"
printf '%s %s 0\n' "$(rw_session_name "$v1")" "$((now - 1000))" >"$SANDBOX/sessions"
export FAKE_TMUX_SESSIONS="$SANDBOX/sessions"
: >"$FAKE_TMUX_LOG"
"$RW_PLUGIN/libexec/reconcile" >/dev/null 2>&1
"$RW_PLUGIN/libexec/reconcile-worker" --worker fakeworker >/dev/null 2>&1
check "G: neither reconcile closes a registered visit endpoint" bash -c "! grep -q '^kill-session' '$FAKE_TMUX_LOG'"
check "G: ... it stays registered" test -f "$(rw_endpoint_file "$v1")"
unset FAKE_TMUX_SESSIONS

# --- A: handoff adopts the visit pane on that remote --------------------------------------------
id="$(rw_root_id Developer/vproj)"
: >"$FAKE_EVENTS"
rw handoff --worker fakeworker --root "$proj" >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "A: handoff of the root: exit 0" "$?" "0"
# X4: the summary names the adopted pane (it read "0 pane(s) moved" when
# only adopted panes were in the root).
eq "A: the summary counts the moved and the adopted pane" "$(cat "$SANDBOX/out")" \
  "rw: Developer/vproj is now remote on fakeworker (1 pane(s) moved, 1 already there)."
eq "A: the visit pane on that remote is now owned" "$(ep_field "$v1" '.kind + " " + .root_id')" "owned $id"
eq "A: ... with the root's worker root" "$(ep_field "$v1" .workspace.worker_root)" "$W/Developer/vproj"
check "A: ... listed in the record" bash -c "jq -e --arg e '$v1' '.endpoints | index(\$e)' '$(rw_owned_record_file "$id")' >/dev/null"
check "A: ... and in the remote's mirror" bash -c "jq -e --arg e '$v1' '.endpoints | index(\$e)' '$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$id/record.json' >/dev/null"
check "A: ... its visit marker is gone" test ! -e "$markers/$v1.json"
check "A: ... no second session for it, and its pane was not replaced" \
  bash -c "[ \$(grep -c '^tmux new-session' '$FAKE_EVENTS') -eq 1 ] && ! grep -q '^tmux respawn-pane -k -t %1 ' '$FAKE_EVENTS'"
eq "A: @rw-root-id on the adopted pane" "$(opt %1 @rw-root-id)" "$id"
eq "A: the visit pane on the other remote stays a visit" "$(ep_field "$v2" '.kind + " " + .worker')" "visit fakeworker2"
check "A: ... not in the record" bash -c "! jq -e --arg e '$v2' '.endpoints | index(\$e)' '$(rw_owned_record_file "$id")' >/dev/null"
check "A: ... and its marker stays" test -f "$markers/$v2.json"
check "A: no warning about either" bash -c "! grep -q 'already has remote endpoint' '$SANDBOX/err'"
check "A: the local pane moved as usual" test -n "$(opt %3 @rw-endpoint)"

# Hand-back: the record's panes come back, the adopted one included; the
# visit pane on the other remote stays there.
: >"$FAKE_EVENTS"
rw handback --root "$proj" >/dev/null 2>"$SANDBOX/err"
eq "A: hand-back: exit 0" "$?" "0"
check "A: the adopted pane is back here" grep -q "^tmux respawn-pane -k -t %1 -c $proj/data exec" "$FAKE_EVENTS"
check "A: ... its endpoint closed" test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$v1.json"
check "A: the other remote's visit pane was not touched" bash -c "! grep -q 'respawn-pane -k -t %2 ' '$FAKE_EVENTS' && [ -f '$(rw_endpoint_file "$v2")' ]"
eq "A: ... and stays a visit" "$(ep_field "$v2" .kind)" "visit"

finish
