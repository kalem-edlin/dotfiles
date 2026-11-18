#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# F and G from the live smoke test:
#   F  attach-seen markers go with their endpoints; hand-back keeps only the
#      newest backup; forget prunes backups/staging on both sides and removes
#      the worker parent directories it leaves empty (never a top-level one);
#      hand-back conflict messages say "rw handback"; the worker checkout gets
#      the laptop branch's upstream
#   G  a local-path origin does not fail preflight's git-host check

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"
rw() { "$RW_PLUGIN/scripts/rw" "$@"; }

make_worktree "$HOME/Developer/grp"
wt="$HOME/Developer/grp/wt"
W="$FAKE_WORKER_HOME/Developer/grp/wt"
id="$(rw_root_id Developer/grp/wt)"
git -C "$wt" remote add origin /nonexistent/origin.git
git -C "$wt" config branch.feat.remote origin
git -C "$wt" config branch.feat.merge refs/heads/feat

# --- G + upstream ------------------------------------------------------------------
rw handoff --worker fakeworker --root "$wt" >/dev/null 2>"$SANDBOX/err"
eq "G: handoff of a worktree whose origin is a local path: exit 0" "$?" "0"
check "G: no git-host-auth failure" bash -c "! grep -q 'git-host-auth' '$SANDBOX/err'"
eq "F: worker checkout has the laptop branch's upstream" \
  "$(git -C "$W" config branch.feat.remote) $(git -C "$W" config branch.feat.merge)" "origin refs/heads/feat"
eq "F: and the same origin" "$(git -C "$W" remote get-url origin)" "/nonexistent/origin.git"

# --- hand-back: conflict wording, attach-seen, backups -------------------------------
rw open --pane %7 --root "$wt" >/dev/null 2>&1
ep="$(rw_owned_record_read "$id" | jq -r '.endpoints[0]')"
mkdir -p "$TMUX_REMOTE_WORKSPACES_STATE_DIR/attach-seen"
echo "1 2" >"$TMUX_REMOTE_WORKSPACES_STATE_DIR/attach-seen/$ep"
sleep 1
echo "frozen edit" >"$wt/notes.txt"
rw handback --root "$wt" >/dev/null 2>"$SANDBOX/err"
eq "F: hand-back conflict: exit 5" "$?" "5"
check "F: the message says rw handback" grep -q "^rw: rw handback: 1 file(s)" "$SANDBOX/err"
check "F: never 'handoff sync' during a hand-back" bash -c "! grep -q 'handoff sync' '$SANDBOX/err'"
rw handback --root "$wt" --resolve overwrite >/dev/null 2>&1
eq "F: hand-back --resolve overwrite: exit 0" "$?" "0"
check "F: the endpoint's attach-seen marker is gone" test ! -e "$TMUX_REMOTE_WORKSPACES_STATE_DIR/attach-seen/$ep"

# A few round trips leave several backups; hand-back keeps only the newest.
for _ in 1 2; do
  echo "w$RANDOM" >>"$W/t.txt" 2>/dev/null
  rw handoff --worker fakeworker --root "$wt" --force-diverged >/dev/null 2>&1
  echo "remote $RANDOM" >>"$W/t.txt"
  sleep 1
  rw handback --root "$wt" >/dev/null 2>&1
done
count_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
eq "F: one laptop-side backup kept after hand-back" "$(count_dirs "$TMUX_REMOTE_WORKSPACES_STATE_DIR/handoff-backups/root-$id")" "1"
eq "F: one worker-side backup kept after hand-back" "$(count_dirs "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/handoff-backups/root-$id")" "1"

# --- forget -----------------------------------------------------------------------
rw forget "$wt" >/dev/null 2>&1
eq "F: forget: exit 0" "$?" "0"
check "F: worker backups and staging pruned" bash -c "[ ! -e '$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/handoff-backups/root-$id' ] && [ ! -e '$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/handoff-staging/root-$id' ]"
check "F: laptop backups and staging pruned" bash -c "[ ! -e '$TMUX_REMOTE_WORKSPACES_STATE_DIR/handoff-backups/root-$id' ] && [ ! -e '$TMUX_REMOTE_WORKSPACES_STATE_DIR/handoff-staging/root-$id' ]"
check "F: the empty worker parent rw created is gone" test ! -e "$FAKE_WORKER_HOME/Developer/grp"
check "F: the top-level folder of the worker home stays" test -d "$FAKE_WORKER_HOME/Developer"
check "F: worker sessions were closed, and a save requested" test -s "$SANDBOX/worker-saves.log"

finish
