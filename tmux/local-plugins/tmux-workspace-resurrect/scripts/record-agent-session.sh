#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

tool="${1:-}"
case "$tool" in
  claude | pi) ;;
  *) exit 0 ;;
esac

pane_id="${TMUX_PANE:-}"
if [ -z "$pane_id" ] || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -er '.session_id | strings | select(length > 0)' 2>/dev/null || true)"
if [ -z "$session_id" ]; then
  exit 0
fi

# Pane numbers are reused after crashes. Bind new hook records to the actual
# server incarnation and pane process, not just the filename pane-N.json.
pane_context="$(tmux display-message -p -t "$pane_id" '#{pane_id} #{pid}:#{start_time}:#{pane_pid}' 2>/dev/null || true)"
[ "${pane_context%% *}" = "$pane_id" ] || exit 0
pane_identity="${pane_context#* }"
[[ "$pane_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || exit 0
# An orphaned application can still carry the previous server's TMUX value.
inherited_server="${TMUX:-}"
inherited_server="${inherited_server#*,}"
inherited_server="${inherited_server%%,*}"
[ "$inherited_server" = "${pane_identity%%:*}" ] || exit 0

state_dir="$(workspace_state_dir)"
state_file="$(workspace_pane_state_file "$pane_id" write "${pane_identity%:*}")" || exit 0
agent_dir="$(dirname "$state_file")"
workspace_ensure_private_dir "$state_dir"
workspace_ensure_private_dir "$agent_dir"

temp_file="$(mktemp "$agent_dir/.agent.XXXXXX")"

printf '%s' "$input" |
  jq \
    --arg tool "$tool" \
    --arg pane_id "$pane_id" \
    --arg pane_identity "$pane_identity" \
    --arg recorded_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson hook_pid "$$" \
    '. + {
      tool: $tool,
      pane_id: $pane_id,
      pane_identity: $pane_identity,
      recorded_at: $recorded_at,
      hook_pid: $hook_pid
    }' >"$temp_file"

chmod 0600 "$temp_file"
mv "$temp_file" "$state_file"
