#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Manifests (C1) and the manifest gate (C2): generation for plain and git
# roots, diff kinds, conflict exit 5, --resolve keep-both / overwrite /
# abort.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../libexec/sync/common.sh
source "$RW_PLUGIN/libexec/sync/common.sh"

plain="$HOME/Developer/idol-app"
make_plain "$plain"
touch -t 202601020304.05 "$plain/README"
mkdir -p "$plain/.git" && echo junk >"$plain/.git/HEAD" # a stray .git is never carried
echo finder >"$plain/data/.DS_Store"
echo keep >"$plain/data/a.csv.local-20260101-120000"

m="$(rw_sync_manifest_local "$plain" plain)"
eq "plain manifest: every file and symlink, sorted, no .git/.DS_Store/keep-both" \
  "$(cut -f1 <<<"$m" | paste -sd, -)" "README,data/a.csv,data/b.csv,latest,scripts/work/run.sh"
eq "manifest row: size and mtime" "$(grep '^README' <<<"$m")" \
  "$(printf 'README\t5\t%s' "$(date -j -f '%Y%m%d%H%M.%S' 202601020304.05 +%s 2>/dev/null || date -d '2026-01-02 03:04:05' +%s)")"
eq "symlinks record mtime 0" "$(grep '^latest' <<<"$m" | cut -f3)" "0"
eq "missing path: empty manifest" "$(rw_sync_manifest_local "$SANDBOX/nope" plain)" ""

make_worktree "$HOME/Developer/ce"
g="$(rw_sync_manifest_local "$HOME/Developer/ce/wt" git)"
eq "git manifest: gitignored files (collapsed dirs expanded) plus untracked files" \
  "$(cut -f1 <<<"$g" | paste -sd, -)" ".env.local,build/out.bin,node_modules/pkg/index.js,notes.txt,pkgs/app/node_modules/x/y.js"

# --- diff ---------------------------------------------------------------
printf 'a\t1\t10\nb\t2\t20\nc\t3\t30\n#git\tX\n' >"$SANDBOX/stored.tsv"
printf 'a\t1\t10\nb\t2\t21\nd\t4\t40\n#git\tY\n' >"$SANDBOX/current.tsv"
eq "diff: changed, deleted, added; # rows ignored" "$(rw_sync_manifest_diff "$SANDBOX/stored.tsv" "$SANDBOX/current.tsv")" \
  "$(printf 'conflict\tb\tchanged\nconflict\tc\tdeleted\nconflict\td\tadded')"
eq "diff --no-deleted drops deletions" "$(rw_sync_manifest_diff "$SANDBOX/stored.tsv" "$SANDBOX/current.tsv" --no-deleted | cut -f2 | paste -sd, -)" "b,d"
check "identical manifests compare equal" rw_sync_manifests_equal "$SANDBOX/stored.tsv" "$SANDBOX/stored.tsv"
eq "#git row lookup" "$(rw_sync_manifest_git_fp "$SANDBOX/current.tsv")" "Y"

# --- the gate, end to end through the sync core -------------------------
src="$HOME/Developer/gate"
dst="$FAKE_WORKER_HOME/Developer/gate"
make_plain "$src"
sync() { "$RW_SYNC" sync --dest-mode local --source-path "$src" --dest-path "$dst" "$@"; }

sync --direction handoff --dest-manifest "$SANDBOX/none.tsv" --manifest-out "$SANDBOX/m1" >/dev/null 2>&1
eq "first handoff into an empty destination: no conflicts" "$?" "0"
cp "$SANDBOX/m1/dest.tsv" "$SANDBOX/stored-dest.tsv"

sleep 1
echo edited-remotely >"$dst/data/a.csv"
echo new >"$dst/new.txt"
rm "$dst/data/b.csv"
echo newer >"$src/data/a.csv"

out="$(sync --direction handoff --dest-manifest "$SANDBOX/stored-dest.tsv" 2>/dev/null)"
eq "changed copy: exit 5" "$?" "5"
eq "exit 5 lists one line per file" "$out" \
  "$(printf 'conflict\tdata/a.csv\tchanged\nconflict\tdata/b.csv\tdeleted\nconflict\tnew.txt\tadded')"
eq "exit 5 touched nothing" "$(cat "$dst/data/a.csv")" "edited-remotely"

sync --direction handoff --dest-manifest "$SANDBOX/stored-dest.tsv" --resolve abort >/dev/null 2>&1
eq "--resolve abort: still exit 5" "$?" "5"

res="$(sync --direction handoff --dest-manifest "$SANDBOX/stored-dest.tsv" --resolve keep-both 2>/dev/null)"
eq "--resolve keep-both: exit 0" "$?" "0"
kept="$(jq -r '.renamed[]' <<<"$res" | sort | paste -sd, -)"
check "keep-both renamed exactly the changed and added files" bash -c "[[ '$kept' =~ ^data/a\.csv\.local-[0-9]{8}-[0-9]{6},new\.txt\.local-[0-9]{8}-[0-9]{6}$ ]]"
eq "keep-both: the losing copy survives" "$(cat "$dst"/data/a.csv.local-*)" "edited-remotely"
eq "keep-both: the owner's version wins" "$(cat "$dst/data/a.csv")" "newer"
eq "keep-both: the deleted file is restored" "$(cat "$dst/data/b.csv")" "2"
check "keep-both copies are not in the manifest" bash -c "! grep -q local- '$SANDBOX/m1/dest.tsv'"

sleep 1
echo again >"$dst/README"
sync --direction handoff --dest-manifest "$SANDBOX/stored-dest.tsv" --resolve overwrite >/dev/null 2>&1
eq "--resolve overwrite: exit 0" "$?" "0"
eq "overwrite: the owner's version wins" "$(cat "$dst/README")" "note"

# No stored manifest but an existing destination: only files that would
# really be replaced or deleted conflict.
rm -rf "$dst"
mkdir -p "$dst/data"
cp -p "$src/data/b.csv" "$dst/data/b.csv"
echo stale >"$dst/data/a.csv"
echo extra >"$dst/extra"
out="$(sync --direction handoff --dest-manifest "$SANDBOX/none.tsv" 2>/dev/null)"
eq "no stored manifest: baseline is the source" "$out" \
  "$(printf 'conflict\tdata/a.csv\tchanged\nconflict\textra\tadded')"

finish
