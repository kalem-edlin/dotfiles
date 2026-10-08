#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$(cd "$TEST_DIR/../scripts" && pwd)/resurrect_save.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-save-transaction.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_PLUGIN="$TEST_ROOT/plugin"
FAKE_HOME="$TEST_ROOT/home"
RESURRECT_DIR="$TEST_ROOT/resurrect"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'resurrect save transaction test: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$FAKE_BIN" "$FAKE_PLUGIN/scripts" "$FAKE_HOME" "$RESURRECT_DIR"

cat >"$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) exit 0 ;;
  show-option)
    case "${!#}" in
      @resurrect-dir) printf '%s\n' "$TEST_RESURRECT_DIR" ;;
      @resurrect-delete-backup-after) printf '%s\n' "${TEST_RETENTION_DAYS:-30}" ;;
    esac
    ;;
  display-message) printf '%s\n' 424242 ;;
  set-option | refresh-client) exit 0 ;;
  *) printf 'unexpected fake tmux command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

# Hold the filename timestamp constant. Two successful wrapper processes must
# still publish distinct pairs even when they finish in the same second.
cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = +%Y%m%dT%H%M%S ]; then
  printf '20260929T120000\n'
else
  exec /bin/date "$@"
fi
EOF

cat >"$FAKE_PLUGIN/scripts/save.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

stage="${TMUX_RESURRECT_OVERRIDE_DIR:?}"
snapshot="${TMUX_RESURRECT_OVERRIDE_FILE_PATH:?}"
name="${snapshot##*/}"

case "${TEST_SAVE_MODE:-valid}" in
  error) exit 19 ;;
  malformed)
    printf 'pane\ttruncated\n' >"$snapshot"
    ln -s "$name" "$stage/last"
    printf '{}\n' >"$stage/workspace_state.json"
    ;;
  bad-sidecar)
    printf 'pane\tsession\t0\t1\t:*\t0\ttitle\t/tmp\t1\tzsh\t:zsh\nstate\tsession\tlast\n' >"$snapshot"
    ln -s "$name" "$stage/last"
    printf '{"version":1,"resurrect_snapshot":"wrong-name.txt"}\n' \
      >"$stage/workspace_state.json"
    ;;
  agent-error | valid)
    printf 'pane\tsession\t0\t1\t:*\t0\ttitle\t/tmp\t1\tzsh\t:zsh\nstate\tsession\tlast\n' >"$snapshot"
    ln -s "$name" "$stage/last"
    if [ "${TEST_SAVE_MODE:-valid}" = agent-error ]; then
      errors='[{"pane_id":"%1","reason":"missing"}]'
    else
      errors='[]'
    fi
    jq -n --arg snapshot "$name" --argjson errors "$errors" '{
      version: 1,
      resurrect_snapshot: $snapshot,
      saved_at: "2026-09-29T12:00:00-0500",
      panes: [{pane_id:"%1", logical_id:"session:0.0"}],
      pane_coverage: {
        complete: true, logical_ids_unique: true,
        expected_count: 1, captured_count: 1
      },
      treemux: [],
      agent_capture_errors: $errors
    }' >"$stage/workspace_state.json"
    ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux" "$FAKE_BIN/date" "$FAKE_PLUGIN/scripts/save.sh"

# Seed a known-good published pair and unrelated history. Failed candidates
# must not mutate, delete, or repoint any of it.
old_snapshot=tmux_resurrect_20260928T010203_seed.txt
old_companion="$old_snapshot.workspace_state.json"
printf 'old snapshot bytes\n' >"$RESURRECT_DIR/$old_snapshot"
printf '{"old":"sidecar bytes"}\n' >"$RESURRECT_DIR/$old_companion"
ln -s "$old_snapshot" "$RESURRECT_DIR/last"
ln -s "$old_companion" "$RESURRECT_DIR/workspace_state.json"
printf '1111111111\n' >"$RESURRECT_DIR/.last-successful-save"
printf 'unrelated history bytes\n' >"$RESURRECT_DIR/tmux_resurrect_20260901T000000_history.txt"

manifest() {
  (
    cd "$RESURRECT_DIR"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' link; do
      printf 'LINK %s -> %s\n' "$link" "$(readlink "$link")"
    done
  )
}

run_wrapper() {
  env HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" TEST_RESURRECT_DIR="$RESURRECT_DIR" \
    TMUX_RESURRECT_SAVE_TMUX_BIN="$FAKE_BIN/tmux" \
    TMUX_RESURRECT_SAVE_PLUGIN_DIR="$FAKE_PLUGIN" \
    TEST_SAVE_MODE="$1" bash "$WRAPPER" "${@:2}"
}

assert_failed_without_publication() {
  local mode="$1" before after stderr
  stderr="$TEST_ROOT/$mode.stderr"
  before="$(manifest)"
  if run_wrapper "$mode" 2>"$stderr"; then
    fail "$mode candidate unexpectedly succeeded"
  fi
  after="$(manifest)"
  [ "$after" = "$before" ] || fail "$mode candidate changed published files"
  ! find "$RESURRECT_DIR" -maxdepth 1 -name '.save-stage.*' -print -quit | grep -q . ||
    fail "$mode candidate left a staging directory"
}

assert_failed_without_publication error
assert_failed_without_publication malformed
assert_failed_without_publication bad-sidecar
assert_failed_without_publication agent-error

run_wrapper valid --print-timestamp >"$TEST_ROOT/first.timestamp" ||
  fail 'valid candidate was rejected'
first="$(readlink "$RESURRECT_DIR/last")"
first_sidecar="$(readlink "$RESURRECT_DIR/workspace_state.json")"
[ "$first_sidecar" = "$first.workspace_state.json" ] || fail 'first pair names do not match'
[ -f "$RESURRECT_DIR/$first" ] && [ -f "$RESURRECT_DIR/$first_sidecar" ] ||
  fail 'first published pair is incomplete'
jq -e --arg snapshot "$first" '.resurrect_snapshot == $snapshot' \
  "$RESURRECT_DIR/$first_sidecar" >/dev/null || fail 'first companion points at the wrong snapshot'

run_wrapper valid --print-timestamp >"$TEST_ROOT/second.timestamp" ||
  fail 'second valid candidate was rejected'
second="$(readlink "$RESURRECT_DIR/last")"
second_sidecar="$(readlink "$RESURRECT_DIR/workspace_state.json")"
[ "$second" != "$first" ] || fail 'same-second saves reused a snapshot name'
[ "$second_sidecar" = "$second.workspace_state.json" ] || fail 'second pair names do not match'
[ -f "$RESURRECT_DIR/$first" ] && [ -f "$RESURRECT_DIR/$first_sidecar" ] ||
  fail 'second save damaged the first immutable pair'
[ -f "$RESURRECT_DIR/$second" ] && [ -f "$RESURRECT_DIR/$second_sidecar" ] ||
  fail 'second published pair is incomplete'
[ "$(cat "$RESURRECT_DIR/.last-successful-save")" = "$(cat "$TEST_ROOT/second.timestamp")" ] ||
  fail 'success marker does not describe the latest publication'

# Retention follows tmux-resurrect's policy: age applies only after excluding
# the newest five snapshots. Every deleted snapshot must take its immutable
# companion with it, while non-snapshot files remain outside retention.
rm -rf -- "$RESURRECT_DIR"
mkdir -p "$RESURRECT_DIR"
retained_old=()
deleted_old=()
for index in 1 2 3 4 5 6 7; do
  snapshot="tmux_resurrect_2026070${index}T000000_old${index}.txt"
  printf 'old snapshot %s\n' "$index" >"$RESURRECT_DIR/$snapshot"
  printf '{"pair":%s}\n' "$index" >"$RESURRECT_DIR/$snapshot.workspace_state.json"
  # Index 7 is newest among the expired fixtures.
  touch -t "2026070${index}0000" "$RESURRECT_DIR/$snapshot" \
    "$RESURRECT_DIR/$snapshot.workspace_state.json"
  if [ "$index" -ge 5 ]; then
    retained_old+=("$snapshot")
  else
    deleted_old+=("$snapshot")
  fi
done
fresh=tmux_resurrect_20260928T000000_fresh.txt
printf 'fresh snapshot\n' >"$RESURRECT_DIR/$fresh"
printf '{"pair":"fresh"}\n' >"$RESURRECT_DIR/$fresh.workspace_state.json"
printf 'must survive retention\n' >"$RESURRECT_DIR/operator-note.txt"

run_wrapper valid || fail 'valid retention-triggering save was rejected'
for snapshot in "${deleted_old[@]}"; do
  [ ! -e "$RESURRECT_DIR/$snapshot" ] || fail "expired snapshot survived retention: $snapshot"
  [ ! -e "$RESURRECT_DIR/$snapshot.workspace_state.json" ] ||
    fail "orphan companion survived deleted snapshot: $snapshot"
done
for snapshot in "${retained_old[@]}" "$fresh"; do
  [ -f "$RESURRECT_DIR/$snapshot" ] || fail "retention deleted protected snapshot: $snapshot"
  [ -f "$RESURRECT_DIR/$snapshot.workspace_state.json" ] ||
    fail "retention deleted protected companion: $snapshot"
done
[ -f "$RESURRECT_DIR/operator-note.txt" ] || fail 'retention deleted a non-snapshot file'
latest="$(readlink "$RESURRECT_DIR/last")"
[ -f "$RESURRECT_DIR/$latest" ] && [ -f "$RESURRECT_DIR/$latest.workspace_state.json" ] ||
  fail 'retention damaged the newly published pair'
[ "$(find "$RESURRECT_DIR" -maxdepth 1 -type f -name 'tmux_resurrect_*.txt' | wc -l | tr -d ' ')" = 5 ] ||
  fail 'retention did not preserve exactly the newest five snapshots'

printf 'resurrect transactional save tests passed\n'
