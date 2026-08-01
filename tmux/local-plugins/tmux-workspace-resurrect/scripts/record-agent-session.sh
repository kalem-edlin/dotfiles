#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

tool="${1:-}"
case "$tool" in
  claude | codex | pi) ;;
  *) exit 0 ;;
esac

pane_id="${TMUX_PANE:-}"
if [ -z "$pane_id" ] || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
if [ -z "$session_id" ]; then
  exit 0
fi

state_dir="$(workspace_state_dir)"
agent_dir="$state_dir/agents"
workspace_ensure_private_dir "$state_dir"
workspace_ensure_private_dir "$agent_dir"

state_file="$(workspace_pane_state_file "$pane_id")"
temp_file="$(mktemp "$agent_dir/.agent.XXXXXX")"

printf '%s' "$input" |
  jq \
    --arg tool "$tool" \
    --arg pane_id "$pane_id" \
    --arg recorded_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson hook_pid "$$" \
    '. + {
      tool: $tool,
      pane_id: $pane_id,
      recorded_at: $recorded_at,
      hook_pid: $hook_pid
    }' >"$temp_file"

chmod 0600 "$temp_file"
mv "$temp_file" "$state_file"
