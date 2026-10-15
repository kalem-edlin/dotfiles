#!/bin/bash
# Agent Bash calls inherit a socket as stdin that never reaches EOF. Any
# command that reads stdin (a pager standing in for cat, an interactive
# confirmation, a REPL started without a script) blocks until the harness
# moves it to the background, and the turn never completes. Rewrite the
# command so the shell closes stdin before running it. Heredocs and pipes
# carry their own input and are unaffected.
set -eu
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[ "$tool" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0
case "$cmd" in
  "exec </dev/null"*) exit 0 ;;
esac
printf '%s' "$input" | jq -c '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: (.tool_input + { command: ("exec </dev/null\n" + .tool_input.command) })
  }
}'
