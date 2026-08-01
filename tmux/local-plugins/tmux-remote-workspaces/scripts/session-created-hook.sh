#!/usr/bin/env bash
# Assigns a stable @session-uuid to a tmux session and registers it in
# sessions.jsonl. Invoked two ways:
#   1. Bound to tmux's global `session-created` hook for every new session.
#   2. Called directly at plugin load to backfill already-running sessions.
#
# @session-uuid is a runtime cache (does not survive server restart);
# sessions.jsonl is the authoritative, append-only, latest-line-wins registry.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

session_id="${1:?session id required as \$1}"
session_name="${2:?session name required as \$2}"
rw_need_jq

assign() {
  local existing
  existing="$(tmux show-option -t "$session_id" -qv @session-uuid 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    # Already assigned (e.g. re-run at plugin reload, or tmux invoking this
    # hook more than once for the same session). Only touch the registry if
    # the last-known name actually changed, so a repeated fire is a no-op.
    if [ "$(rw_session_name_for_uuid "$existing")" != "$session_name" ]; then
      rw_register_session_uuid "$existing" "$session_name"
    fi
    return 0
  fi

  local uuid
  uuid="$(rw_new_uuid)"
  tmux set-option -t "$session_id" -q @session-uuid "$uuid"
  rw_register_session_uuid "$uuid" "$session_name"
  rw_log "assigned session uuid $uuid to $session_name ($session_id)"
}

# Locked so two near-simultaneous fires for the same session (e.g. the
# explicit backfill loop racing tmux's own hook invocation) never both see
# "no existing uuid" and mint two different ones.
rw_with_lock "session-${session_id#\$}" assign
