#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_DIR="$(cd "$TEST_DIR/.." && pwd)"
RESTORE_WRAPPER="$TMUX_DIR/scripts/resurrect_restore.sh"
SAVE_WRAPPER="$TMUX_DIR/scripts/resurrect_save.sh"
WORKSPACE_RESTORE="$TMUX_DIR/local-plugins/tmux-workspace-resurrect/scripts/restore.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-restore-guard.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_PLUGIN="$TEST_ROOT/plugin"
TEST_TMP="$TEST_ROOT/tmp"
RESURRECT_DIR="$TEST_ROOT/resurrect"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$FAKE_PLUGIN/scripts" "$TEST_TMP" "$RESURRECT_DIR"

cat >"$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) exit 0 ;;
  display-message) printf '424242\n' ;;
  show-option) printf '%s\n' "$TEST_RESURRECT_DIR" ;;
  *) exit 0 ;;
esac
EOF
cat >"$FAKE_PLUGIN/scripts/restore.sh" <<'EOF'
#!/usr/bin/env bash
case "$TEST_MODE" in
  wait)
    printf started >"$TEST_STARTED"
    while [ ! -e "$TEST_RELEASE" ]; do sleep 0.05; done
    printf 'success\n' >"$TMUX_WORKSPACE_RESTORE_RESULT_FILE"
    ;;
  fail) exit 7 ;;
  no-result) exit 0 ;;
  workspace) exec bash "$TEST_WORKSPACE_RESTORE" ;;
  *) exit 2 ;;
esac
EOF
cat >"$FAKE_PLUGIN/scripts/save.sh" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$FAKE_BIN/tmux" "$FAKE_PLUGIN/scripts/restore.sh" "$FAKE_PLUGIN/scripts/save.sh"

export PATH="$FAKE_BIN:$PATH"
export TMPDIR="$TEST_TMP"
export TEST_RESURRECT_DIR="$RESURRECT_DIR"
export TEST_STARTED="$TEST_ROOT/started"
export TEST_RELEASE="$TEST_ROOT/release"
export TEST_WORKSPACE_RESTORE="$WORKSPACE_RESTORE"
export TMUX_RESURRECT_RESTORE_PLUGIN_DIR="$FAKE_PLUGIN"
export TMUX_RESURRECT_SAVE_PLUGIN_DIR="$FAKE_PLUGIN"
export TMUX_RESURRECT_SAVE_TIMEOUT_SECONDS=30

guard="$TEST_TMP/tmux-resurrect-424242-restore-incomplete"
lock="$TEST_TMP/tmux-resurrect-424242-verified-save.lock"

# A restore owns the shared lifecycle lock. Neither another restore nor a save
# may queue behind it and later publish a partial landscape.
env TEST_MODE=wait "$RESTORE_WRAPPER" >"$TEST_ROOT/wait.out" 2>"$TEST_ROOT/wait.err" &
restore_pid=$!
for _ in $(seq 1 100); do
  [ -e "$TEST_STARTED" ] && break
  sleep 0.02
done
[ -e "$TEST_STARTED" ] || { printf 'guarded restore did not start\n' >&2; exit 1; }
if TEST_MODE=no-result "$RESTORE_WRAPPER" 2>"$TEST_ROOT/overlap.err"; then
  printf 'overlapping restore unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'lifecycle operation is already active' "$TEST_ROOT/overlap.err"
if "$SAVE_WRAPPER" 2>"$TEST_ROOT/save-during-restore.err"; then
  printf 'save during restore unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Eq 'restore is (in progress|incomplete)' "$TEST_ROOT/save-during-restore.err"
touch "$TEST_RELEASE"
wait "$restore_pid"
[ ! -e "$guard" ]
[ ! -d "$lock" ]

# tmux-resurrect does not propagate post-hook failures. A zero upstream exit
# without the per-attempt workspace result must therefore remain fail closed.
if TEST_MODE=no-result "$RESTORE_WRAPPER" 2>"$TEST_ROOT/no-result.err"; then
  printf 'restore without workspace completion unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'post-restore did not report successful completion' "$TEST_ROOT/no-result.err"
[ -e "$guard" ]
if "$SAVE_WRAPPER" 2>"$TEST_ROOT/save-after-incomplete.err"; then
  printf 'save after incomplete restore unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'restore is incomplete' "$TEST_ROOT/save-after-incomplete.err"

# An explicit upstream failure has the same fail-closed behavior.
if TEST_MODE=fail "$RESTORE_WRAPPER" 2>"$TEST_ROOT/failure.err"; then
  printf 'failed upstream restore unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'returned an error' "$TEST_ROOT/failure.err"
[ -e "$guard" ]

# Exercise the real workspace post-hook result contract with a private valid
# empty snapshot. No pane command is pasted or executed in this test.
cat >"$RESURRECT_DIR/workspace_state.json" <<'EOF'
{"version":1,"panes":[],"treemux":[]}
EOF
cat >"$TEST_ROOT/config.json" <<'EOF'
{
  "restore_timeout_seconds": 2,
  "restore_pane_timeout_seconds": 1,
  "restore_mode": "queue",
  "restore_whitelist": {"names": [], "delay_ms": 0},
  "capture": {"treemux": false}
}
EOF
TMUX_RESURRECT_DIR="$RESURRECT_DIR" \
  TMUX_WORKSPACE_RESURRECT_CONFIG="$TEST_ROOT/config.json" \
  TMUX_WORKSPACE_RESURRECT_STATE_DIR="$TEST_ROOT/state" \
  TEST_MODE=workspace "$RESTORE_WRAPPER"
[ ! -e "$guard" ]
[ ! -d "$lock" ]

printf 'restore lifecycle guard tests passed\n'
