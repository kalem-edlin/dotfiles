#!/usr/bin/env bash
# Drives scripts/agent-state with fixture hook JSON through a fake tmux shim and
# asserts the argv of every tmux invocation. Never runs the real tmux.

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$PLUGIN_DIR/scripts/agent-state"
FIXTURES="$TEST_DIR/fixtures/agent-state"

command -v jq >/dev/null 2>&1 || {
  printf 'missing test dependency: jq\n' >&2
  exit 1
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-state-test.XXXXXX")" || exit 1
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

shim_dir="$scratch/bin"
mkdir -p "$shim_dir" "$scratch/tmux-tmpdir"
LOG="$scratch/tmux.log"
DISPLAY_OUT="$scratch/display.out"
export AGENT_STATE_TEST_LOG="$LOG" AGENT_STATE_TEST_DISPLAY="$DISPLAY_OUT"

# Fake tmux: one log line per call, argv joined by \x1f. display-message prints
# the canned reply in $AGENT_STATE_TEST_DISPLAY.
cat >"$shim_dir/tmux" <<'EOF'
#!/usr/bin/env bash
line=""
for arg in "$@"; do line="$line$arg"$'\x1f'; done
printf '%s\n' "${line%$'\x1f'}" >>"$AGENT_STATE_TEST_LOG"
case "${1:-}" in
  display | display-message) cat "$AGENT_STATE_TEST_DISPLAY" 2>/dev/null ;;
esac
exit 0
EOF
# Fixed clock for @agent_at.
cat >"$shim_dir/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s" ]; then echo 1700000000; else exec /bin/date "$@"; fi
EOF
# Fake ps: the whole-table listing (-A) prints $AGENT_STATE_TEST_PS (default
# empty, so nothing matches); the per-pid lookups of find_agent_pid are real.
cat >"$shim_dir/ps" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -A "*) cat "${AGENT_STATE_TEST_PS:-/dev/null}" 2>/dev/null ;;
  *) exec /bin/ps "$@" ;;
esac
EOF
chmod +x "$shim_dir/tmux" "$shim_dir/date" "$shim_dir/ps"

PATH="$shim_dir:$PATH"
export PATH
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$scratch/tmux-tmpdir"
if [ "$(command -v tmux)" != "$shim_dir/tmux" ]; then
  printf 'ABORT: tmux does not resolve to the shim\n' >&2
  exit 1
fi

PANE="%7"
NOW=1700000000
SERVER_PID=$$ # any live pid stands in for the tmux server
FAKE_TMUX="$scratch/fake-socket,$SERVER_PID,0"
VISIBLE='#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}'
SUBS_GT0='#{e|>|:#{@agent_subs},0}'
SEP=$'\x1f'

pass=0
fail=0
status=0

ok() { pass=$((pass + 1)); }
not_ok() {
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$1" >&2
  [ $# -lt 2 ] || printf '  expected: %s\n  actual:   %s\n' "$2" "$3" | tr "$SEP" '|' >&2
}

join() {
  local out="" arg
  for arg in "$@"; do out="$out$arg$SEP"; done
  printf '%s' "${out%"$SEP"}"
}

# hook EVENT FIXTURE [env...]: runs the publisher with TMUX/TMUX_PANE set.
hook() {
  local event="$1" fixture="$2"
  shift 2
  : >"$LOG"
  env TMUX="$FAKE_TMUX" TMUX_PANE="$PANE" "$@" \
    "$BASH" "$SCRIPT" claude "$event" <"$fixture" >"$scratch/stdout" 2>"$scratch/stderr"
  status=$?
}

assert_quiet() {
  if [ "$status" -eq 0 ] && [ ! -s "$scratch/stdout" ] && [ ! -s "$scratch/stderr" ]; then
    ok
  else
    not_ok "$1: exit $status, stdout/stderr not empty"
  fi
}

# assert_calls NAME CALL...: each CALL is one joined argv, in order.
assert_calls() {
  local name="$1" expected="" actual
  shift
  local call
  for call in "$@"; do expected="$expected$call"$'\n'; done
  actual="$(cat "$LOG")"
  expected="${expected%$'\n'}"
  if [ "$actual" = "$expected" ]; then ok; else not_ok "$name" "$expected" "$actual"; fi
  assert_quiet "$name"
}

# The shim cannot evaluate formats, so @agent_state_at is checked as the exact
# set -F value: keep the stamp if the state is unchanged and stamped, else now.
sa() { printf '#{?#{&&:#{==:#{@agent_state},%s},#{@agent_state_at}},#{@agent_state_at},%s}' "$1" "$NOW"; }
# State writes as top-level argv (joined) and as an if -F branch string.
state_calls() {
  join set -pF -t "$PANE" @agent_state_at "$(sa "$1")" \; set -p -t "$PANE" @agent_state "$1" \
    \; set -p -t "$PANE" @agent_at "$NOW"
}
st() {
  printf 'set -pF -t %s @agent_state_at "%s" ; set -p -t %s @agent_state %s ; set -p -t %s @agent_at %s' \
    "$PANE" "$(sa "$1")" "$PANE" "$1" "$PANE" "$NOW"
}

# with_transcript FIXTURE PATH: the fixture with transcript_path set to PATH.
with_transcript() {
  jq --arg tp "$2" '.transcript_path = $tp' "$1" >"$scratch/hook.json"
  printf '%s' "$scratch/hook.json"
}

# --- guards -------------------------------------------------------------------

: >"$LOG"
env TMUX="$FAKE_TMUX" bash "$SCRIPT" claude PreToolUse <"$FIXTURES/pre-tool-use.json" >"$scratch/stdout" 2>&1
status=$?
assert_calls "no TMUX_PANE is a no-op"

: >"$LOG"
env TMUX_PANE="$PANE" bash "$SCRIPT" claude PreToolUse <"$FIXTURES/pre-tool-use.json" >"$scratch/stdout" 2>&1
status=$?
assert_calls "no TMUX is a no-op"

sh -c ':' &
dead_pid=$!
wait "$dead_pid"
: >"$LOG"
env TMUX="$scratch/fake-socket,$dead_pid,0" TMUX_PANE="$PANE" \
  bash "$SCRIPT" claude PreToolUse <"$FIXTURES/pre-tool-use.json" >"$scratch/stdout" 2>&1
status=$?
assert_calls "stale TMUX (dead server pid) is a no-op"

hook PreToolUse "$FIXTURES/pre-tool-use.json" TMUX_PANE=bogus
assert_calls "malformed TMUX_PANE is a no-op"

# PATH with the script's tools but no tmux at all (never fall back to /usr/bin,
# where a real tmux may live).
notmux_dir="$scratch/notmux"
mkdir -p "$notmux_dir"
for tool in cat date grep jq ps tail; do
  ln -s "$(command -v "$tool")" "$notmux_dir/$tool"
done
if PATH="$notmux_dir" command -v tmux >/dev/null 2>&1; then
  not_ok "notmux PATH still resolves tmux"
else
  hook PreToolUse "$FIXTURES/pre-tool-use.json" PATH="$notmux_dir"
  assert_calls "missing tmux is a no-op"
fi

hook Bogus "$FIXTURES/pre-tool-use.json"
assert_calls "unknown event is a no-op"

: >"$LOG"
env TMUX="$FAKE_TMUX" TMUX_PANE="$PANE" bash "$SCRIPT" codex Stop <"$FIXTURES/stop-plain.json" >"$scratch/stdout" 2>&1
status=$?
assert_calls "unknown agent is a no-op"

# Guard read reports another server pid: read only, no write.
printf '%s %s %s\n' "$PANE" 99999999 "" >"$DISPLAY_OUT"
hook UserPromptSubmit "$FIXTURES/user-prompt.json"
assert_calls "UserPromptSubmit with server pid mismatch writes nothing" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')"

# Guard read reports another pane id: read only, no write.
printf '%%8 %s 123\n' "$SERVER_PID" >"$DISPLAY_OUT"
hook SessionStart "$FIXTURES/session-start.json"
assert_calls "SessionStart with pane id mismatch writes nothing" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')"

# --- SessionStart ---------------------------------------------------------------

# Hook runs directly under a non-shell process (perl stands in for claude) whose
# parent is the pane shell: @agent_pid is that process.
pidfile="$scratch/agent.pid"
printf '%s %s %s\n' "$PANE" "$SERVER_PID" "$$" >"$DISPLAY_OUT"
: >"$LOG"
# shellcheck disable=SC2016 # perl source
env TMUX="$FAKE_TMUX" TMUX_PANE="$PANE" perl -e \
  'open(my $f, ">", shift) or die; print $f $$; close $f; exit(system(@ARGV) >> 8)' \
  "$pidfile" bash "$SCRIPT" claude SessionStart \
  <"$FIXTURES/session-start.json" >"$scratch/stdout" 2>"$scratch/stderr"
status=$?
agent_pid="$(cat "$pidfile")"
assert_calls "SessionStart startup" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -p -t "$PANE" @agent_pid "$agent_pid" \
    \; set -pu -t "$PANE" @agent_name \; set -p -t "$PANE" @agent_empty 1 \; set -p -t "$PANE" @agent_subs 0 \
    \; "$(state_calls idle)")"

# Hook wrapper shell directly under the pane process: the agent is the pane
# process itself. Here the wrapper is this bash ($$) and the "pane" its parent.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" "$PPID" >"$DISPLAY_OUT"
hook SessionStart "$FIXTURES/session-start-compact.json"
assert_calls "SessionStart compact keeps state; wrapper shell resolves to pane pid" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -p -t "$PANE" @agent_pid "$PPID" \; set -pu -t "$PANE" @agent_empty)"

# Pane pid not among our ancestors: no @agent_pid.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" 999999 >"$DISPLAY_OUT"
hook SessionStart "$FIXTURES/session-start-compact.json"
assert_calls "SessionStart without a matching ancestor omits @agent_pid" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -pu -t "$PANE" @agent_empty)"

# resume shows the transcript title at once; startup and clear unset the name
# even when the transcript has a title; compact refreshes it, else keeps it.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" 999999 >"$DISPLAY_OUT"
ss_read="$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')"
hook SessionStart "$(with_transcript "$FIXTURES/session-start-resume.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "SessionStart resume sets the transcript title" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \
    \; set -p -t "$PANE" @agent_name "Auto title: wire session titles into the agent picker card r" \
    \; set -pu -t "$PANE" @agent_empty \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start-resume.json" "$FIXTURES/transcript-untitled.jsonl")"
assert_calls "SessionStart resume without a title unsets the name and @agent_empty" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -pu -t "$PANE" @agent_name \
    \; set -pu -t "$PANE" @agent_empty \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "SessionStart startup unsets the name, sets @agent_empty 1, without reading the transcript" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -pu -t "$PANE" @agent_name \
    \; set -p -t "$PANE" @agent_empty 1 \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start-clear.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "SessionStart clear unsets the name, sets @agent_empty 1, without reading the transcript" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -pu -t "$PANE" @agent_name \
    \; set -p -t "$PANE" @agent_empty 1 \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start-compact.json" "$FIXTURES/transcript-titles.jsonl")"
assert_calls "SessionStart compact refreshes the name from the transcript" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \
    \; set -p -t "$PANE" @agent_name "Renamed session: refactor the agent-state publisher for tmux" \
    \; set -pu -t "$PANE" @agent_empty)"

# --- UserPromptSubmit -------------------------------------------------------------

printf '%s %s \n' "$PANE" "$SERVER_PID" >"$DISPLAY_OUT"
hook UserPromptSubmit "$FIXTURES/user-prompt.json"
assert_calls "UserPromptSubmit names an unnamed pane (sanitized, 40 chars)" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \
    \; set -p -t "$PANE" @agent_name "Fix the broken #{pane_id}; it's \"quoted\"")"

printf '%s %s %s\n' "$PANE" "$SERVER_PID" "existing name" >"$DISPLAY_OUT"
hook UserPromptSubmit "$FIXTURES/user-prompt.json"
assert_calls "UserPromptSubmit keeps an existing name; unsets @agent_empty in the same call" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty)"

# No title in an existing transcript: the prompt fallback as above.
printf '%s %s \n' "$PANE" "$SERVER_PID" >"$DISPLAY_OUT"
hook UserPromptSubmit "$(with_transcript "$FIXTURES/user-prompt.json" "$FIXTURES/transcript-untitled.jsonl")"
assert_calls "UserPromptSubmit without a transcript title falls back to the prompt" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \
    \; set -p -t "$PANE" @agent_name "Fix the broken #{pane_id}; it's \"quoted\"")"

# A transcript title replaces any name, including the prompt fallback.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" "existing name" >"$DISPLAY_OUT"
hook UserPromptSubmit "$(with_transcript "$FIXTURES/user-prompt.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "UserPromptSubmit sets the last ai-title (sanitized, 60 chars)" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \
    \; set -p -t "$PANE" @agent_name "Auto title: wire session titles into the agent picker card r")"

hook UserPromptSubmit "$(with_transcript "$FIXTURES/user-prompt.json" "$FIXTURES/transcript-malformed.jsonl")"
assert_calls "UserPromptSubmit skips malformed and nested title lines" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; set -p -t "$PANE" @agent_name "Valid auto title")"

# --- AskUserQuestion, notifications, subagents ------------------------------------

hook PreToolUse "$FIXTURES/pre-tool-use.json"
assert_calls "PreToolUse AskUserQuestion" \
  "$(state_calls awaiting)"

hook PostToolUse "$FIXTURES/post-tool-use.json"
assert_calls "PostToolUse AskUserQuestion" \
  "$(state_calls working)"

hook Notification "$FIXTURES/notification-elicitation-dialog.json"
assert_calls "Notification elicitation_dialog" \
  "$(state_calls awaiting)"

hook Notification "$FIXTURES/notification-idle-prompt.json"
assert_calls "Notification idle_prompt only while working without subagents" \
  "$(join if -F -t "$PANE" '#{&&:#{==:#{@agent_state},working},#{==:#{e|>|:#{@agent_subs},0},0}}' "$(st idle)")"

hook Notification "$FIXTURES/notification-auth-success.json"
assert_calls "Notification of another type is a no-op"

hook SubagentStart "$FIXTURES/subagent-start.json"
assert_calls "SubagentStart increments" \
  "$(join set -pF -t "$PANE" @agent_subs '#{e|+|:#{@agent_subs},1}')"

hook SubagentStop "$FIXTURES/subagent-stop.json"
assert_calls "SubagentStop decrements clamped at zero" \
  "$(join set -pF -t "$PANE" @agent_subs '#{?#{e|>|:#{@agent_subs},0},#{e|-|:#{@agent_subs},1},0}')"

# --- Stop ---------------------------------------------------------------------------

no_marker_call="$(join if -F -t "$PANE" "$SUBS_GT0" "$(st working)" \
  "if -F -t $PANE '$VISIBLE' '$(st idle)' '$(st finished)'")"

hook Stop "$FIXTURES/stop-marker.json"
assert_calls "Stop with marker: subs>0 working, else awaiting" \
  "$(join if -F -t "$PANE" "$SUBS_GT0" "$(st working)" "$(st awaiting)")"

hook Stop "$FIXTURES/stop-plain.json"
assert_calls "Stop without marker: subs>0 working, else visible idle / finished" "$no_marker_call"

hook Stop "$FIXTURES/stop-near-marker.json"
assert_calls "Stop with marker text not alone on the last line is not awaiting" "$no_marker_call"

stop_with_transcript() {
  jq --arg tp "$1" '.transcript_path = $tp' "$FIXTURES/stop-title.json" >"$scratch/stop.json"
  hook Stop "$scratch/stop.json"
}

# The last custom-title wins over a later ai-title.
stop_with_transcript "$FIXTURES/transcript-titles.jsonl"
assert_calls "Stop overrides the name with the last custom-title (sanitized, 60 chars)" \
  "$(join set -p -t "$PANE" @agent_name "Renamed session: refactor the agent-state publisher for tmux" \
    \; if -F -t "$PANE" "$SUBS_GT0" "$(st working)" \
    "if -F -t $PANE '$VISIBLE' '$(st idle)' '$(st finished)'")"

stop_with_transcript "$FIXTURES/transcript-ai-title.jsonl"
assert_calls "Stop sets the last ai-title without a custom-title" \
  "$(join set -p -t "$PANE" @agent_name "Auto title: wire session titles into the agent picker card r" \
    \; "$no_marker_call")"

# Titles older than the 256 KB tail window: the whole-file scan finds them.
{
  printf '{"type":"ai-title","aiTitle":"early auto","sessionId":"s"}\n'
  printf '{"type":"custom-title","customTitle":"early rename","sessionId":"s"}\n'
  printf '{"type":"ai-title","aiTitle":"later auto","sessionId":"s"}\n'
  filler="$(printf '%01000d' 0)"
  i=0
  while [ "$i" -lt 300 ]; do
    printf '{"type":"assistant","text":"%s"}\n' "$filler"
    i=$((i + 1))
  done
} >"$scratch/long.jsonl"
stop_with_transcript "$scratch/long.jsonl"
assert_calls "Stop finds titles outside the tail window" \
  "$(join set -p -t "$PANE" @agent_name "early rename" \; "$no_marker_call")"

# The same through grep, on a PATH without rg.
norg_dir="$scratch/norg"
mkdir -p "$norg_dir"
for tool in bash cat grep jq ps tail; do
  ln -s "$(command -v "$tool")" "$norg_dir/$tool"
done
ln -s "$shim_dir/tmux" "$norg_dir/tmux"
ln -s "$shim_dir/date" "$norg_dir/date"
jq --arg tp "$scratch/long.jsonl" '.transcript_path = $tp' "$FIXTURES/stop-title.json" >"$scratch/stop.json"
hook Stop "$scratch/stop.json" PATH="$norg_dir"
assert_calls "Stop finds titles outside the tail window without rg" \
  "$(join set -p -t "$PANE" @agent_name "early rename" \; "$no_marker_call")"

stop_with_transcript "$FIXTURES/transcript-untitled.jsonl"
assert_calls "Stop without a transcript title keeps the name" "$no_marker_call"

stop_with_transcript "$scratch/missing.jsonl"
assert_calls "Stop with a missing transcript still sets state" "$no_marker_call"

# --- @agent_state_at ----------------------------------------------------------------

# The stamp format spelled out literally, so sa() cannot drift with the script:
# the first transition (no stamp) and a new state take now, a repeat of the
# stamped state keeps the old stamp. It must precede the @agent_state write.
hook PostToolUse "$FIXTURES/post-tool-use.json"
assert_calls "@agent_state_at is set -F before @agent_state, keyed on the new state" \
  "$(join set -pF -t "$PANE" @agent_state_at \
    '#{?#{&&:#{==:#{@agent_state},working},#{@agent_state_at}},#{@agent_state_at},1700000000}' \
    \; set -p -t "$PANE" @agent_state working \; set -p -t "$PANE" @agent_at "$NOW")"

# --- background shells (Stop, idle_prompt) --------------------------------------------

SNAP='/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh && eval sleep 120'
AGENT=4242
printf '%s\n' " 100 /usr/bin/login" " $AGENT node mcp-server.js" " $AGENT $SNAP" >"$scratch/ps-match"
printf '%s\n' " $AGENT node mcp-server.js" " 999 $SNAP" " 5 /bin/zsh -c eval ls" >"$scratch/ps-other"
printf '%s %s %s' "$PANE" "$SERVER_PID" "$AGENT 77" >"$DISPLAY_OUT"
read_call="$(join display-message -p -t "$PANE" "#{pane_id} #{pid} #{@agent_pid} #{pane_pid}")"

hook Stop "$FIXTURES/stop-plain.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "Stop with a background shell under the agent publishes working" \
  "$read_call" "$(state_calls working)"
hook Stop "$FIXTURES/stop-marker.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "Stop with a background shell and the marker still publishes working" \
  "$read_call" "$(state_calls working)"
hook Notification "$FIXTURES/notification-idle-prompt.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "idle_prompt with a background shell changes nothing" "$read_call"

hook Stop "$FIXTURES/stop-plain.json" AGENT_STATE_TEST_PS="$scratch/ps-other"
assert_calls "Stop: other children and another parent's shell are ignored" "$read_call" "$no_marker_call"
hook Notification "$FIXTURES/notification-idle-prompt.json" AGENT_STATE_TEST_PS="$scratch/ps-other"
assert_calls "idle_prompt: other children and another parent's shell are ignored" "$read_call" \
  "$(join if -F -t "$PANE" '#{&&:#{==:#{@agent_state},working},#{==:#{e|>|:#{@agent_subs},0},0}}' "$(st idle)")"

# --- SessionEnd ---------------------------------------------------------------------

hook SessionEnd "$FIXTURES/session-end.json"
assert_calls "SessionEnd unsets every @agent_* option" \
  "$(join set -pu -t "$PANE" @agent_kind \; set -pu -t "$PANE" @agent_pid \
    \; set -pu -t "$PANE" @agent_state \; set -pu -t "$PANE" @agent_state_at \
    \; set -pu -t "$PANE" @agent_at \
    \; set -pu -t "$PANE" @agent_name \; set -pu -t "$PANE" @agent_subs \
    \; set -pu -t "$PANE" @agent_empty)"

hook SessionEnd "$FIXTURES/session-end-clear.json"
assert_calls "SessionEnd for /clear leaves options to the following SessionStart"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
