#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/../plugins/tmux-resurrect" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-process-capture.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_HOME="$TEST_ROOT/home"
RESURRECT_DIR="$TEST_ROOT/resurrect"
PS_CALLS="$TEST_ROOT/ps-calls"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$RESURRECT_DIR"

cat >"$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
	-V) printf 'tmux 3.5a\n' ;;
	show-option)
		option="${!#}"
		case "$option" in
			@resurrect-dir) printf '%s\n' "$TEST_RESURRECT_DIR" ;;
			@resurrect-processes) [ -z "${TEST_PROCESS_SETTING+x}" ] || printf '%s\n' "$TEST_PROCESS_SETTING" ;;
			@resurrect-save-command-strategy) printf '%s\n' "${TEST_STRATEGY_SETTING:-ps}" ;;
			*) : ;;
		esac
		;;
	list-sessions) : ;;
	list-panes)
		printf 'pane<<RESURRECT-TAB>>test<<RESURRECT-TAB>>0<<RESURRECT-TAB>>1<<RESURRECT-TAB>>:*<<RESURRECT-TAB>>0<<RESURRECT-TAB>>title<<RESURRECT-TAB>>:/tmp/path with space<<RESURRECT-TAB>>1<<RESURRECT-TAB>>zsh<<RESURRECT-TAB>>123<<RESURRECT-TAB>>0\n'
		;;
	list-windows) : ;;
	display-message) printf 'state<<RESURRECT-TAB>>test<<RESURRECT-TAB>>last\n' ;;
	*) printf 'unexpected fake tmux command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$TEST_PS_CALLS"
printf '  123 sleep 600\n'
EOF
chmod +x "$FAKE_BIN/tmux" "$FAKE_BIN/ps"

run_case() {
	local setting="$1" strategy="${2:-ps}" case_dir
	case_dir="$RESURRECT_DIR/$setting-$strategy"
	mkdir -p "$case_dir"
	: >"$PS_CALLS"
	env HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" \
		TEST_RESURRECT_DIR="$case_dir" TEST_PROCESS_SETTING="$setting" \
		TEST_STRATEGY_SETTING="$strategy" TEST_PS_CALLS="$PS_CALLS" \
		bash "$PLUGIN_DIR/scripts/save.sh" quiet
	LAST_FILE="$case_dir/last"
}

run_default_case() {
	local case_dir="$RESURRECT_DIR/default"
	mkdir -p "$case_dir"
	: >"$PS_CALLS"
	env -u TEST_PROCESS_SETTING HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" \
		TEST_RESURRECT_DIR="$case_dir" TEST_STRATEGY_SETTING=ps \
		TEST_PS_CALLS="$PS_CALLS" bash "$PLUGIN_DIR/scripts/save.sh" quiet
	LAST_FILE="$case_dir/last"
}

assert_pane_shape_and_command() {
	local expected="$1"
	awk -F'\t' -v expected="$expected" '
		$1 == "pane" { found = 1; if (NF != 11 || $11 != expected) bad = 1 }
		END { exit (bad || !found) }
	' "$LAST_FILE"
}

run_case false
[ ! -s "$PS_CALLS" ] || { printf 'process strategy ran while disabled\n' >&2; exit 1; }
assert_pane_shape_and_command ':'

run_case true
[ "$(wc -l <"$PS_CALLS" | tr -d ' ')" = 1 ] || { printf 'process strategy did not run exactly once\n' >&2; exit 1; }
assert_pane_shape_and_command ':sleep 600'

run_default_case
[ "$(wc -l <"$PS_CALLS" | tr -d ' ')" = 1 ] || { printf 'default process setting did not run the strategy\n' >&2; exit 1; }
assert_pane_shape_and_command ':sleep 600'

run_case true missing-strategy
[ "$(wc -l <"$PS_CALLS" | tr -d ' ')" = 1 ] || { printf 'default strategy fallback did not run\n' >&2; exit 1; }
assert_pane_shape_and_command ':sleep 600'

printf 'save process-capture bypass tests passed\n'
