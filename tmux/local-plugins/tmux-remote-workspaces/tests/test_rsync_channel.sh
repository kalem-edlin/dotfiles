#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# rsync channel set selection: for a git root it carries exactly the
# gitignored set (collapsed entries, union of both sides so vanished
# entries are deleted), never tracked or untracked files or .git; for a
# plain root the whole tree minus the root's .git. Keep-both copies and
# .DS_Store are never sent nor deleted.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../libexec/sync/common.sh
source "$RW_PLUGIN/libexec/sync/common.sh"

base="$HOME/Developer/ce"
make_worktree "$base"
wt="$base/wt"
echo bracket >"$wt/.env[1]"      # wildcard characters must match literally
mkdir -p "$wt/mixed/node_modules/q"
echo keep >"$wt/mixed/plain.txt"  # untracked, NOT ignored: git channel only
echo q >"$wt/mixed/node_modules/q/q.js"

bash_script() { bash -s <"$1"; }
entries="$(rw_sync_ignored_via bash_script "$wt")"
eq "collapsed ignored entries (git status --ignored=matching)" "$(LC_ALL=C sort <<<"$entries" | paste -sd, -)" \
  ".env.local,.env[1],build/,mixed/node_modules/,node_modules/,pkgs/app/node_modules/"
check "an untracked parent of an ignored dir is not an entry" bash -c "! grep -qx 'pkgs/' <<<'$entries'"

printf '%s\n' "$entries" >"$SANDBOX/entries"
: >"$SANDBOX/protect"
rw_sync_write_rsync_rules git "$SANDBOX/entries" "$SANDBOX/protect" "$SANDBOX/rules"
eq "rules: first .DS_Store, then keep-both" "$(sed -n '1,2p' "$SANDBOX/rules" | paste -sd'|' -)" \
  "- .DS_Store|- *.local-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]"
eq "rules: everything else excluded last" "$(tail -n1 "$SANDBOX/rules")" "- *"
check "rules: ancestors of a nested entry are included" grep -qx '+ /pkgs/app/' "$SANDBOX/rules"
check "rules: collapsed dir included recursively" grep -qx '+ /pkgs/app/node_modules/\*\*' "$SANDBOX/rules"
check "rules: wildcard characters escaped" grep -qxF '+ /.env\[1\]' "$SANDBOX/rules"

# rsync with those rules into an empty dir carries exactly the ignored set.
mkdir -p "$SANDBOX/only"
rsync -rlptD --delete "--exclude-from=$SANDBOX/rules" "$wt/" "$SANDBOX/only/"
eq "channel carries exactly the ignored files" "$(cd "$SANDBOX/only" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | paste -sd, -)" \
  ".env.local,.env[1],build/out.bin,mixed/node_modules/q/q.js,node_modules/pkg/index.js,pkgs/app/node_modules/x/y.js"

# Union: an ignored entry only the destination has is deleted; tracked and
# untracked destination files are excluded and therefore untouched.
dst="$SANDBOX/dst"
mkdir -p "$dst/dist" "$dst/node_modules/stale" "$dst/.git"
echo old >"$dst/dist/bundle.js"
echo stale >"$dst/node_modules/stale/s.js"
echo mine >"$dst/t.txt"
echo mine >"$dst/notes.txt"
echo head >"$dst/.git/HEAD"
echo kept >"$dst/.env.local.local-20260101-120000"
echo finder >"$dst/.DS_Store"
printf '%s\ndist/\n' "$entries" | LC_ALL=C sort -u >"$SANDBOX/union"
rw_sync_write_rsync_rules git "$SANDBOX/union" "$SANDBOX/protect" "$SANDBOX/rules2"
rsync -rlptD --delete "--exclude-from=$SANDBOX/rules2" "$wt/" "$dst/"
check "vanished ignored entry deleted on the other side" test ! -e "$dst/dist"
check "stale file inside a carried ignored dir deleted" test ! -e "$dst/node_modules/stale"
eq "tracked file untouched by the rsync channel" "$(cat "$dst/t.txt")" "mine"
eq "untracked file untouched by the rsync channel" "$(cat "$dst/notes.txt")" "mine"
eq ".git untouched" "$(cat "$dst/.git/HEAD")" "head"
check "keep-both copy never deleted" test -e "$dst/.env.local.local-20260101-120000"
check ".DS_Store never deleted" test -e "$dst/.DS_Store"

# Plain: everything but the root's own .git.
plain="$HOME/Developer/idol-app"
make_plain "$plain"
mkdir -p "$plain/.git" "$plain/vendor/lib/.git"
echo x >"$plain/.git/HEAD"
echo nested >"$plain/vendor/lib/.git/HEAD"
rw_sync_write_rsync_rules plain /dev/null "$SANDBOX/protect" "$SANDBOX/rules3"
mkdir -p "$SANDBOX/p"
rsync -rlptD --delete "--exclude-from=$SANDBOX/rules3" "$plain/" "$SANDBOX/p/"
check "plain: the root's .git is not carried" test ! -e "$SANDBOX/p/.git"
check "plain: a nested repository travels whole" test -e "$SANDBOX/p/vendor/lib/.git/HEAD"
check "plain: symlinks travel as symlinks" test -L "$SANDBOX/p/latest"

finish
