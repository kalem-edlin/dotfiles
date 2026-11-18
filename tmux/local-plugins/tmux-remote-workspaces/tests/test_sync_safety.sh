#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Sync-core safety fixes (review of fe61a15): untracked content in the
# manifest gate, per-root incoming refs, existing destination repositories,
# retry after an interrupted transfer, submodules, untracked nested repos,
# plain-root backups and the empty-owner guard, odd file names, keep-both
# copies staying put.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

push() { # src dst stored-manifest manifest-out [extra...]
  "$RW_SYNC" sync --direction handoff --dest-mode ssh --dest-worker fakeworker \
    --source-path "$1" --dest-path "$2" --dest-manifest "$3" --manifest-out "$4" \
    --backup-root "$SANDBOX/wb" --staging-root "$SANDBOX/ws" --token "root-${5:-x}" "${@:6}" \
    >"$SANDBOX/out" 2>"$SANDBOX/err"
}
pull() { # worker-src focus-dst stored-manifest manifest-out [token] [extra...]
  "$RW_SYNC" sync --direction handback --pull --dest-mode ssh --dest-worker fakeworker \
    --source-path "$1" --dest-path "$2" --dest-manifest "$3" --manifest-out "$4" \
    --token "root-${5:-x}" "${@:6}" >"$SANDBOX/out" 2>"$SANDBOX/err"
}

# --- 1: an untracked file edited on the frozen copy is a conflict ----------
make_worktree "$HOME/Developer/ce"
wt="$HOME/Developer/ce/wt"
W="$FAKE_WORKER_HOME/Developer/ce/wt"
push "$wt" "$W" "$SANDBOX/none" "$SANDBOX/m1" ce
eq "1: first push" "$?" "0"
echo "worker work" >>"$W/t.txt"
sleep 1
echo "LOCAL ONLY EDIT" >"$wt/notes.txt"
pull "$W" "$wt" "$SANDBOX/m1/source.tsv" "$SANDBOX/m2" ce
eq "1: untracked content edit on the frozen copy: exit 5" "$?" "5"
eq "1: the conflict names it" "$(cat "$SANDBOX/out")" "$(printf 'conflict\tnotes.txt\tchanged')"
eq "1: nothing overwritten" "$(cat "$wt/notes.txt")" "LOCAL ONLY EDIT"
pull "$W" "$wt" "$SANDBOX/m1/source.tsv" "$SANDBOX/m2" ce --resolve keep-both
eq "1: keep-both: exit 0" "$?" "0"
eq "1: keep-both kept the local edit" "$(cat "$wt"/notes.txt.local-*)" "LOCAL ONLY EDIT"
eq "1: the owner's version is in place" "$(cat "$wt/notes.txt")" "untracked"
check "1: untracked files are manifest rows" grep -q "^notes.txt	" "$SANDBOX/m2/dest.tsv"

# --- LOW: keep-both copies never ride the untracked tar ----------------------
push "$wt" "$W" "$SANDBOX/m2/source.tsv" "$SANDBOX/m3" ce
eq "LOW: next push: exit 0" "$?" "0"
check "LOW: the keep-both copy stayed on the laptop only" bash -c "! ls '$W'/notes.txt.local-* >/dev/null 2>&1"

# --- 5: the incoming bundle never lands on a shared ref ------------------------
git -C "$HOME/Developer/ce/main" worktree add -q "$HOME/Developer/ce/wt2" -b feat2
git -C "$W" commit -qam "remote commit"
pull "$W" "$wt" "$SANDBOX/m3/dest.tsv" "$SANDBOX/m4" ce
eq "5: pull with a bundle: exit 0" "$?" "0"
eq "5: no rw-incoming ref left in the shared repository" "$(git -C "$HOME/Developer/ce/main" for-each-ref refs/rw-incoming | wc -l | tr -d ' ')" "0"
eq "5: the sibling worktree's branch is untouched" "$(git -C "$HOME/Developer/ce/wt2" log -1 --format=%s)" "init"
eq "5: the pulled commit is checked out by sha" "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$W" rev-parse HEAD)"

# --- 8: a retry after an interrupted transfer converges ------------------------
echo "more" >>"$W/t.txt"
echo SECRET=2 >"$W/.env.local"
mkdir -p "$SANDBOX/badbin"
printf '#!/bin/sh\necho "rsync: connection unexpectedly closed" >&2\nexit 12\n' >"$SANDBOX/badbin/rsync"
chmod +x "$SANDBOX/badbin/rsync"
PATH="$SANDBOX/badbin:$PATH" pull "$W" "$wt" "$SANDBOX/m4/dest.tsv" "$SANDBOX/m5" ce
eq "8: interrupted pull (rsync dies after the git apply): exit 4" "$?" "4"
pull "$W" "$wt" "$SANDBOX/m4/dest.tsv" "$SANDBOX/m5" ce
eq "8: plain retry with the same stored manifest converges: exit 0" "$?" "0"
check "8: trees identical after the retry (the laptop-only keep-both copy aside)" \
  diff -r -x .git -x 'notes.txt.local-*' "$wt" "$W"

# --- 6: first handoff onto an existing, different repository -----------------
p3="$HOME/Developer/p3"
git init -q "$p3"
echo a >"$p3/a.txt"
git -C "$p3" add . && git -C "$p3" commit -qm a
W3="$FAKE_WORKER_HOME/Developer/p3"
git clone -q "$p3" "$W3"
echo "worker-only" >"$W3/b.txt"
git -C "$W3" add b.txt && git -C "$W3" commit -qm "worker unpushed"
push "$p3" "$W3" "$SANDBOX/none" "$SANDBOX/m6" p3
eq "6: existing remote repository that differs, no sync record: exit 2" "$?" "2"
check "6: says there is no record" grep -q "no record of an earlier sync" "$SANDBOX/err"
eq "6: the remote commit survives" "$(git -C "$W3" log -1 --format=%s)" "worker unpushed"
git clone -q "$p3" "$FAKE_WORKER_HOME/Developer/p3same" && git init -q "$HOME/Developer/p3same-src" 2>/dev/null
rm -rf "$HOME/Developer/p3same-src"
git clone -q "$p3" "$HOME/Developer/p3same-src"
push "$HOME/Developer/p3same-src" "$FAKE_WORKER_HOME/Developer/p3same" "$SANDBOX/none" "$SANDBOX/m6b" p3same
eq "6: an existing remote repository at the same state is fine: exit 0" "$?" "0"

# --- 10: submodules are refused before anything is touched ---------------------
sub="$SANDBOX/subsrc"
git init -q "$sub" && echo s >"$sub/s.txt" && git -C "$sub" add . && git -C "$sub" commit -qm s
r8="$HOME/Developer/sm"
git init -q "$r8" && echo top >"$r8/top.txt" && git -C "$r8" add . && git -C "$r8" commit -qm t
git -C "$r8" -c protocol.file.allow=always submodule add -q "$sub" libs/sub >/dev/null 2>&1
git -C "$r8" commit -qm sub
push "$r8" "$FAKE_WORKER_HOME/Developer/sm" "$SANDBOX/none" "$SANDBOX/m8" sm
eq "10: root with a submodule: exit 1" "$?" "1"
check "10: names the submodule" grep -q "libs/sub' is a git submodule" "$SANDBOX/err"
check "10: the worker was not touched" test ! -e "$FAKE_WORKER_HOME/Developer/sm"

# --- 11: an untracked nested repository absent on the owner ----------------------
make_worktree "$HOME/Developer/nr"
wt5="$HOME/Developer/nr/wt"
W5="$FAKE_WORKER_HOME/Developer/nr/wt"
push "$wt5" "$W5" "$SANDBOX/none" "$SANDBOX/m9" nr
mkdir -p "$W5/vendor/lib"
git init -q "$W5/vendor/lib"
echo v >"$W5/vendor/lib/v.txt"
push "$wt5" "$W5" "$SANDBOX/m9/dest.tsv" "$SANDBOX/m10" nr --force-diverged
eq "11: the nested repository is a conflict first: exit 5" "$?" "5"
push "$wt5" "$W5" "$SANDBOX/m9/dest.tsv" "$SANDBOX/m10" nr --force-diverged --resolve overwrite
eq "11: overwrite removes it cleanly: exit 0" "$?" "0"
check "11: nested repository gone (owner did not have it)" test ! -e "$W5/vendor/lib"
check "11: trees identical" trees_equal "$wt5" "$W5"

# --- 12: plain roots get a backup; an empty owner never empties the other copy --
pp="$HOME/Developer/plainx"
make_plain "$pp"
W9="$FAKE_WORKER_HOME/Developer/plainx"
"$RW_SYNC" sync --direction handoff --dest-mode ssh --dest-worker fakeworker --source-path "$pp" --dest-path "$W9" \
  --dest-manifest "$SANDBOX/none" --manifest-out "$SANDBOX/m11" --backup-root "$SANDBOX/wb" --staging-root "$SANDBOX/ws" >/dev/null 2>&1
find "$W9" -mindepth 1 -delete
pull "$W9" "$pp" "$SANDBOX/m11/source.tsv" "$SANDBOX/m12" plainx
eq "12: pull from an emptied owner: refused (exit 1)" "$?" "1"
eq "12: the laptop copy is untouched" "$(find "$pp" -type f -o -type l | wc -l | tr -d ' ')" "5"
echo "only file" >"$W9/new.txt"
pull "$W9" "$pp" "$SANDBOX/m11/source.tsv" "$SANDBOX/m12" plainx
eq "12: a mass deletion that leaves files: exit 0" "$?" "0"
bk="$(jq -r .backup_dir "$SANDBOX/out")"
eq "12: every replaced or deleted file was backed up first" "$(tar -tf "$bk/files.tar" | LC_ALL=C sort | paste -sd, -)" \
  "README,data/a.csv,data/b.csv,latest,scripts/work/run.sh"

# --- LOW: backslashes, quotes and wildcards in ignored names over ssh ------------
make_worktree "$HOME/Developer/odd dir"
wt6="$HOME/Developer/odd dir/wt"
mkdir -p "$wt6/node_modules/é ü" "$wt6/build/[x]"
echo 1 >"$wt6/node_modules/é ü/ä b.js"
echo 2 >"$wt6/build/[x]/*?.txt"
echo 3 >"$wt6/.env a\\b"
echo 4 >"$wt6/.env'q"
push "$wt6" "$FAKE_WORKER_HOME/Developer/odd dir/wt" "$SANDBOX/none" "$SANDBOX/m13" odd
eq "LOW: odd names: exit 0" "$?" "0"
check "LOW: odd names: identical trees" trees_equal "$wt6" "$FAKE_WORKER_HOME/Developer/odd dir/wt"

finish
