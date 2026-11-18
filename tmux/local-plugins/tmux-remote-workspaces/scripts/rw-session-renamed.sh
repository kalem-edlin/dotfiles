#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# tmux `session-renamed` hook (wired in tmux-remote-workspaces.tmux).
#
# Usage: rw-session-renamed.sh <session_id> <new_session_name>
#
# Keeps the laptop-side restore keys current when a session is renamed
# (worktree sessions are renamed by wt and the picker), so
# rw-post-restore.sh still finds the pane after a restore (D14, C6):
#
#   - sessions.jsonl gains a line mapping the session's stable
#     @session-uuid to the new name;
#   - every endpoint whose pane lives in the session (@rw-endpoint on a pane
#     of it) gets focus_session_name = the new name, and its
#     focus_window_index / focus_pane_index refreshed from that pane;
#   - every other endpoint whose focus_session_uuid is the session's uuid
#     (registered, but its pane is not currently bound) gets the new name.
#
# Only endpoint files that already exist are rewritten (atomically); this
# never creates, closes or tombstones an endpoint.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# rw_session_renamed_apply <new_name> <session_uuid> <bound.dump>
# <bound.dump> lines: "<endpoint_id> <window_index> <pane_index>" for each
# pane of the renamed session that carries @rw-endpoint. Prints the ids of
# the endpoints it rewrote.
rw_session_renamed_apply() {
  local new_name="$1" uuid="$2" dump="$3" f id json updated now bound
  now="$(rw_now_iso)"
  for f in "$(rw_endpoints_dir)"/*.json; do
    [ -f "$f" ] || continue
    json="$(jq -c 'select(type == "object")' "$f" 2>/dev/null)" || continue
    id="$(jq -r '.endpoint_id // empty' <<<"$json")"
    [ -n "$id" ] || continue
    bound="$(awk -v id="$id" '$1 == id { print $2 " " $3; exit }' "$dump" 2>/dev/null)"
    if [ -n "$bound" ]; then
      updated="$(jq -c --arg name "$new_name" \
        --argjson w "${bound% *}" --argjson p "${bound#* }" \
        '.focus_session_name = $name | .focus_window_index = $w | .focus_pane_index = $p' \
        <<<"$json")"
    elif [ -n "$uuid" ] && [ "$(jq -r '.focus_session_uuid // empty' <<<"$json")" = "$uuid" ]; then
      updated="$(jq -c --arg name "$new_name" '.focus_session_name = $name' <<<"$json")"
    else
      continue
    fi
    [ -n "$updated" ] && [ "$updated" != "$json" ] || continue
    updated="$(jq -c --arg now "$now" '.updated_at = $now' <<<"$updated")"
    # The endpoint may have been closed while this ran; never recreate it.
    [ -f "$f" ] || continue
    rw_write_json_atomic "$f" "$updated"
    printf '%s\n' "$id"
  done
}

rw_session_renamed_main() {
  local session_id="${1:?session id required}" new_name="${2:?session name required}"
  local uuid dump changed
  command -v jq >/dev/null 2>&1 || return 0

  uuid="$(tmux show-option -t "$session_id" -qv @session-uuid 2>/dev/null || true)"
  if [ -n "$uuid" ] && [ "$(rw_session_name_for_uuid "$uuid")" != "$new_name" ]; then
    rw_register_session_uuid "$uuid" "$new_name"
  fi

  compgen -G "$(rw_endpoints_dir)/*.json" >/dev/null || return 0

  dump="$(mktemp "${TMPDIR:-/tmp}/rw-session-renamed.XXXXXX")" || return 0
  tmux list-panes -s -t "$session_id" \
    -F '#{?@rw-endpoint,#{@rw-endpoint},-} #{window_index} #{pane_index}' 2>/dev/null |
    awk '$1 != "-"' >"$dump"
  changed="$(rw_session_renamed_apply "$new_name" "$uuid" "$dump" | tr '\n' ' ')"
  rm -f "$dump"
  [ -z "$changed" ] || rw_log "session-renamed: $session_id is now '$new_name'; updated endpoints: ${changed% }"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Same lock as session-created-hook.sh, so a create and a rename of one
  # session never interleave their sessions.jsonl writes.
  rw_session_lock_id="${1:-}"
  rw_with_lock "session-${rw_session_lock_id#\$}" rw_session_renamed_main "$@"
fi
