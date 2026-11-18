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
# empty, so nothing matches). Per-pid lookups are real unless a case supplies
# AGENT_STATE_TEST_PARENT to force deterministic ancestry.
cat >"$shim_dir/ps" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -A "*) cat "${AGENT_STATE_TEST_PS:-/dev/null}" 2>/dev/null ;;
  *)
    if [ -n "${AGENT_STATE_TEST_PARENT:-}" ]; then
      printf '%s\n' "$AGENT_STATE_TEST_PARENT"
    else
      exec /bin/ps "$@"
    fi
    ;;
esac
EOF
chmod +x "$shim_dir/tmux" "$shim_dir/date" "$shim_dir/ps"

PATH="$shim_dir:$PATH"
export PATH
unset TMUX TMUX_PANE AGENT_STATE_OFF AGENT_STATE_PANE
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

# Resume recovery must finish before a new prompt can publish Working.
if jq -e '[.hooks.SessionStart[].hooks[]
    | select((.command // "" | contains("tmux-agent-sessions/scripts/agent-state"))
      and (.command // "" | endswith(" claude SessionStart")))]
    | length == 1 and (.[0].async != true)' \
    "$PLUGIN_DIR/../../../claude/.config/claudef/settings.json" >/dev/null; then
  ok
else
  not_ok "Claude startup-state hook must be synchronous"
fi

join() {
  local out="" arg
  for arg in "$@"; do out="$out$arg$SEP"; done
  printf '%s' "${out%"$SEP"}"
}

# The @agent_cwd write for every fixture's hook cwd (/tmp).
CWD_W="$(join set -p -t "$PANE" @agent_cwd /tmp)"

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

# A nested agent (claudef found the pane already claimed) publishes nothing, so
# its start cannot overwrite the outer agent's state and its end cannot unset it.
for event in SessionStart:session-start UserPromptSubmit:user-prompt Stop:stop-plain SessionEnd:session-end; do
  hook "${event%%:*}" "$FIXTURES/${event#*:}.json" AGENT_STATE_OFF=1
  assert_calls "AGENT_STATE_OFF=1 makes ${event%%:*} a no-op"
done

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
env TMUX="$FAKE_TMUX" TMUX_PANE="$PANE" bash "$SCRIPT" bogus-agent Stop <"$FIXTURES/stop-plain.json" >"$scratch/stdout" 2>&1
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
  "$(join set -p -t "$PANE" @agent_kind claude \; set -p -t "$PANE" @agent_pid "$agent_pid" \; "$CWD_W" \
    \; set -pu -t "$PANE" @agent_name \; set -p -t "$PANE" @agent_empty 1 \; set -p -t "$PANE" @agent_subs 0 \
    \; "$(state_calls idle)")"

# Hook wrapper shell directly under the pane process: the agent is the pane
# process itself. Here the wrapper is this bash ($$) and the "pane" its parent.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" "$PPID" >"$DISPLAY_OUT"
hook SessionStart "$FIXTURES/session-start-compact.json"
assert_calls "SessionStart compact keeps state; wrapper shell resolves to pane pid" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -p -t "$PANE" @agent_pid "$PPID" \; "$CWD_W" \; set -pu -t "$PANE" @agent_empty)"

# Pane pid not among our ancestors: no @agent_pid.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" 999999 >"$DISPLAY_OUT"
hook SessionStart "$FIXTURES/session-start-compact.json"
assert_calls "SessionStart without a matching ancestor omits @agent_pid" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')" \
  "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \; set -pu -t "$PANE" @agent_empty)"

# resume shows the transcript title at once; startup and clear unset the name
# even when the transcript has a title; compact refreshes it, else keeps it.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" 999999 >"$DISPLAY_OUT"
ss_read="$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{pane_pid}')"
hook SessionStart "$(with_transcript "$FIXTURES/session-start-resume.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "SessionStart resume sets the transcript title" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \
    \; set -p -t "$PANE" @agent_name "Auto title: wire session titles into the agent picker card r" \
    \; set -pu -t "$PANE" @agent_empty \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start-resume.json" "$FIXTURES/transcript-untitled.jsonl")"
assert_calls "SessionStart resume without a title unsets the name and @agent_empty" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \; set -pu -t "$PANE" @agent_name \
    \; set -pu -t "$PANE" @agent_empty \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "SessionStart startup unsets the name, sets @agent_empty 1, without reading the transcript" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \; set -pu -t "$PANE" @agent_name \
    \; set -p -t "$PANE" @agent_empty 1 \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start-clear.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "SessionStart clear unsets the name, sets @agent_empty 1, without reading the transcript" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \; set -pu -t "$PANE" @agent_name \
    \; set -p -t "$PANE" @agent_empty 1 \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls idle)")"

hook SessionStart "$(with_transcript "$FIXTURES/session-start-compact.json" "$FIXTURES/transcript-titles.jsonl")"
assert_calls "SessionStart compact refreshes the name from the transcript" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \
    \; set -p -t "$PANE" @agent_name "Renamed session: refactor the agent-state publisher for tmux" \
    \; set -pu -t "$PANE" @agent_empty)"

# --- resumed reply recovery ------------------------------------------------------

# Every case runs the actual hook with a temp hook payload, the fake tmux, and
# deterministic ps ancestry. Exact argv assertions also enforce one state-write
# invocation, in addition to SessionStart's existing pane/server guard read.
resume_case() {
  local name="$1" state="$2" transcript="$3" source="${4:-resume}" empty
  jq --arg source "$source" --arg tp "$transcript" \
    '.source = $source | .transcript_path = $tp' "$FIXTURES/session-start-resume.json" >"$scratch/resume-hook.json"
  hook SessionStart "$scratch/resume-hook.json" AGENT_STATE_TEST_PARENT=1
  case "$source" in
    startup | clear) empty="$(join set -p -t "$PANE" @agent_empty 1)" ;;
    *) empty="$(join set -pu -t "$PANE" @agent_empty)" ;;
  esac
  if [ "$source" = compact ]; then
    assert_calls "$name" "$ss_read" \
      "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \; "$empty")"
  else
    assert_calls "$name" "$ss_read" \
      "$(join set -p -t "$PANE" @agent_kind claude \; "$CWD_W" \; set -pu -t "$PANE" @agent_name \
        \; "$empty" \; set -p -t "$PANE" @agent_subs 0 \; "$(state_calls "$state")")"
  fi
}

marker_file="$FIXTURES/transcript-resume-marker.jsonl"
resume_case "resume recovers a text-block marker with whitespace and blank final lines" awaiting "$marker_file"
resume_case "resume recovers a string content marker without optional stop_reason" awaiting "$FIXTURES/transcript-resume-string.jsonl"
resume_case "resume ignores malformed, truncated, progress and title marker matches" idle "$FIXTURES/transcript-resume-noise.jsonl"
resume_case "startup ignores an old marker" idle "$marker_file" startup
resume_case "clear ignores an old marker" idle "$marker_file" clear
resume_case "compact preserves existing state despite a marker" unused "$marker_file" compact
resume_case "resume with a missing path is idle" idle "$scratch/missing.jsonl"
resume_case "resume with a directory path is idle" idle "$scratch"
cp "$marker_file" "$scratch/unreadable.jsonl"
chmod 000 "$scratch/unreadable.jsonl"
# Root can still read chmod 000 files, so only assert this where unreadable.
if [ ! -r "$scratch/unreadable.jsonl" ]; then
  resume_case "resume with an unreadable transcript is idle" idle "$scratch/unreadable.jsonl"
fi
: >"$scratch/empty.jsonl"
resume_case "resume with an empty transcript is idle" idle "$scratch/empty.jsonl"

# Rewrite or append synthetic records. No local user transcripts are consulted.
jq -c 'select(.type == "user")' "$marker_file" >"$scratch/turn.jsonl"
resume_case "resume with only a user and no assistant is idle" idle "$scratch/turn.jsonl"
for record in \
  '{"type":"user","uuid":"new-user","parentUuid":"reply","message":{"content":"continue"}}' \
  '{"type":"user","uuid":"tool-result","parentUuid":"reply","message":{"content":[{"type":"tool_result","content":"Awaiting your input."}]}}' \
  '{"type":"assistant","uuid":"plain","parentUuid":"reply","message":{"content":"Done.","stop_reason":"end_turn"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Awaiting your input.","input":{}}],"stop_reason":"tool_use"}}' \
  '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Awaiting your input."}],"stop_reason":"end_turn"}}'; do
  { cat "$marker_file"; printf '%s\n' "$record"; } >"$scratch/turn.jsonl"
  resume_case "a newer user/tool/plain/thinking turn masks an old marker: $record" idle "$scratch/turn.jsonl"
done

for reason in null '"tool_use"' '"max_tokens"'; do
  jq -c --argjson reason "$reason" 'if .type == "assistant" then .message.stop_reason = $reason else . end' \
    "$marker_file" >"$scratch/turn.jsonl"
  resume_case "an incomplete response ($reason) cannot recover awaiting" idle "$scratch/turn.jsonl"
done
jq -c 'if .type == "assistant" then .message.content += [{type:"tool_use",name:"Bash",input:{}}] else . end' \
  "$marker_file" >"$scratch/turn.jsonl"
resume_case "a tool-bearing response is not a completed reply even with marker text" idle "$scratch/turn.jsonl"
for text in 'Done.' 'prefix Awaiting your input.' 'Awaiting your input. suffix' $'Awaiting your input.\nMore text'; do
  jq -c --arg text "$text" 'if .type == "assistant" then .message.content = $text else . end' \
    "$marker_file" >"$scratch/turn.jsonl"
  resume_case "only the exact final nonempty line counts: $text" idle "$scratch/turn.jsonl"
done
jq -c 'if .type == "assistant" then .message = "Awaiting your input." else . end' \
  "$marker_file" >"$scratch/turn.jsonl"
resume_case "a legacy string message body is supported" awaiting "$scratch/turn.jsonl"

# Sidechains neither supply the marker nor mask a main-branch marker.
{ cat "$marker_file"; printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"content":"Done."}}'; } >"$scratch/turn.jsonl"
resume_case "a later sidechain plain reply does not mask the main marker" awaiting "$scratch/turn.jsonl"
jq -c 'if .type == "assistant" then .isSidechain = true else . end' "$marker_file" >"$scratch/turn.jsonl"
resume_case "a sidechain marker cannot satisfy the main user prompt" idle "$scratch/turn.jsonl"
{ cat "$marker_file"; printf '%s\n' '{"type":"last-prompt","leafUuid":"missing-sidechain","isSidechain":true}'; } >"$scratch/turn.jsonl"
resume_case "sidechain checkpoints cannot change the current main branch" awaiting "$scratch/turn.jsonl"
resume_case "an explicit rewind selects its main branch rather than the last physical reply" awaiting "$FIXTURES/transcript-resume-rewind.jsonl"
for leaf in root other-reply missing; do
  jq -c --arg leaf "$leaf" 'if .type == "last-prompt" then .leafUuid = $leaf else . end' \
    "$FIXTURES/transcript-resume-rewind.jsonl" >"$scratch/turn.jsonl"
  resume_case "a selected user/plain/missing branch leaf is idle: $leaf" idle "$scratch/turn.jsonl"
done
{ cat "$marker_file"; printf '%s\n' '{"type":"last-prompt","leafUuid":null,"explicit":true}'; } >"$scratch/turn.jsonl"
resume_case "an explicitly cleared branch cannot reuse an old marker" idle "$scratch/turn.jsonl"
{ cat "$FIXTURES/transcript-resume-rewind.jsonl"; printf '%s\n' '{"type":"user","uuid":"after-checkpoint","parentUuid":"waiting-branch","message":{"content":"continue"}}'; } >"$scratch/turn.jsonl"
resume_case "a new prompt after a checkpoint masks its marker" idle "$scratch/turn.jsonl"
printf '%s\n' '{"type":"last-prompt","leafUuid":"waiting-branch"}' >>"$scratch/turn.jsonl"
resume_case "an implicit stale checkpoint cannot revive a marker after a newer prompt" idle "$scratch/turn.jsonl"

# Push relevant records outside the tail window without shell-variable copies
# of the conversation. Also exercise a single oversized record cut by tail.
jq -cn '{type:"progress",data:("x" * 300000)}' >"$scratch/padding.jsonl"
{ cat "$marker_file"; cat "$scratch/padding.jsonl"; } >"$scratch/long-resume.jsonl"
resume_case "streaming fallback finds a marker older than the bounded tail" awaiting "$scratch/long-resume.jsonl"
{ cat "$FIXTURES/transcript-resume-noise.jsonl"; cat "$scratch/padding.jsonl"; } >"$scratch/long-resume.jsonl"
resume_case "streaming fallback without a marker stays idle" idle "$scratch/long-resume.jsonl"
jq -cn '{type:"assistant",message:{content:(("x" * 300000) + "\nAwaiting your input."),stop_reason:"end_turn"}}' >"$scratch/long-resume.jsonl"
resume_case "streaming fallback recovers a marker in an oversized assistant record" awaiting "$scratch/long-resume.jsonl"
{ cat "$marker_file"; jq -cn '{type:"user",message:{content:("x" * 300000)}}'; } >"$scratch/long-resume.jsonl"
resume_case "an oversized newer user record still masks an older marker" idle "$scratch/long-resume.jsonl"
{ cat "$FIXTURES/transcript-resume-rewind.jsonl"; cat "$scratch/padding.jsonl"; printf '%s\n' '{"type":"last-prompt","leafUuid":"waiting-branch","explicit":true}'; } >"$scratch/long-resume.jsonl"
resume_case "a tail checkpoint resolves an older branch UUID through streaming lookup" awaiting "$scratch/long-resume.jsonl"
{ cat "$marker_file"; cat "$scratch/padding.jsonl"; printf '%s\n' '{"type":"user","message":{"content":"new prompt"}}'; } >"$scratch/long-resume.jsonl"
resume_case "the tail fast path sees a newer prompt and never revives an older marker" idle "$scratch/long-resume.jsonl"

# An inherited live server must never be used by these tests. hook always sets
# the fake socket, and even an explicit stale override is rejected before tmux.
hook SessionStart "$scratch/resume-hook.json" TMUX="$scratch/never-a-live-socket,$dead_pid,0"
assert_calls "resumed-session stale inherited server guard remains isolated"

# --- UserPromptSubmit -------------------------------------------------------------

printf '%s %s \n' "$PANE" "$SERVER_PID" >"$DISPLAY_OUT"
hook UserPromptSubmit "$FIXTURES/user-prompt.json"
assert_calls "UserPromptSubmit names an unnamed pane (sanitized, 40 chars)" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; "$CWD_W" \
    \; set -p -t "$PANE" @agent_name "Fix the broken #{pane_id}; it's \"quoted\"")"

printf '%s %s %s\n' "$PANE" "$SERVER_PID" "existing name" >"$DISPLAY_OUT"
hook UserPromptSubmit "$FIXTURES/user-prompt.json"
assert_calls "UserPromptSubmit keeps an existing name; unsets @agent_empty in the same call" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; "$CWD_W")"

# No title in an existing transcript: the prompt fallback as above.
printf '%s %s \n' "$PANE" "$SERVER_PID" >"$DISPLAY_OUT"
hook UserPromptSubmit "$(with_transcript "$FIXTURES/user-prompt.json" "$FIXTURES/transcript-untitled.jsonl")"
assert_calls "UserPromptSubmit without a transcript title falls back to the prompt" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; "$CWD_W" \
    \; set -p -t "$PANE" @agent_name "Fix the broken #{pane_id}; it's \"quoted\"")"

# A transcript title replaces any name, including the prompt fallback.
printf '%s %s %s\n' "$PANE" "$SERVER_PID" "existing name" >"$DISPLAY_OUT"
hook UserPromptSubmit "$(with_transcript "$FIXTURES/user-prompt.json" "$FIXTURES/transcript-ai-title.jsonl")"
assert_calls "UserPromptSubmit sets the last ai-title (sanitized, 60 chars)" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; "$CWD_W" \
    \; set -p -t "$PANE" @agent_name "Auto title: wire session titles into the agent picker card r")"

hook UserPromptSubmit "$(with_transcript "$FIXTURES/user-prompt.json" "$FIXTURES/transcript-malformed.jsonl")"
assert_calls "UserPromptSubmit skips malformed and nested title lines" \
  "$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; "$CWD_W" \; set -p -t "$PANE" @agent_name "Valid auto title")"

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

no_marker_state="$(join if -F -t "$PANE" "$SUBS_GT0" "$(st working)" \
  "if -F -t $PANE '$VISIBLE' '$(st idle)' '$(st finished)'")"
no_marker_call="$(join "$CWD_W" \; "$no_marker_state")"

hook Stop "$FIXTURES/stop-marker.json"
assert_calls "Stop with marker: awaiting, whatever the subagent count" \
  "$(join "$CWD_W" \; "$(state_calls awaiting)")"

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
  "$(join "$CWD_W" \; set -p -t "$PANE" @agent_name "Renamed session: refactor the agent-state publisher for tmux" \
    \; if -F -t "$PANE" "$SUBS_GT0" "$(st working)" \
    "if -F -t $PANE '$VISIBLE' '$(st idle)' '$(st finished)'")"

stop_with_transcript "$FIXTURES/transcript-ai-title.jsonl"
assert_calls "Stop sets the last ai-title without a custom-title" \
  "$(join "$CWD_W" \; set -p -t "$PANE" @agent_name "Auto title: wire session titles into the agent picker card r" \
    \; "$no_marker_state")"

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
  "$(join "$CWD_W" \; set -p -t "$PANE" @agent_name "early rename" \; "$no_marker_state")"

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
  "$(join "$CWD_W" \; set -p -t "$PANE" @agent_name "early rename" \; "$no_marker_state")"

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
  "$read_call" "$(join "$CWD_W" \; "$(state_calls working)")"
hook Stop "$FIXTURES/stop-marker.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "Stop with a background shell and the marker publishes awaiting without a ps read" \
  "$(join "$CWD_W" \; "$(state_calls awaiting)")"
hook Notification "$FIXTURES/notification-idle-prompt.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "idle_prompt with a background shell changes nothing" "$read_call"

hook Stop "$FIXTURES/stop-plain.json" AGENT_STATE_TEST_PS="$scratch/ps-other"
assert_calls "Stop: other children and another parent's shell are ignored" "$read_call" "$no_marker_call"
hook Notification "$FIXTURES/notification-idle-prompt.json" AGENT_STATE_TEST_PS="$scratch/ps-other"
assert_calls "idle_prompt: other children and another parent's shell are ignored" "$read_call" \
  "$(join if -F -t "$PANE" '#{&&:#{==:#{@agent_state},working},#{==:#{e|>|:#{@agent_subs},0},0}}' "$(st idle)")"

# --- background_tasks (Stop, Claude Code 2.1.29x) -------------------------------------

# With the list present the counter is resynced from it and the ps scan is skipped
# (no display-message read), even when a shell-snapshots process exists.
subs_w() { join set -p -t "$PANE" @agent_subs "$1"; }
hook Stop "$FIXTURES/stop-tasks-subagent.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "Stop with in-flight subagents and the marker: subs resynced, awaiting wins, no ps read" \
  "$(join "$CWD_W" \; "$(subs_w 2)" \; "$(state_calls awaiting)")"
hook Stop "$FIXTURES/stop-tasks-subagent-plain.json" AGENT_STATE_TEST_PS="$scratch/ps-match"
assert_calls "Stop with in-flight subagents and no marker: subs resynced, working, no ps read" \
  "$(join "$CWD_W" \; "$(subs_w 2)" \; "$(state_calls working)")"
hook Stop "$FIXTURES/stop-tasks-shell.json" AGENT_STATE_TEST_PS="$scratch/ps-other"
assert_calls "Stop with a background shell task and the marker: subs 0, awaiting" \
  "$(join "$CWD_W" \; "$(subs_w 0)" \; "$(state_calls awaiting)")"
hook Stop "$FIXTURES/stop-tasks-shell-plain.json" AGENT_STATE_TEST_PS="$scratch/ps-other"
assert_calls "Stop with a background shell task and no marker: subs 0, working" \
  "$(join "$CWD_W" \; "$(subs_w 0)" \; "$(state_calls working)")"
hook Stop "$FIXTURES/stop-tasks-empty-marker.json"
assert_calls "Stop with no tasks and the marker: subs 0, awaiting without a counter check" \
  "$(join "$CWD_W" \; "$(subs_w 0)" \; "$(state_calls awaiting)")"
hook Stop "$FIXTURES/stop-tasks-empty-plain.json"
assert_calls "Stop with only finished tasks and no marker: subs 0, visible idle / finished" \
  "$(join "$CWD_W" \; "$(subs_w 0)" \; if -F -t "$PANE" "$VISIBLE" "$(st idle)" "$(st finished)")"

# --- @agent_cwd -----------------------------------------------------------------------

# with_cwd FIXTURE JQ: the fixture rewritten by the jq filter.
with_cwd() {
  jq "$2" "$1" >"$scratch/cwd.json"
  printf '%s' "$scratch/cwd.json"
}
SPACED='/Users/x/My Repo/wt 2'

hook CwdChanged "$FIXTURES/cwd-changed.json"
assert_calls "CwdChanged sets only @agent_cwd from new_cwd (spaces kept)" \
  "$(join set -p -t "$PANE" @agent_cwd "$SPACED")"

hook CwdChanged "$(with_cwd "$FIXTURES/cwd-changed.json" 'del(.cwd)')"
assert_calls "CwdChanged reads new_cwd, not cwd" \
  "$(join set -p -t "$PANE" @agent_cwd "$SPACED")"

hook CwdChanged "$(with_cwd "$FIXTURES/cwd-changed.json" 'del(.new_cwd)')"
assert_calls "CwdChanged without new_cwd writes nothing"

hook CwdChanged "$(with_cwd "$FIXTURES/cwd-changed.json" '.new_cwd = "/tmp/a\nb"')"
assert_calls "CwdChanged drops a cwd with control characters"

hook CwdChanged "$(with_cwd "$FIXTURES/cwd-changed.json" '.new_cwd = "/tmp/a;"')"
assert_calls "CwdChanged drops a cwd ending in a tmux separator"

printf '%s %s %s\n' "$PANE" "$SERVER_PID" 999999 >"$DISPLAY_OUT"
hook SessionStart "$(with_cwd "$FIXTURES/session-start-compact.json" "$(printf '.cwd = "%s"' "$SPACED")")"
assert_calls "SessionStart publishes a cwd with spaces as one argument" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -p -t "$PANE" @agent_cwd "$SPACED" \
    \; set -pu -t "$PANE" @agent_empty)"

hook SessionStart "$(with_cwd "$FIXTURES/session-start-compact.json" 'del(.cwd)')"
assert_calls "SessionStart without cwd writes no @agent_cwd" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -pu -t "$PANE" @agent_empty)"

hook SessionStart "$(with_cwd "$FIXTURES/session-start-compact.json" '.cwd = ""')"
assert_calls "SessionStart with an empty cwd writes no @agent_cwd" "$ss_read" \
  "$(join set -p -t "$PANE" @agent_kind claude \; set -pu -t "$PANE" @agent_empty)"

printf '%s %s %s\n' "$PANE" "$SERVER_PID" "existing name" >"$DISPLAY_OUT"
ups_read="$(join display-message -p -t "$PANE" '#{pane_id} #{pid} #{@agent_name}')"
hook UserPromptSubmit "$(with_cwd "$FIXTURES/user-prompt.json" "$(printf '.cwd = "%s"' "$SPACED")")"
assert_calls "UserPromptSubmit publishes a cwd with spaces" "$ups_read" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty \; set -p -t "$PANE" @agent_cwd "$SPACED")"

hook UserPromptSubmit "$(with_cwd "$FIXTURES/user-prompt.json" 'del(.cwd)')"
assert_calls "UserPromptSubmit without cwd writes no @agent_cwd" "$ups_read" \
  "$(join "$(state_calls working)" \; set -pu -t "$PANE" @agent_empty)"

hook Stop "$(with_cwd "$FIXTURES/stop-plain.json" "$(printf '.cwd = "%s"' "$SPACED")")"
assert_calls "Stop publishes a cwd with spaces" \
  "$(join set -p -t "$PANE" @agent_cwd "$SPACED" \; "$no_marker_state")"

hook Stop "$(with_cwd "$FIXTURES/stop-plain.json" 'del(.cwd)')"
assert_calls "Stop without cwd writes no @agent_cwd" "$no_marker_state"

# --- SessionEnd ---------------------------------------------------------------------

hook SessionEnd "$FIXTURES/session-end.json"
assert_calls "SessionEnd unsets every @agent_* option, @agent_cwd included" \
  "$(join set -pu -t "$PANE" @agent_kind \; set -pu -t "$PANE" @agent_pid \
    \; set -pu -t "$PANE" @agent_state \; set -pu -t "$PANE" @agent_state_at \
    \; set -pu -t "$PANE" @agent_at \
    \; set -pu -t "$PANE" @agent_name \; set -pu -t "$PANE" @agent_subs \
    \; set -pu -t "$PANE" @agent_empty \; set -pu -t "$PANE" @agent_cwd)"

hook SessionEnd "$FIXTURES/session-end-clear.json"
assert_calls "SessionEnd for /clear leaves options to the following SessionStart"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
