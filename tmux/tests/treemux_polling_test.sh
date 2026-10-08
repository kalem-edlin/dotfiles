#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/../.." && pwd)"
PATCH="$REPO_DIR/setup/patches/treemux-polling.patch"
SOURCE_TREEMUX="${TREEMUX_SOURCE:-$HOME/.config/tmux/plugins/treemux}"
TEST_ROOT="$(mktemp -d /tmp/treemux-polling-test.XXXXXX)"

[ -d "$SOURCE_TREEMUX/.git" ] || {
  printf 'missing Treemux checkout: %s\n' "$SOURCE_TREEMUX" >&2
  exit 1
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
mkdir "$TEST_ROOT/treemux"
git -C "$SOURCE_TREEMUX" archive HEAD | tar -x -C "$TEST_ROOT/treemux"
if ! git -C "$TEST_ROOT/treemux" apply --reverse --check "$PATCH" 2>/dev/null; then
  git -C "$TEST_ROOT/treemux" apply --check "$PATCH"
  git -C "$TEST_ROOT/treemux" apply "$PATCH"
fi
# Also prove the patch still applies to the pristine pinned source and that
# a subsequent setup run can recognize the complete patched state.
git -C "$TEST_ROOT/treemux" apply --reverse "$PATCH"
git -C "$TEST_ROOT/treemux" apply --check "$PATCH"
git -C "$TEST_ROOT/treemux" apply "$PATCH"
git -C "$TEST_ROOT/treemux" apply --reverse --check "$PATCH"
cp "$TEST_DIR/fixtures/treemux_polling_tmux" "$TEST_ROOT/bin/tmux"
cp "$TEST_DIR/fixtures/treemux_polling_python" "$TEST_ROOT/bin/python-mock"
cp "$TEST_DIR/fixtures/treemux_polling_sleep" "$TEST_ROOT/bin/sleep"
chmod +x "$TEST_ROOT/bin/tmux" "$TEST_ROOT/bin/python-mock" "$TEST_ROOT/bin/sleep"

watcher="$TEST_ROOT/treemux/scripts/tree/watch_and_update.sh"
log="$TEST_ROOT/calls.log"

assert_count() {
  local pattern="$1" expected="$2"
  local actual
  actual="$(rg -c -- "$pattern" "$log" || printf '0')"
  [ "$actual" -eq "$expected" ] || {
    printf 'expected %s matches for %s, got %s\n' "$expected" "$pattern" "$actual" >&2
    return 1
  }
}

reset_case() {
  : >"$log"
  : >"$TEST_ROOT/state/list-panes-count"
  : >"$TEST_ROOT/state/list-clients-count"
  : >"$TEST_ROOT/state/cwd-query-count"
}

run_watcher() {
  PATH="$TEST_ROOT/bin:$PATH" \
    TREEMUX_TEST_LOG="$log" \
    TREEMUX_TEST_STATE="$TEST_ROOT/state" \
    "$watcher" '%1' '%2' /project /tmp/tree.sock "$@" nvim "$TEST_ROOT/bin/python-mock" >/dev/null
}

helpers="$(bash -c '
  source "$1"
  get_tmux_option() { printf "%s=%s\\n" "$1" "$2"; }
  source "$2"
  refresh_interval_inactive_pane
  refresh_interval_inactive_window
' _ "$TEST_ROOT/treemux/scripts/variables.sh" "$TEST_ROOT/treemux/scripts/tree_helpers.sh")"
printf '%s\n' "$helpers" | rg -qx '@treemux-refresh-interval-inactive-pane=2'
printf '%s\n' "$helpers" | rg -qx '@treemux-refresh-interval-inactive-window=5'

reset_case
TREEMUX_TEST_ATTACHED=1 TREEMUX_TEST_PANE_ACTIVE=1 run_watcher 0.5 2 5
assert_count '^cwd-query ' 1
assert_count '^python ' 2
rg -qx 'sleep 0.5' "$log"

reset_case
TREEMUX_TEST_ATTACHED=1 TREEMUX_TEST_PANE_ACTIVE=0 run_watcher 0.5 2 5
assert_count '^cwd-query ' 1
assert_count '^python ' 2
rg -qx 'sleep 2' "$log"

reset_case
TREEMUX_TEST_ATTACHED=0 TREEMUX_TEST_PANE_ACTIVE=1 run_watcher 0.5 2 5
assert_count '^cwd-query ' 0
assert_count '^python ' 0
rg -qx 'sleep 5' "$log"

reset_case
TREEMUX_TEST_CYCLES=4 \
  TREEMUX_TEST_VISIBILITY_SEQUENCE=0,1,1,1 \
  TREEMUX_TEST_CWD_SEQUENCE=/project,/project,/changed \
  TREEMUX_TEST_PANE_ACTIVE=1 \
  run_watcher 0.5 2 5
assert_count '^cwd-query ' 3
assert_count '^python ' 3
assert_count '^python wait_treeinit.py$' 1
assert_count '^python go_random_within_rootdir.py$' 1
assert_count '^python change_root.py$' 1

reset_case
TREEMUX_TEST_ATTACHED=1 TREEMUX_TEST_CLIENT_WINDOW=@2 run_watcher 0.5 2 5
assert_count '^cwd-query ' 0
assert_count '^python ' 0
rg -qx 'sleep 5' "$log"

reset_case
TREEMUX_TEST_ATTACHED=1 TREEMUX_TEST_CLIENT_SESSION='$2' run_watcher 0.5 2 5
assert_count '^cwd-query ' 1
assert_count '^python ' 2
rg -qx 'sleep 0.5' "$log"

reset_case
set +e
run_watcher invalid 2 5
status=$?
set -e
[ "$status" -eq 107 ]
[ ! -s "$log" ]

printf 'treemux polling test passed\n'
