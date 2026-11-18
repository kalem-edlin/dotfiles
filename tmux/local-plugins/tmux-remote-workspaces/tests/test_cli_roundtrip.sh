#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# The rw command surface end to end against a same-host fake worker (fake
# ssh, stub tmux, so roots with zero live panes): handoff, open, handback,
# conflicts, unreachable worker (exit 6), reclaim --force, forget (direct
# and pending), status --json, ownership records and worker mirrors.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
record() { rw_owned_record_read "$(rw_root_id "$1")"; }
mirror() { cat "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$(rw_root_id "$1")/record.json" 2>/dev/null; }

plain="$HOME/Developer/idol-app"
make_plain "$plain"
wplain="$FAKE_WORKER_HOME/Developer/idol-app"

# --- handoff -------------------------------------------------------------
rw handoff --worker fakeworker --root "$plain" >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "handoff of a plain root: exit 0" "$?" "0"
check "handoff: the worker copy lands at <worker home>/<root_rel>" trees_equal "$plain" "$wplain"
eq "record: owner worker" "$(record Developer/idol-app | jq -r .owner)" "worker"
eq "record: kind plain" "$(record Developer/idol-app | jq -r .kind)" "plain"
eq "record: worker_root" "$(record Developer/idol-app | jq -r .worker_root)" "$wplain"
check "record: manifests on the focus side" test -s "$(rw_owned_record_dir "$(rw_root_id Developer/idol-app)")/manifest.worker.tsv"
eq "mirror: owner worker, root_local = worker path" "$(mirror Developer/idol-app | jq -r '.owner + " " + .root_local')" "worker $wplain"
check "mirror: manifests on the worker side" test -s "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$(rw_root_id Developer/idol-app)/manifest.focus.tsv"
check "held index lists the worker" test -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/held/fakeworker/$(rw_root_id Developer/idol-app).json"
check "no ~/rw-workspaces on the worker" test ! -e "$FAKE_WORKER_HOME/rw-workspaces"
eq "rw_owned_root_for_path finds it from a subdirectory" "$(rw_owned_root_for_path "$plain/scripts/work")" "$(rw_root_id Developer/idol-app)"

rw handoff --worker fakeworker --root "$plain" >/dev/null 2>&1
eq "handoff of a root that is already remote: exit 7" "$?" "7"
rw handoff --worker fakeworker --root "$plain/scripts" >/dev/null 2>&1
eq "handoff of a directory inside a remote root: exit 7" "$?" "7"
rw handoff --worker nosuch --root "$plain" >/dev/null 2>&1
eq "undeclared worker: exit 64" "$?" "64"

# --- open --------------------------------------------------------------------
rw open --pane %9 --root "$plain" >/dev/null 2>"$SANDBOX/open.err"
eq "open in a remote root: exit 0" "$?" "0"
ep="$(record Developer/idol-app | jq -r '.endpoints[0]')"
check "open: endpoint recorded on the root" test -n "$ep"
ej="$(rw_read_endpoint "$ep")"
eq "endpoint carries the C3 fields" "$(jq -c '[has("root_id"), has("root_rel"), has("focus_session_uuid"), has("focus_session_name"), has("focus_window_index"), has("focus_pane_index")]' <<<"$ej")" \
  "[true,true,true,true,true,true]"
eq "endpoint remote path is the worker root" "$(jq -r .workspace.remote_path <<<"$ej")" "$wplain"
check "open: hidden session created on the worker" grep -q "^new-session -d -s rw-[0-9a-f]*-$ep -c $wplain\$" "$FAKE_TMUX_LOG"
check "open: hidden options applied (prefix None, status off)" \
  bash -c "grep -q '^set-option -t rw-[0-9a-f]*-$ep prefix None\$' '$FAKE_TMUX_LOG' && grep -q '^set-option -t rw-[0-9a-f]*-$ep status off\$' '$FAKE_TMUX_LOG'"
check "open: @rw-root-id set on the pane" grep -q "set-option -pqt %9 @rw-root-id $(rw_root_id Developer/idol-app)" "$FAKE_TMUX_LOG"
mkdir -p "$HOME/Developer/local-only"
rw open --pane %9 --root "$HOME/Developer/local-only" >/dev/null 2>&1
eq "open in a root that is not remote: exit 7" "$?" "7"

# --- handback ----------------------------------------------------------------
echo remote-edit >"$wplain/README"
rm "$wplain/data/b.csv"
rw handback --root "$plain" >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "handback: exit 0" "$?" "0"
check "handback: identical trees" trees_equal "$plain" "$wplain"
check "handback: remote deletion propagated" test ! -e "$plain/data/b.csv"
check "handback: record deleted (nothing pending)" test ! -e "$(rw_owned_record_dir "$(rw_root_id Developer/idol-app)")"
check "handback: endpoint closed (tombstone, no registry entry)" bash -c "[ -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/tombstones/$ep.json' ] && [ ! -f '$TMUX_REMOTE_WORKSPACES_STATE_DIR/endpoints/$ep.json' ]"
eq "handback: mirror stays, owner focus" "$(mirror Developer/idol-app | jq -r .owner)" "focus"
rw handback --root "$plain" >/dev/null 2>&1
eq "handback of a local root: exit 7" "$?" "7"

# --- conflicts on the frozen copy ----------------------------------------------
rw handoff --worker fakeworker --root "$plain" >/dev/null 2>&1
eq "second handoff (worker copy unchanged): exit 0" "$?" "0"
sleep 1
echo "edited the frozen laptop copy" >"$plain/data/a.csv"
out="$(rw handback --root "$plain" 2>/dev/null)"
eq "handback over an edited frozen copy: exit 5" "$?" "5"
eq "exit 5 names the file" "$out" "$(printf 'conflict\tdata/a.csv\tchanged')"
eq "exit 5: still remote" "$(record Developer/idol-app | jq -r .owner)" "worker"
rw handback --root "$plain" --resolve keep-both >/dev/null 2>&1
eq "handback --resolve keep-both: exit 0" "$?" "0"
eq "keep-both: the laptop edit is kept beside the owner's file" "$(cat "$plain"/data/a.csv.local-*)" "edited the frozen laptop copy"
eq "keep-both: the owner's version is in place" "$(cat "$plain/data/a.csv")" "1"

sleep 1
echo "edited the stale remote copy" >"$wplain/data/a.csv"
out="$(rw handoff --worker fakeworker --root "$plain" 2>/dev/null)"
eq "handoff over an edited stale remote copy: exit 5" "$?" "5"
eq "exit 5 names the remote file" "$out" "$(printf 'conflict\tdata/a.csv\tchanged')"
rw handoff --worker fakeworker --root "$plain" --resolve overwrite >/dev/null 2>&1
eq "handoff --resolve overwrite: exit 0" "$?" "0"
eq "overwrite: the owner's version wins" "$(cat "$wplain/data/a.csv")" "1"

# --- unreachable worker, reclaim -------------------------------------------------
touch "$FAKE_SSH_DOWN"
rw handback --root "$plain" >/dev/null 2>&1
eq "handback with the worker unreachable: exit 6" "$?" "6"
eq "exit 6: nothing changed" "$(record Developer/idol-app | jq -r .owner)" "worker"
rw reclaim "$plain" >/dev/null 2>&1
eq "reclaim without --force: exit 64" "$?" "64"
rw reclaim --force "$plain" >/dev/null 2>&1
eq "reclaim --force: exit 0" "$?" "0"
eq "reclaim: owner focus, stale worker, pending reconcile" \
  "$(record Developer/idol-app | jq -c '[.owner, .stale_worker, .pending.action]')" '["focus",true,"reconcile"]'
rw_owned_root_for_path "$plain" >/dev/null
eq "reclaimed root is local again for lookups" "$?" "1"
rm -f "$FAKE_SSH_DOWN"
rw handoff --worker fakeworker --root "$plain" >/dev/null 2>&1
eq "next contact reconciles, then the handoff proceeds: exit 0" "$?" "0"
eq "after reconcile + handoff: clean worker-owned record" "$(record Developer/idol-app | jq -c '[.owner, has("pending"), has("stale_worker")]')" '["worker",false,false]'

# --- worktree root -------------------------------------------------------------
make_worktree "$HOME/Developer/ce"
wt="$HOME/Developer/ce/wt"
rw handoff --worker fakeworker --root "$wt" >/dev/null 2>"$SANDBOX/err"
eq "handoff of a linked worktree: exit 0" "$?" "0"
check "worktree: identical trees incl. gitignored files" trees_equal "$wt" "$FAKE_WORKER_HOME/Developer/ce/wt"
eq "worktree: kind git" "$(record Developer/ce/wt | jq -r .kind)" "git"
check "worktree manifest ends in #git" bash -c "tail -n1 '$(rw_owned_record_dir "$(rw_root_id Developer/ce/wt)")/manifest.focus.tsv' | grep -q '^#git'"

# --- status --json -------------------------------------------------------------
eq "status --json: one array of records" "$(rw status --json | jq -r 'map(.root_rel + ":" + .owner) | join(",")')" \
  "Developer/ce/wt:worker,Developer/idol-app:worker"

# --- forget ------------------------------------------------------------------------
rw forget "$plain" >/dev/null 2>&1
eq "forget: exit 0" "$?" "0"
check "forget: worker copy deleted" test ! -e "$wplain"
check "forget: worker mirror deleted" test ! -e "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$(rw_root_id Developer/idol-app)"
check "forget: focus record deleted" test ! -e "$(rw_owned_record_dir "$(rw_root_id Developer/idol-app)")"
check "forget: local copy untouched" test -f "$plain/README"

mkdir -p "$FAKE_WORKER_HOME/Developer/not-ours"
echo precious >"$FAKE_WORKER_HOME/Developer/not-ours/file"
rw forget "$HOME/Developer/not-ours" --worker fakeworker >/dev/null 2>&1
eq "forget of a root never handed off: exit 0" "$?" "0"
check "forget never deletes a remote directory without its mirror record" test -f "$FAKE_WORKER_HOME/Developer/not-ours/file"

touch "$FAKE_SSH_DOWN"
rw forget "$wt" >/dev/null 2>&1
eq "forget with the worker unreachable: exit 6" "$?" "6"
eq "pending forget recorded" "$(record Developer/ce/wt | jq -r .pending.action)" "forget"
check "worker copy still there while unreachable" test -d "$FAKE_WORKER_HOME/Developer/ce/wt"
rm -f "$FAKE_SSH_DOWN"
mkdir -p "$HOME/Developer/other"
echo x >"$HOME/Developer/other/x"
rw handoff --worker fakeworker --root "$HOME/Developer/other" >/dev/null 2>&1
eq "next contact (an unrelated handoff): exit 0" "$?" "0"
check "pending forget ran on next contact: worker copy deleted" test ! -e "$FAKE_WORKER_HOME/Developer/ce/wt"
check "pending forget ran on next contact: record deleted" test ! -e "$(rw_owned_record_dir "$(rw_root_id Developer/ce/wt)")"

check "every ssh call went to the fake worker" bash -c "! cut -f1 '$FAKE_SSH_LOG' | grep -vqx fakeworker"
finish
