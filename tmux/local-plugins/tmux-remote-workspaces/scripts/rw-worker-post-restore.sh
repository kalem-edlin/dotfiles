#!/usr/bin/env bash
# Worker-side post-restore (contract C6, docs/tasks/mini-remote-sessions.md).
# Runs ON THE WORKER after its tmux server has been restored, called by the
# boot restore wrapper (setup/templates/tmux-resurrect-restore.sh), which the
# LaunchAgent/systemd unit and the laptop attach loop's `no-server` path both
# run. Never called on the laptop.
#
#   1. tmux-resurrect saves no session options, so every restored rw-*
#      endpoint session comes back with a live prefix and status line.
#      Re-apply the hidden endpoint options (rw_apply_hidden_session_options).
#   2. Stamp each mirror record under <worker state dir>/owned/<root_id>/
#      record.json with `restored_at` and `restored_endpoints` (the record's
#      endpoints whose rw-* session is live after the restore). Only existing
#      records are updated; owner, since and every other field stay as they
#      are, and nothing is created or deleted (held/ is not touched).
#
# Exit 0 when there is no tmux server or nothing to do; nonzero only when an
# option or record update failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

say() { printf 'rw-worker-post-restore: %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || {
  say "tmux not on PATH"
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  say "jq not on PATH"
  exit 1
}

if ! sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"; then
  say "no tmux server; nothing to do"
  exit 0
fi

failed=0
applied=0
while IFS= read -r session; do
  case "$session" in
    rw-*) ;;
    *) continue ;;
  esac
  if rw_apply_hidden_session_options "$session" >/dev/null 2>&1; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
    say "could not apply hidden options to $session"
  fi
done <<<"$sessions"
say "hidden options applied to $applied rw-* session(s)"

# The worker's own state dir. rw_state_dir_at honours the worker-side
# override (contract C4), which a same-host harness sets; on a real worker it
# is the same directory rw_state_dir resolves to.
owned_dir="$(rw_state_dir_at "$HOME")/owned"
stamped=0
if [ -d "$owned_dir" ]; then
  now="$(rw_now_iso)"
  live_json="$(printf '%s\n' "$sessions" | jq -R . | jq -sc 'map(select(length > 0))')"
  for record in "$owned_dir"/*/record.json; do
    [ -f "$record" ] || continue
    # Session names are rw-<focus machine short id>-<endpoint id>.
    if json="$(jq -c --arg at "$now" --argjson live "$live_json" '
        ((.focus_machine_id // "") | gsub("-"; "") | .[0:8]) as $mid
        | .restored_at = $at
        | .restored_endpoints = [ (.endpoints // [])[]
            | select(("rw-" + $mid + "-" + .) as $name | $live | index($name)) ]
      ' "$record" 2>/dev/null)" && [ -n "$json" ]; then
      if rw_write_json_atomic "$record" "$json"; then
        stamped=$((stamped + 1))
      else
        failed=$((failed + 1))
        say "could not write $record"
      fi
    else
      failed=$((failed + 1))
      say "unreadable mirror record $record"
    fi
  done
fi
say "stamped $stamped mirror record(s)"

[ "$failed" -eq 0 ]
