#!/usr/bin/env bash
# Drives git/.local/bin/wt against a throwaway repo (fake origin, main checkout
# named `main` under a temp project folder, fake env values only) and asserts
# exit codes, JSON fields and files on disk. Never touches a real repo or tmux.

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$(cd "$TEST_DIR/.." && pwd)/git/.local/bin/wt"

for dep in git jq python3; do
  command -v "$dep" >/dev/null 2>&1 || {
    printf 'missing test dependency: %s\n' "$dep" >&2
    exit 1
  }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")" || exit 1
scratch="$(cd "$scratch" && pwd -P)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

# wt rm of a main checkout moves it to ~/.Trash: HOME is a temp dir, so the
# real Trash is never touched.
real_home=${HOME:-}
export HOME="$scratch/home"
mkdir -p "$HOME"
[ "$HOME" != "$real_home" ] || { echo "ABORT: HOME not isolated" >&2; exit 2; }

# Isolate git from the user's config (signing, hooks, templates).
export GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name 'wt test'
git config --file "$GIT_CONFIG_GLOBAL" user.email 'wt-test@example.invalid'
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false
# Listeners on this machine must not move the allocator's answer.
export WT_PORT_PROBE=0
# rw's ownership records (wt rm, D11) live in a scratch state dir.
export TMUX_REMOTE_WORKSPACES_STATE_DIR="$scratch/rw-state"
unset XDG_STATE_HOME
unset GIT_DIR GIT_WORK_TREE

pass=0
fail=0
out="" err="" rc=0

ok() { pass=$((pass + 1)); }
not_ok() {
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$1" >&2
  [ $# -lt 2 ] || printf '  expected: %s\n  actual:   %s\n' "$2" "$3" >&2
}

# wt ARGS...: run the script, capture stdout, stderr and exit status.
wt() {
  out="$("$BASH" "$WT" "$@" 2>"$scratch/stderr")"
  rc=$?
  err="$(cat "$scratch/stderr")"
}

check_eq() { if [ "$2" = "$3" ]; then ok; else not_ok "$1" "$2" "$3"; fi; }
check_rc() { check_eq "$1: exit code (stderr: $err)" "$2" "$rc"; }
check_true() { if eval "$2"; then ok; else not_ok "$1"; fi; }
# field FILTER: jq over the last stdout, which must be one JSON object.
field() { printf '%s' "$out" | jq -rc "$1" 2>/dev/null || printf '<invalid json>'; }
check_json() {
  if printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 &&
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; then ok; else not_ok "$1: one JSON object on stdout" "object" "$out"; fi
}
envval() { sed -n "s/^$2=//p" "$1"; }

# --- fixture ------------------------------------------------------------------

PROJECT="$scratch/project"
MAIN="$PROJECT/main"
mkdir -p "$PROJECT"
git init -q --bare "$scratch/origin.git"
git clone -q "$scratch/origin.git" "$MAIN" 2>/dev/null
(
  cd "$MAIN" || exit 1
  cat >.gitignore <<'EOF'
.env*.local
.env.production
.env.branch
.env.ports
*.generated
apps/expo/ios/Pods/
apps/expo/ios/build/
packages/native-tools/ios/Models/
EOF
  mkdir -p apps/expo/ios
  echo readme >README.md
  echo 'lockfileVersion: 1' >pnpm-lock.yaml
  echo 'export default {}' >apps/expo/app.config.ts
  echo "platform :ios" >apps/expo/ios/Podfile
  echo 'EXAMPLE_KEY=example' >.env.example
  git add -A && git commit -q -m init && git push -q origin main
  git switch -q -c feature/deps
  echo 'lockfileVersion: 2' >pnpm-lock.yaml
  echo "platform :ios, '16'" >apps/expo/ios/Podfile
  git commit -q -am deps && git push -q origin feature/deps
  git switch -q main && git branch -q -D feature/deps
  git branch -q existing-b origin/main
) || exit 1

# Fake values only: the 13 port-bearing keys of content-engine's .env.local.
cat >"$MAIN/.env.local" <<'EOF'
# fake values for wt-test
NEXT_PORT=3000
DASHBOARD_PORT="3010"
ENGINE_PORT='7500'
EXPO_PORT=8081
DEEP_LINK_BASE_URL=http://localhost:3000/link
ENGINE_URL=http://localhost:7500
EXPO_PUBLIC_DEEP_LINK_BASE_URL="http://localhost:3000/link"
EXPO_PUBLIC_ENGINE_URL="http://localhost:7500"
EXPO_PUBLIC_SERVER_ORIGIN=http://localhost:3000
SERVER_ORIGIN=http://localhost:3000
VITE_DEEP_LINK_BASE_URL=http://localhost:3000/link
VITE_ENGINE_URL=http://localhost:7500
VITE_SERVER_ORIGIN=http://localhost:3010
FAKE_SECRET=fake-secret:3000
EOF
chmod 600 "$MAIN/.env.local"
echo 'FAKE_PROD=fake' >"$MAIN/.env.production"
echo 'BRANCH_DB=fake-branch' >"$MAIN/.env.branch"
echo 'GEN=fake' >"$MAIN/.env.test.generated"
cat >"$MAIN/.env.ports" <<'EOF'
# block 0
NEXT_PORT=3000
DASHBOARD_PORT=3010
ENGINE_PORT=7500
EXPO_PORT=8081
EOF
cp "$MAIN/.env.local" "$scratch/env.local.orig"

# --- usage --------------------------------------------------------------------

wt
check_rc "no command" 2
wt bogus "$MAIN" --json
check_rc "unknown command" 2
check_json "unknown command"
wt new "$MAIN"
check_rc "new without --branch" 2
wt new "$MAIN" --branch 'bad..name'
check_rc "new with invalid branch" 2
wt new "$MAIN" --branch ok --name 'has space'
check_rc "new with invalid name" 2
wt status "$scratch/nope"
check_rc "status of a missing dir" 1

# --- ports and new ------------------------------------------------------------

wt ports "$MAIN" --json
check_rc "ports" 0
check_json "ports"
check_eq "ports: next block after main's 0" 1 "$(field .block)"
check_eq "ports: NEXT_PORT of block 1" 3100 "$(field .ports.NEXT_PORT)"
check_eq "ports: used" '[0]' "$(field .used)"
wt ports "$MAIN"
check_eq "ports human line" "next free block 1: NEXT_PORT=3100 DASHBOARD_PORT=3110 ENGINE_PORT=7600 EXPO_PORT=8181" "$out"
check_true "ports writes nothing" "[ ! -e '$PROJECT/feat-one' ] && [ \"\$(ls '$PROJECT')\" = main ]"

wt new "$MAIN" --branch feat/one --json
check_rc "new feat/one" 0
check_json "new feat/one"
ONE="$PROJECT/feat-one"
check_eq "new: path is a sibling of main named after the branch" "$ONE" "$(field .path)"
check_eq "new: first block" 1 "$(field .ports_block)"
check_eq "new: needs_install" true "$(field .needs_install)"
check_eq "new: created_branch" true "$(field .created_branch)"
check_eq "new: from defaults to origin/main" origin/main "$(field .from)"
check_eq "new: env files copied" '[".env.local",".env.production"]' "$(field '.env_copied | sort')"
check_eq "new: 13 port keys rewritten" 13 "$(field '.env_rewritten | length')"
check_eq "new: branch checked out" feat/one "$(git -C "$ONE" symbolic-ref --short HEAD)"
check_eq "new: no upstream tracking" "" "$(git -C "$ONE" config --get branch.feat/one.merge)"
check_true "new: .env.local is a real file" "[ -f '$ONE/.env.local' ] && [ ! -L '$ONE/.env.local' ]"
check_true "new: .env.production is a real file" "[ -f '$ONE/.env.production' ] && [ ! -L '$ONE/.env.production' ]"
check_true "new: .env.branch not copied" "[ ! -e '$ONE/.env.branch' ]"
check_true "new: *.generated not copied" "[ ! -e '$ONE/.env.test.generated' ]"
check_eq "new: .env.local mode kept" 600 "$(stat -f %Lp "$ONE/.env.local" 2>/dev/null || stat -c %a "$ONE/.env.local")"
check_eq "new: .env.ports NEXT_PORT" 3100 "$(envval "$ONE/.env.ports" NEXT_PORT)"
check_eq "new: .env.ports EXPO_PORT" 8181 "$(envval "$ONE/.env.ports" EXPO_PORT)"
check_true "new: .env.ports has a comment header" "head -n 1 '$ONE/.env.ports' | grep -q '^# Generated by wt new'"
check_eq "rewrite: bare NEXT_PORT" 3100 "$(envval "$ONE/.env.local" NEXT_PORT)"
check_eq "rewrite: double-quoted DASHBOARD_PORT" '"3110"' "$(envval "$ONE/.env.local" DASHBOARD_PORT)"
check_eq "rewrite: single-quoted ENGINE_PORT" "'7600'" "$(envval "$ONE/.env.local" ENGINE_PORT)"
check_eq "rewrite: EXPO_PORT" 8181 "$(envval "$ONE/.env.local" EXPO_PORT)"
check_eq "rewrite: SERVER_ORIGIN" http://localhost:3100 "$(envval "$ONE/.env.local" SERVER_ORIGIN)"
check_eq "rewrite: ENGINE_URL" http://localhost:7600 "$(envval "$ONE/.env.local" ENGINE_URL)"
check_eq "rewrite: quoted EXPO_PUBLIC_ENGINE_URL" '"http://localhost:7600"' "$(envval "$ONE/.env.local" EXPO_PUBLIC_ENGINE_URL)"
check_eq "rewrite: DEEP_LINK_BASE_URL path kept" http://localhost:3100/link "$(envval "$ONE/.env.local" DEEP_LINK_BASE_URL)"
check_eq "rewrite: VITE_SERVER_ORIGIN dashboard" http://localhost:3110 "$(envval "$ONE/.env.local" VITE_SERVER_ORIGIN)"
check_eq "rewrite: non-port key untouched" fake-secret:3000 "$(envval "$ONE/.env.local" FAKE_SECRET)"
check_eq "rewrite: comment untouched" '# fake values for wt-test' "$(head -n 1 "$ONE/.env.local")"
check_true "rewrite: main .env.local unchanged" "cmp -s '$scratch/env.local.orig' '$MAIN/.env.local'"
check_eq "new: lfs.fetchexclude in the worktree config" 'packages/native-tools/ios/Models/**' \
  "$(git -C "$ONE" config --worktree --get lfs.fetchexclude)"
check_eq "new: lfs.fetchexclude not in main" "" "$(git -C "$MAIN" config --get lfs.fetchexclude)"
check_eq "new: extensions.worktreeConfig enabled" true "$(git -C "$MAIN" config --get extensions.worktreeConfig)"

wt new "$MAIN" --branch feat/two
check_rc "new feat/two (human)" 0
TWO="$PROJECT/feat-two"
check_true "new human line" "printf '%s' \"\$out\" | grep -q '^created $TWO on feat/two .* block 2'"
check_eq "new: second block" 2 "$(envval "$TWO/.env.ports" NEXT_PORT | sed 's/^3200$/2/')"
check_eq "new: second block rewrite" http://localhost:3200 "$(envval "$TWO/.env.local" SERVER_ORIGIN)"

wt new "$MAIN" --branch feat/other --name feat-one --json
check_rc "new into an existing directory" 5
check_json "new refusal"
check_eq "new refusal: ok false" false "$(field .ok)"
wt new "$MAIN" --branch feat/one --name elsewhere
check_rc "new with a branch checked out elsewhere" 5
wt new "$MAIN" --branch existing-b --from origin/main
check_rc "new with existing branch and --from" 2
wt new "$MAIN" --branch existing-b --json
check_rc "new on an existing branch" 0
check_eq "new existing: created_branch false" false "$(field .created_branch)"
check_eq "new existing: block 3" 3 "$(field .ports_block)"
EXB="$PROJECT/existing-b"

# Symlinked source .env.local: refuse before creating anything.
mv "$MAIN/.env.local" "$scratch/env.local.real"
ln -s "$scratch/env.local.real" "$MAIN/.env.local"
wt new "$MAIN" --branch feat/link --json
check_rc "new refuses a symlinked source .env.local" 5
check_true "symlink refusal created no directory" "[ ! -e '$PROJECT/feat-link' ]"
check_true "symlink refusal created no branch" "! git -C '$MAIN' show-ref -q --verify refs/heads/feat/link"
rm "$MAIN/.env.local"
mv "$scratch/env.local.real" "$MAIN/.env.local"

# --- status -------------------------------------------------------------------

echo changed >>"$TWO/README.md"
echo new >"$TWO/untracked.txt"
mkdir -p "$TWO/apps/expo/ios/Pods/Fake" "$TWO/packages/native-tools/ios/Models/Fake.mlmodelc"
head -c 2048 /dev/zero >"$TWO/packages/native-tools/ios/Models/Fake.mlmodelc/weights"
head -c 130 /dev/zero >"$TWO/packages/native-tools/ios/Models/pointer"
wt status "$TWO" --json
check_rc "status" 0
check_json "status"
check_eq "status: path" "$TWO" "$(field .path)"
check_eq "status: main" false "$(field .main)"
check_eq "status: branch" feat/two "$(field .branch)"
check_eq "status: head" "$(git -C "$TWO" rev-parse --short HEAD)" "$(field .head)"
check_eq "status: dirty" 1 "$(field .dirty)"
check_eq "status: untracked" 1 "$(field .untracked)"
check_eq "status: no upstream" null "$(field .upstream)"
check_eq "status: ahead null without upstream" null "$(field .ahead)"
check_eq "status: merged" true "$(field .merged)"
check_eq "status: locked" false "$(field .locked)"
check_eq "status: heavy" '["ios","lfs"]' "$(field .heavy)"
check_eq "status: ports_block" 2 "$(field .ports_block)"
wt status "$TWO/apps/expo"
check_true "status human line from a subdirectory" "printf '%s' \"\$out\" | grep -q '^$TWO feat/two .* dirty=1 untracked=1 .*heavy=ios,lfs ports=2'"

mkdir -p "$ONE/packages/native-tools/ios/Models"
head -c 130 /dev/zero >"$ONE/packages/native-tools/ios/Models/pointer"
git -C "$MAIN" worktree lock --reason 'heavy keep' "$ONE"
git -C "$ONE" branch -q --set-upstream-to=origin/main
echo one >"$ONE/one.txt"
git -C "$ONE" add one.txt && git -C "$ONE" commit -q -m one
wt status "$ONE" --json
check_eq "status: pointer-only models are not lfs" '[]' "$(field .heavy)"
check_eq "status: locked" true "$(field .locked)"
check_eq "status: lock reason" 'heavy keep' "$(field .lock_reason)"
check_eq "status: upstream" origin/main "$(field .upstream)"
check_eq "status: ahead" 1 "$(field .ahead)"
check_eq "status: behind" 0 "$(field .behind)"
check_eq "status: unmerged commit" false "$(field .merged)"
check_eq "status: clean dirty" 0 "$(field .dirty)"
wt status "$MAIN" --json
check_eq "status: main flag" true "$(field .main)"
check_eq "status: main ports_block" 0 "$(field .ports_block)"

# --- env-refresh --------------------------------------------------------------

# Main's renders change (a fresh pull); every worktree takes them, each
# keeping its own ports and mode. .env.branch and generated files never travel.
sed -i.bak 's/^FAKE_SECRET=.*/FAKE_SECRET=rotated:3000/' "$MAIN/.env.local" && rm -f "$MAIN/.env.local.bak"
echo 'ADDED_KEY=added' >>"$MAIN/.env.local"
echo 'FAKE_PROD=fake-2' >"$MAIN/.env.production"
echo 'BRANCH_DB=fake-branch-2' >"$MAIN/.env.branch"
cp "$MAIN/.env.local" "$scratch/env.local.v2"
wt env-refresh "$ONE" --json
check_rc "env-refresh" 0
check_json "env-refresh"
check_eq "env-refresh: pulled false without wt.envPull" false "$(field .pulled)"
check_eq "env-refresh: files" '[".env.local",".env.production"]' "$(field '.files | sort')"
check_eq "env-refresh: refreshed 3" 3 "$(field .refreshed)"
check_eq "env-refresh: missing none" '[]' "$(field .missing)"
check_eq "env-refresh: ONE block" 1 "$(field ".worktrees[] | select(.path == \"$ONE\") | .ports_block")"
check_eq "env-refresh: ONE 13 port keys rewritten" 13 "$(field ".worktrees[] | select(.path == \"$ONE\") | .rewritten | length")"
check_eq "env-refresh: ONE FAKE_SECRET rotated, non-port value kept" rotated:3000 "$(envval "$ONE/.env.local" FAKE_SECRET)"
check_eq "env-refresh: ONE new key" added "$(envval "$ONE/.env.local" ADDED_KEY)"
check_eq "env-refresh: ONE SERVER_ORIGIN keeps block 1" http://localhost:3100 "$(envval "$ONE/.env.local" SERVER_ORIGIN)"
check_eq "env-refresh: ONE NEXT_PORT keeps block 1" 3100 "$(envval "$ONE/.env.local" NEXT_PORT)"
check_eq "env-refresh: EXB SERVER_ORIGIN keeps block 3" http://localhost:3300 "$(envval "$EXB/.env.local" SERVER_ORIGIN)"
check_eq "env-refresh: ONE .env.production" fake-2 "$(envval "$ONE/.env.production" FAKE_PROD)"
check_eq "env-refresh: ONE .env.ports untouched" 3100 "$(envval "$ONE/.env.ports" NEXT_PORT)"
check_true "env-refresh: .env.branch still not copied" "[ ! -e '$ONE/.env.branch' ]"
check_eq "env-refresh: ONE .env.local mode kept" 600 "$(stat -f %Lp "$ONE/.env.local" 2>/dev/null || stat -c %a "$ONE/.env.local")"
check_true "env-refresh: ONE .env.local is a real file" "[ -f '$ONE/.env.local' ] && [ ! -L '$ONE/.env.local' ]"
check_eq "env-refresh: no temp files left" "" "$(ls -A "$ONE" "$TWO" "$EXB" | grep '^\.wt-env' || true)"
check_true "env-refresh: main .env.local unchanged" "cmp -s '$scratch/env.local.v2' '$MAIN/.env.local'"

# A symlinked target is left alone and reported; the other files still land.
rm "$TWO/.env.production"
echo linked >"$scratch/prod.link"
ln -s "$scratch/prod.link" "$TWO/.env.production"
echo 'FAKE_PROD=fake-3' >"$MAIN/.env.production"
wt env-refresh "$MAIN" --json
check_rc "env-refresh from the main root" 0
check_eq "env-refresh: TWO symlink skipped" '[".env.production"]' "$(field ".worktrees[] | select(.path == \"$TWO\") | .skipped")"
check_true "env-refresh: TWO symlink left alone" "[ -L '$TWO/.env.production' ] && [ \"\$(cat '$scratch/prod.link')\" = linked ]"
check_eq "env-refresh: TWO .env.local still copied" added "$(envval "$TWO/.env.local" ADDED_KEY)"
check_eq "env-refresh: ONE takes fake-3" fake-3 "$(envval "$ONE/.env.production" FAKE_PROD)"
wt env-refresh "$ONE"
check_rc "env-refresh (human)" 0
check_true "env-refresh human lines" "printf '%s' \"\$out\" | grep -q '^refreshed 3 worktree(s) from $MAIN: .env.local .env.production\$' && printf '%s' \"\$out\" | grep -q '^  $TWO: symlinks left alone: \\[\".env.production\"\\]\$'"
rm "$TWO/.env.production"
cp "$MAIN/.env.production" "$TWO/.env.production"

# wt.envPull in the main checkout runs there before the copy; --no-pull skips
# it; a failing pull stops everything with its exit code and last line.
git -C "$MAIN" config wt.envPull 'printf "PULLED=%s\n" "$PWD" >>.env.production'
wt env-refresh "$ONE" --json
check_rc "env-refresh with wt.envPull" 0
check_eq "env-refresh: pulled true" true "$(field .pulled)"
check_eq "env-refresh: pull ran in main" "$MAIN" "$(envval "$MAIN/.env.production" PULLED)"
check_eq "env-refresh: pulled value reached ONE" "$MAIN" "$(envval "$ONE/.env.production" PULLED)"
check_true "env-refresh human says pulled" "wt env-refresh '$ONE' && printf '%s' \"\$out\" | grep -q '^pulled env in $MAIN\$'"
wt env-refresh "$ONE" --no-pull --json
check_rc "env-refresh --no-pull" 0
check_eq "env-refresh --no-pull: pulled false" false "$(field .pulled)"
check_eq "env-refresh --no-pull: the pull did not run again" 2 "$(grep -c '^PULLED=' "$MAIN/.env.production")"
git -C "$MAIN" config wt.envPull 'echo nope >&2; exit 7'
echo 'FAKE_PROD=fake-4' >"$MAIN/.env.production"
wt env-refresh "$ONE" --json
check_rc "env-refresh with a failing pull" 1
check_eq "failing pull: ok false" false "$(field .ok)"
check_true "failing pull: error carries the exit code and last line" "printf '%s' \"\$(field .error)\" | grep -q 'env pull failed in $MAIN (exit 7): nope\$'"
check_true "failing pull: nothing copied" "[ \"\$(envval '$ONE/.env.production' FAKE_PROD)\" = fake-3 ]"
git -C "$MAIN" config --unset wt.envPull
wt env-refresh "$ONE" --pull
check_rc "env-refresh rejects an unknown option" 2

# --here: the given worktree is the source, copied as it is to every other
# worktree, main included, each keeping its own ports; nothing is pulled
# even with wt.envPull set.
git -C "$MAIN" config wt.envPull 'echo nope >&2; exit 7'
echo 'HERE_KEY=from-one' >>"$ONE/.env.local"
cp "$ONE/.env.local" "$scratch/env.local.one"
wt env-refresh "$ONE" --here --json
check_rc "env-refresh --here" 0
check_eq "--here: source is the worktree" "$ONE" "$(field .source)"
check_eq "--here: never pulls" false "$(field .pulled)"
check_eq "--here: refreshed 3 (main included)" 3 "$(field .refreshed)"
check_true "--here: main is a target" "printf '%s' \"\$(field '.worktrees[].path')\" | grep -qx '$MAIN'"
check_eq "--here: TWO takes ONE's key" from-one "$(envval "$TWO/.env.local" HERE_KEY)"
check_eq "--here: TWO keeps block 2" http://localhost:3200 "$(envval "$TWO/.env.local" SERVER_ORIGIN)"
check_eq "--here: TWO NEXT_PORT block 2" 3200 "$(envval "$TWO/.env.local" NEXT_PORT)"
check_eq "--here: TWO ENGINE_URL block 2" http://localhost:7700 "$(envval "$TWO/.env.local" ENGINE_URL)"
check_eq "--here: EXB keeps block 3" http://localhost:3300 "$(envval "$EXB/.env.local" SERVER_ORIGIN)"
check_eq "--here: main takes ONE's key" from-one "$(envval "$MAIN/.env.local" HERE_KEY)"
check_eq "--here: main back to block 0" http://localhost:3000 "$(envval "$MAIN/.env.local" SERVER_ORIGIN)"
check_eq "--here: main NEXT_PORT block 0" 3000 "$(envval "$MAIN/.env.local" NEXT_PORT)"
check_eq "--here: main VITE_SERVER_ORIGIN dashboard block 0" http://localhost:3010 "$(envval "$MAIN/.env.local" VITE_SERVER_ORIGIN)"
check_eq "--here: main .env.production from ONE" fake-3 "$(envval "$MAIN/.env.production" FAKE_PROD)"
check_true "--here: the source is untouched" "cmp -s '$scratch/env.local.one' '$ONE/.env.local'"
check_eq "--here: 13 port keys rewritten for main" 13 "$(field ".worktrees[] | select(.path == \"$MAIN\") | .rewritten | length")"
git -C "$MAIN" config --unset wt.envPull

# A registered worktree whose directory is gone is reported, not written.
wt new "$MAIN" --branch feat/gone --json
check_rc "new feat/gone for the missing case" 0
GONE="$PROJECT/feat-gone"
rm -rf "$GONE"
wt env-refresh "$ONE" --json
check_rc "env-refresh with a missing worktree" 0
check_eq "env-refresh: missing lists it" "[\"$GONE\"]" "$(field .missing)"
check_eq "env-refresh: refreshed 3 without it" 3 "$(field .refreshed)"
wt rm "$GONE" --json
check_rc "prune feat/gone after the missing case" 0
echo 'FAKE_PROD=fake' >"$MAIN/.env.production"

# --- rm -----------------------------------------------------------------------

wt rm "$MAIN" --json
check_rc "rm refuses main with linked worktrees" 5
check_json "rm main refusal"
check_eq "rm main refusal: the linked count" "main checkout has 3 linked worktrees: remove them first" "$(field .error)"
wt rm "$MAIN" --force
check_rc "rm refuses main with linked worktrees even with --force" 5
check_true "rm main refusal moved nothing" "[ -d '$MAIN/.git' ] && [ ! -e '$HOME/.Trash' ]"
wt status "$MAIN" --json
check_eq "status: main counts its linked worktrees" 3 "$(field .linked)"
wt status "$TWO" --json
check_eq "status: linked is null off main" null "$(field .linked)"
wt rm "$ONE"
check_rc "rm refuses locked" 4
stashes_before=$(git -C "$MAIN" stash list | wc -l | tr -d ' ')
wt rm "$TWO" --json
check_rc "rm of a dirty worktree, no --force (D105)" 0
check_json "rm"
TRASHED_TWO="$HOME/.Trash/feat-two"
check_eq "rm: main false" false "$(field .main)"
check_eq "rm: removed" "$TWO" "$(field .removed)"
check_eq "rm: trashed_to" "$TRASHED_TWO" "$(field .trashed_to)"
check_eq "rm: branch reported" feat/two "$(field .branch)"
check_eq "rm: no stash field" null "$(field .stash)"
check_true "rm: directory gone" "[ ! -e '$TWO' ]"
check_true "rm: branch kept" "git -C '$MAIN' show-ref -q --verify refs/heads/feat/two"
check_true "rm: the untracked file rides along in the Trash" "[ -f '$TRASHED_TWO/untracked.txt' ]"
check_true "rm: tracked files ride along" "[ -f '$TRASHED_TWO/README.md' ]"
check_eq "rm: no stash made" "$stashes_before" "$(git -C "$MAIN" stash list | wc -l | tr -d ' ')"
check_true "rm: worktree unregistered" "! git -C '$MAIN' worktree list --porcelain | grep -q 'feat-two'"
check_true "rm: admin dir pruned" "[ ! -e '$MAIN/.git/worktrees/feat-two' ]"
wt ports "$MAIN" --json
check_eq "ports: freed block 2 is reused" 2 "$(field .block)"
wt rm "$ONE" --force
check_rc "rm --force locked clean" 0
check_eq "rm human line" "moved $ONE to $HOME/.Trash/feat-one (branch feat/one kept)" "$out"
check_true "rm locked: directory gone" "[ ! -e '$ONE' ]"
check_true "rm locked: in the Trash" "[ -d '$HOME/.Trash/feat-one' ]"
check_true "rm locked: unregistered" "! git -C '$MAIN' worktree list --porcelain | grep -q 'feat-one'"
check_true "rm locked: branch kept" "git -C '$MAIN' show-ref -q --verify refs/heads/feat/one"
wt ports "$MAIN"
check_true "ports: lowest free block 1 after removals" "printf '%s' \"\$out\" | grep -q '^next free block 1:'"

# --- repurpose ----------------------------------------------------------------

wt new "$MAIN" --branch feat/three --json
THREE="$PROJECT/feat-three"
check_eq "new reuses block 1" 1 "$(field .ports_block)"
cp "$THREE/.env.ports" "$scratch/three.ports"
echo 'BRANCH_DB=fake-three' >"$THREE/.env.branch"
echo dirt >>"$THREE/README.md"
echo new >"$THREE/scratch.txt"
wt repurpose "$THREE" --branch feat/four
check_rc "repurpose refuses dirty" 3
check_eq "repurpose dirty refusal kept the branch" feat/three "$(git -C "$THREE" symbolic-ref --short HEAD)"
wt repurpose "$THREE" --branch main --stash
check_rc "repurpose refuses a branch checked out elsewhere" 5
check_true "refusal ran before stashing" "[ -f '$THREE/scratch.txt' ]"
wt repurpose "$THREE" --branch feat/three
check_rc "repurpose onto the current branch" 5
wt repurpose "$THREE" --branch existing-b --from origin/main --stash
check_rc "repurpose existing branch with --from" 2
wt repurpose "$THREE" --branch feat/four --stash --json
check_rc "repurpose --stash" 0
check_json "repurpose"
check_eq "repurpose: branch" feat/four "$(git -C "$THREE" symbolic-ref --short HEAD)"
check_eq "repurpose: previous_branch" feat/three "$(field .previous_branch)"
check_eq "repurpose: stashed" true "$(field .stashed)"
check_eq "repurpose: stashed_changes (1 changed, 1 untracked)" 2 "$(field .stashed_changes)"
check_true "repurpose: stash tagged" "git -C '$MAIN' stash list | grep -q 'wt repurpose feat-three '"
check_true "repurpose: .env.ports kept" "cmp -s '$scratch/three.ports' '$THREE/.env.ports'"
check_true "repurpose: .env.branch removed" "[ ! -e '$THREE/.env.branch' ]"
check_true "repurpose: .env.local kept" "[ -f '$THREE/.env.local' ]"
check_eq "repurpose: ports_block" 1 "$(field .ports_block)"
check_eq "repurpose: same base needs no install" false "$(field .needs_install)"
check_eq "repurpose: same base needs no pods" false "$(field .needs_pods)"
check_eq "repurpose: path unchanged" "$THREE" "$(field .path)"
wt repurpose "$THREE" --branch feat/five --from origin/feature/deps --json
check_rc "repurpose onto a lockfile change" 0
check_eq "repurpose: lockfile change needs install" true "$(field .needs_install)"
check_eq "repurpose: Podfile change needs pods" true "$(field .needs_pods)"
check_eq "repurpose: from" origin/feature/deps "$(field .from)"
wt repurpose "$EXB" --branch feat/four
check_rc "repurpose to an existing free branch (human)" 0
check_eq "repurpose existing: switched" feat/four "$(git -C "$EXB" symbolic-ref --short HEAD)"
check_true "repurpose human line" "printf '%s' \"\$out\" | grep -q '^repurposed $EXB: existing-b -> feat/four'"

# --- rm of a missing worktree (prune) ------------------------------------------

rm -rf "$EXB"
wt status "$MAIN" --json
check_eq "status: a prunable worktree still counts as linked" 2 "$(field .linked)"
wt rm "$EXB" --json
check_rc "rm of a missing worktree prunes it" 0
check_json "rm missing"
check_eq "rm missing: pruned path" "$EXB" "$(field .pruned)"
check_eq "rm missing: branch reported" feat/four "$(field .branch)"
check_true "rm missing: registration gone" "! git -C '$MAIN' worktree list --porcelain | grep -q 'existing-b'"
check_true "rm missing: branch kept" "git -C '$MAIN' show-ref -q --verify refs/heads/feat/four"
wt new "$MAIN" --branch feat/gone --json
GONE="$PROJECT/feat-gone"
git -C "$MAIN" worktree lock --reason 'keep me' "$GONE"
rm -rf "$GONE"
wt rm "$GONE" --json
check_rc "rm of a missing locked worktree" 4
check_true "rm missing locked: still registered" "git -C '$MAIN' worktree list --porcelain | grep -q 'feat-gone'"
wt rm "$GONE/" --force
check_rc "rm --force of a missing locked worktree (human, trailing slash)" 0
check_eq "rm missing human line" "pruned $GONE (its directory was already gone), branch feat/gone kept" "$out"
check_true "rm missing locked: registration gone" "! git -C '$MAIN' worktree list --porcelain | grep -q 'feat-gone'"
wt rm "$PROJECT/never-registered" --json
check_rc "rm of an unregistered missing path" 1
check_eq "rm unregistered missing: message" "no such directory: $PROJECT/never-registered" "$(field .error)"

# --- rm of a main checkout without linked worktrees (to the Trash) ------------

wt rm "$MAIN"
check_rc "rm main with one linked worktree left" 5
check_eq "rm main refusal: singular" "wt: main checkout has 1 linked worktree: remove them first" "$err"
wt rm "$THREE" --force --json
check_rc "rm the last linked worktree" 0
wt status "$MAIN" --json
check_eq "status: main with no linked worktrees" 0 "$(field .linked)"
main_head=$(git -C "$MAIN" rev-parse HEAD)
echo 'main wip' >"$MAIN/wip.txt"
wt rm "$MAIN" --json
check_rc "rm main, dirty, no --force (D105)" 0
check_json "rm main"
TRASHED="$HOME/.Trash/main"
check_eq "rm main: main true" true "$(field .main)"
check_eq "rm main: removed" "$MAIN" "$(field .removed)"
check_eq "rm main: trashed_to" "$TRASHED" "$(field .trashed_to)"
check_eq "rm main: branch" main "$(field .branch)"
check_true "rm main: checkout gone" "[ ! -e '$MAIN' ]"
check_true "rm main: project folder kept" "[ -d '$PROJECT' ]"
check_eq "rm main: recoverable from the Trash" "$main_head" "$(git -C "$TRASHED" rev-parse HEAD)"
check_true "rm main: env files ride along" "[ -f '$TRASHED/.env.local' ]"
check_true "rm main: the untracked file rides along" "[ -f '$TRASHED/wip.txt' ]"
check_true "rm main: still untracked there" "git -C '$TRASHED' status --porcelain | grep -q '^?? wip.txt'"

# A second repo whose checkout has the same basename gets a timestamp.
git init -q "$MAIN"
echo again >"$MAIN/again.txt"
git -C "$MAIN" add again.txt && git -C "$MAIN" commit -q -m again
wt rm "$MAIN"
check_rc "rm main again (human)" 0
check_true "rm main human line" "printf '%s' \"\$out\" | grep -Eq '^moved repo $MAIN to $TRASHED-[0-9]{8}T[0-9]{6}\$'"
check_true "rm main: first trashed repo untouched" "[ \"\$(git -C '$TRASHED' rev-parse HEAD)\" = '$main_head' ]"
check_eq "rm main: two main entries in the Trash" 2 "$(ls "$HOME/.Trash" | grep -c '^main')"

# A git dir outside the checkout would stay behind: refused (git reports
# the git dir as the main worktree, so this one is not even seen as main).
git init -q --separate-git-dir "$scratch/sep.git" "$scratch/sep/main"
git -C "$scratch/sep/main" commit -q --allow-empty -m sep
wt rm "$scratch/sep/main" --json
check_true "rm refuses a checkout whose git dir is outside it" "[ $rc -ne 0 ] && [ \"\$(field .ok)\" = false ]"
check_true "outside git dir: nothing moved" "[ -d '$scratch/sep/main' ] && [ ! -e '$HOME/.Trash/main-sep' ]"

# --- rm and remote copies (rw forget, D11) -------------------------------------
#
# A repo under the temp HOME (rw roots are relative to ~), rw records written
# by hand as rw writes them (one-line JSON), and a fake rw first in PATH that
# logs its argv and exits with $scratch/rw-exit (0 without).

RWP="$HOME/dev/rwproj"
git init -q "$RWP/main"
git -C "$RWP/main" commit -q --allow-empty -m base
for n in a b c d e f g h; do git -C "$RWP/main" worktree add -q -b "rw/$n" "$RWP/$n" 2>/dev/null; done
fake_bin="$scratch/fake-rw"
mkdir -p "$fake_bin"
cat >"$fake_bin/rw" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >>'$scratch/rw.log'
echo "rw: fake output on stdout"
[ -f '$scratch/rw-msg' ] && cat '$scratch/rw-msg' >&2
[ -f '$scratch/rw-exit' ] && exit "\$(cat '$scratch/rw-exit')"
exit 0
FAKE
chmod +x "$fake_bin/rw"
saved_path=$PATH
PATH="$fake_bin:$PATH"
rw_id() { printf '%s' "dev/rwproj/$1" | cksum | awk '{print $1}'; }
rw_record() { # NAME OWNER WORKER [PENDING-ACTION]
  local id dir pending=""
  id=$(rw_id "$1")
  dir="$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned/$id"
  mkdir -p "$dir"
  [ -n "${4:-}" ] && pending=",\"pending\":{\"action\":\"$4\",\"reason\":\"remote was unreachable\",\"at\":\"x\"}"
  printf '{"root_id":"%s","root_rel":"dev/rwproj/%s","root_local":"%s","kind":"git","worker":"%s","worker_root":"/w/dev/rwproj/%s","owner":"%s","since":"x","endpoints":[]%s}' \
    "$id" "$1" "$RWP/$1" "$3" "$1" "$2" "$pending" >"$dir/record.json"
}
rw_held() { # NAME WORKER
  mkdir -p "$TMUX_REMOTE_WORKSPACES_STATE_DIR/held/$2"
  printf '{"worker":"%s","root_id":"%s","root_rel":"dev/rwproj/%s","worker_root":"/w","since":"x"}' \
    "$2" "$(rw_id "$1")" "$1" >"$TMUX_REMOTE_WORKSPACES_STATE_DIR/held/$2/$(rw_id "$1").json"
}
rw_reset() { rm -f "$scratch/rw.log" "$scratch/rw-exit" "$scratch/rw-msg"; : >"$scratch/rw.log"; }

rw_reset
wt rm "$RWP/a" --json
check_rc "rm with no rw records" 0
check_eq "rm with no rw records: rw not called" "" "$(cat "$scratch/rw.log")"

# Handed back earlier: the worker still holds a copy (held/ only).
rw_reset
rw_held b w1
wt rm "$RWP/b" --json
check_rc "rm of a root a worker holds a copy of" 0
check_json "rm with rw forget (rw's own output kept off stdout)"
# One call, no --worker: rw combines the record and held/ itself, so an
# alias dropped from rw's config cannot block the delete (exit 64).
check_eq "rm: one rw forget, no --worker, no --force" "forget $RWP/b" "$(cat "$scratch/rw.log")"
check_eq "rm: reply says the remote copy went" deleted "$(field .remote)"
check_true "rm: deleted after forget" "[ ! -e '$RWP/b' ]"

# Remote right now: refused without --discard-remote, nothing called.
rw_reset
rw_record c worker w1
rw_held c w1
rw_held c w2
wt rm "$RWP/c" --json
check_rc "rm of a remote root without --discard-remote" 5
check_true "rm remote refusal: says remote" "printf '%s' \"\$(field .error)\" | grep -q 'is remote and its remote copy is the only current one'"
check_eq "rm remote refusal: rw not called" "" "$(cat "$scratch/rw.log")"
check_true "rm remote refusal: kept" "[ -d '$RWP/c' ]"
wt rm "$RWP/c" --discard-remote --json
check_rc "rm --discard-remote of a remote root" 0
check_eq "rm --discard-remote: one forget with --force" "forget $RWP/c --force" "$(cat "$scratch/rw.log")"
check_true "rm --discard-remote: deleted" "[ ! -e '$RWP/c' ]"

# Unreachable worker (exit 6): the delete goes on, rw keeps a pending forget.
rw_reset
rw_record d worker w1
echo 6 >"$scratch/rw-exit"
wt rm "$RWP/d" --discard-remote --json
check_rc "rm with an unreachable worker still deletes" 0
check_eq "rm unreachable: forget was called" "forget $RWP/d --force" "$(cat "$scratch/rw.log")"
check_eq "rm unreachable: reply says pending" pending "$(field .remote)"
check_true "rm unreachable: deleted" "[ ! -e '$RWP/d' ]"
check_true "rm unreachable: noted" "printf '%s' \"\$err\" | grep -q 'deleted on next contact'"

# Any other rw failure blocks the delete.
rw_reset
rw_held e w1
echo 1 >"$scratch/rw-exit"
echo "rw: rw forget: lost contact while deleting" >"$scratch/rw-msg"
wt rm "$RWP/e" --json
check_rc "rm with a failing rw forget" 1
check_true "rm failing forget: kept" "[ -d '$RWP/e' ]"
check_eq "rm failing forget: rw's last line in the error" "rw forget failed for $RWP/e (exit 1: rw forget: lost contact while deleting); nothing deleted" "$(field .error)"

# A forget already pending is rw's to finish: not called again.
rw_reset
rw_record e focus w1 forget
rm -f "$TMUX_REMOTE_WORKSPACES_STATE_DIR/held/w1/$(rw_id e).json"
wt rm "$RWP/e" --json
check_rc "rm with a pending forget" 0
check_eq "rm pending forget: rw not called" "" "$(cat "$scratch/rw.log")"
check_eq "rm pending forget: nothing to report" null "$(field .remote)"

# A pending forget of a root that was remote counts as confirmed (no
# refusal); another copy still held makes rw run, with --force.
rw_reset
rw_record g worker w1 forget
rw_held g w2
wt rm "$RWP/g" --json
check_rc "rm of a pending-forget remote root with another holder" 0
check_eq "rm pending remote root: one forget with --force" "forget $RWP/g --force" "$(cat "$scratch/rw.log")"

# A failure after the forget says the remote copies are already gone.
rw_reset
rw_held h w1
mkdir -p "$HOME/.Trash"
chmod 555 "$HOME/.Trash"
wt rm "$RWP/h" --json
chmod 755 "$HOME/.Trash"
check_rc "rm whose trash move fails after the forget" 1
check_true "rm failing after forget: error says the remote copies went" "printf '%s' \"\$(field .error)\" | grep -q 'its remote copies were already deleted'"
check_true "rm failing after forget: local copy kept" "[ -d '$RWP/h' ]"

# rw not installed: skipped with a note, the delete goes on.
rw_reset
rw_held f w1
PATH=$saved_path
no_rw_path="/usr/bin:/bin:$(dirname "$(command -v git)")"
PATH=$no_rw_path
if command -v rw >/dev/null 2>&1; then
  PATH=$saved_path
  echo "ABORT: rw still resolves without the fake ($no_rw_path)" >&2
  exit 2
fi
wt rm "$RWP/f" --json
PATH=$saved_path
check_rc "rm without rw installed" 0
check_true "rm without rw: deleted" "[ ! -e '$RWP/f' ]"
check_true "rm without rw: noted" "printf '%s' \"\$err\" | grep -q 'rw is not installed'"
check_eq "rm without rw: fake rw not reached" "" "$(cat "$scratch/rw.log")"
check_eq "rm without rw: reply says kept" kept "$(field .remote)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
