#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# libexec/sync/handoff round trips (push, edit on the worker, pull) for a
# plain folder and a linked worktree: identical trees after each leg,
# deletions propagated on both channels, git divergence gate (exit 2), and
# the same round trip over the ssh exec wrapper (fake same-host ssh, rsync
# -e) into a path with a space.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

push() { # src dst manifest-in manifest-out [extra...]
  local src="$1" dst="$2" min="$3" mout="$4"
  shift 4
  "$RW_SYNC" sync --direction handoff --dest-mode local --source-path "$src" --dest-path "$dst" \
    --dest-manifest "$min" --manifest-out "$mout" "$@" >"$SANDBOX/last.json" 2>"$SANDBOX/last.err"
}
pull() { # worker-src focus-dst manifest-in manifest-out [extra...]
  local src="$1" dst="$2" min="$3" mout="$4"
  shift 4
  "$RW_SYNC" sync --direction handback --pull --dest-mode local --source-path "$src" --dest-path "$dst" \
    --dest-manifest "$min" --manifest-out "$mout" "$@" >"$SANDBOX/last.json" 2>"$SANDBOX/last.err"
}

# --- plain folder ----------------------------------------------------------
pf="$HOME/Developer/idol-app"
pw="$FAKE_WORKER_HOME/Developer/idol-app"
make_plain "$pf"
push "$pf" "$pw" "$SANDBOX/none" "$SANDBOX/p1"
eq "plain push: exit 0" "$?" "0"
check "plain push: identical trees" trees_equal "$pf" "$pw"
eq "plain push: kind detected" "$(jq -r .kind "$SANDBOX/last.json")" "plain"
check "plain push: source and dest manifests equal" cmp -s "$SANDBOX/p1/source.tsv" "$SANDBOX/p1/dest.tsv"

rm "$pw/data/b.csv" "$pw/latest"
rm -r "$pw/scripts"
echo new >"$pw/data/c.csv"
echo changed >"$pw/README"
pull "$pw" "$pf" "$SANDBOX/p1/source.tsv" "$SANDBOX/p2"
eq "plain pull: exit 0" "$?" "0"
check "plain pull: identical trees" trees_equal "$pf" "$pw"
check "plain pull: deleted file gone locally" test ! -e "$pf/data/b.csv"
check "plain pull: deleted directory gone locally" test ! -e "$pf/scripts"
check "plain pull: deleted symlink gone locally" test ! -L "$pf/latest"

# --- worktree ----------------------------------------------------------------
base="$HOME/Developer/ce"
make_worktree "$base"
wf="$base/wt"
ww="$FAKE_WORKER_HOME/Developer/ce/wt"
git -C "$wf" add t.txt
echo more >>"$wf/t.txt" # staged + unstaged on the same file
push "$wf" "$ww" "$SANDBOX/none" "$SANDBOX/g1"
eq "worktree push: exit 0" "$?" "0"
check "worktree push: identical trees (tracked, untracked, ignored)" trees_equal "$wf" "$ww"
eq "worktree push: branch carried" "$(git -C "$ww" symbolic-ref --short HEAD)" "feat"
eq "worktree push: staged state carried" "$(git -C "$ww" diff --cached --name-only)" "t.txt"
check "worktree push: manifests end in the #git row" bash -c "tail -n1 '$SANDBOX/g1/dest.tsv' | grep -q '^#git'"

git -C "$ww" commit -qam "remote work"
rm "$ww/notes.txt" "$ww/.env.local"
rm -r "$ww/build"
echo fresh >"$ww/todo.txt"
echo E2 >"$ww/.env.production"
mkdir -p "$ww/dist" && echo b >"$ww/dist/app.js"
printf 'node_modules/\n.env*\nbuild/\ndist/\n' >"$ww/.gitignore"
git -C "$ww" commit -qam "ignore dist"
pull "$ww" "$wf" "$SANDBOX/g1/source.tsv" "$SANDBOX/g2"
eq "worktree pull: exit 0" "$?" "0"
check "worktree pull: identical trees" trees_equal "$wf" "$ww"
eq "worktree pull: remote commits arrive" "$(git -C "$wf" log -1 --format=%s)" "ignore dist"
check "worktree pull: untracked file deleted on the owner is deleted" test ! -e "$wf/notes.txt"
check "worktree pull: ignored file deleted on the owner is deleted" test ! -e "$wf/.env.local"
check "worktree pull: ignored dir deleted on the owner is deleted" test ! -e "$wf/build"
eq "worktree pull: newly ignored dir carried" "$(cat "$wf/dist/app.js")" "b"
eq "worktree pull: main checkout still lists the linked worktree" \
  "$(git -C "$base/main" worktree list --porcelain | grep -c "^worktree $wf\$")" "1"

# Divergence gate: git state changed on the copy about to be overwritten.
echo "laptop edit" >>"$wf/t.txt"
push "$wf" "$ww" "$SANDBOX/g2/source.tsv" "$SANDBOX/g3"
eq "worker copy unchanged since its manifest: push ok" "$?" "0"
echo "remote edit" >>"$ww/t.txt"
pull "$ww" "$wf" "$SANDBOX/g3/source.tsv" "$SANDBOX/g4"
eq "focus copy unchanged since handoff: pull ok" "$?" "0"
echo "edit on the stale worker copy" >>"$ww/t.txt"
push "$wf" "$ww" "$SANDBOX/g4/source.tsv" "$SANDBOX/g5"
eq "worker copy edited after hand-back: push exit 2 (diverged)" "$?" "2"
eq "exit 2 touched nothing" "$(tail -n1 "$ww/t.txt")" "edit on the stale worker copy"
push "$wf" "$ww" "$SANDBOX/g4/source.tsv" "$SANDBOX/g5" --force-diverged
eq "--force-diverged overrides" "$?" "0"
check "--force-diverged took a backup first" bash -c "jq -e '.backup_dir != null' '$SANDBOX/last.json' >/dev/null"
check "after the override the trees match" trees_equal "$wf" "$ww"
git -C "$wf" commit -qm "commit on the frozen focus copy" --allow-empty
pull "$ww" "$wf" "$SANDBOX/g5/source.tsv" "$SANDBOX/g6"
eq "commit on the frozen focus copy: pull exit 2 (diverged)" "$?" "2"

# --- over the ssh exec wrapper, into a path with a space ---------------------------
sp="$HOME/Developer/with space"
make_plain "$sp"
"$RW_SYNC" sync --direction handoff --dest-mode ssh --dest-worker fakeworker \
  --source-path "$sp" --dest-path "$FAKE_WORKER_HOME/Developer/with space" \
  --dest-manifest "$SANDBOX/none" --manifest-out "$SANDBOX/s1" >/dev/null 2>"$SANDBOX/ssh.err"
eq "ssh mode push (rsync -e fake ssh, path with a space): exit 0" "$?" "0"
check "ssh mode push: identical trees" trees_equal "$sp" "$FAKE_WORKER_HOME/Developer/with space"
check "ssh mode: rsync went through the ssh wrapper" grep -q 'rsync --server' "$FAKE_SSH_LOG"
rm "$FAKE_WORKER_HOME/Developer/with space/README"
"$RW_SYNC" sync --direction handback --pull --dest-mode ssh --dest-worker fakeworker \
  --source-path "$FAKE_WORKER_HOME/Developer/with space" --dest-path "$sp" \
  --dest-manifest "$SANDBOX/s1/source.tsv" --manifest-out "$SANDBOX/s2" >/dev/null 2>>"$SANDBOX/ssh.err"
eq "ssh mode pull: exit 0" "$?" "0"
check "ssh mode pull: deletion propagated" test ! -e "$sp/README"

check "no command reached tmux beyond the stub" test ! -s "$FAKE_TMUX_LOG"
finish
