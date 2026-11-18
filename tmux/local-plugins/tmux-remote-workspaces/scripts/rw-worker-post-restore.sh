#!/usr/bin/env bash
# Worker-side post-restore (contract C6, docs/tasks/mini-remote-sessions.md).
# Runs ON THE WORKER after its tmux server has been restored:
#
#   - from the boot restore wrapper (setup/templates/tmux-resurrect-restore.sh),
#     which the LaunchAgent/systemd unit and the laptop attach loop's
#     `no-server` path run; and
#   - with --hook, from tmux-resurrect's post-restore-all hook
#     (tmux-remote-workspaces.tmux), so a Continuum restore-on-start fired by
#     any server start (`rw open`, an attach loop rebuilding a session) gets
#     the same treatment. That hook also runs on a laptop restore, so the
#     script acts only where rw-* endpoint sessions exist (they exist only on
#     worker servers) and always exits 0 in --hook mode.
#
# What it does:
#   1. Drops the boot wrapper's bootstrap session (_tmux_restore_boot) once
#      other sessions exist. Under --hook this happens inside the guarded
#      restore, before its incomplete-restore marker clears, so no save can
#      ever capture the bootstrap session.
#   2. Kills every RESTORED rw-* session (one named in the snapshot it was
#      restored from) whose endpoint is not listed in a mirror record with
#      owner=worker, and logs it. When rw closes the last sessions on a
#      worker the server exits and `last` still lists them; without this the
#      next server start (rw's own new-session, or the boot restore) would
#      bring closed sessions back, agents included. A session that is not in
#      the snapshot (rw creating one right now) is never touched.
#   3. tmux-resurrect saves no session options, so every restored rw-*
#      endpoint session comes back with a live prefix and status line.
#      Re-applies the hidden endpoint options (rw_apply_hidden_session_options).
#   4. For each mirror record <worker state dir>/owned/<root_id>/record.json,
#      writes restored.json beside it: {"restored_at", "restored_endpoints"}
#      (the record's endpoints whose rw-* session is live). record.json itself
#      is never written here (the focus machine writes it over ssh), no
#      record is created or deleted, held/ is not touched, and a record whose
#      focus_machine_id is this machine's own id (a focus record, not a
#      mirror) is skipped.
#
# Exit 0 when there is no tmux server or nothing to do; without --hook,
# nonzero when an option or file update failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

hook=0
[ "${1:-}" = "--hook" ] && hook=1

BOOT_SESSION="_tmux_restore_boot"

say() { printf 'rw-worker-post-restore: %s\n' "$1"; }

done_with() { # <status>
  if [ "$hook" -eq 1 ]; then exit 0; fi
  exit "$1"
}

command -v tmux >/dev/null 2>&1 || {
  say "tmux not on PATH"
  done_with 1
}
command -v jq >/dev/null 2>&1 || {
  say "jq not on PATH"
  done_with 1
}

if ! sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"; then
  [ "$hook" -eq 1 ] || say "no tmux server; nothing to do"
  done_with 0
fi

if printf '%s\n' "$sessions" | grep -qx -- "$BOOT_SESSION" &&
  printf '%s\n' "$sessions" | grep -qvx -- "$BOOT_SESSION"; then
  tmux kill-session -t "=$BOOT_SESSION" 2>/dev/null || true
  sessions="$(printf '%s\n' "$sessions" | grep -vx -- "$BOOT_SESSION")"
fi

if ! printf '%s\n' "$sessions" | grep -q '^rw-'; then
  # No endpoint sessions: a focus machine, or a worker with nothing parked.
  [ "$hook" -eq 1 ] || say "no rw-* sessions; nothing to do"
  done_with 0
fi

# This machine's own rw identity, read without creating it. A record naming
# it as focus_machine_id is a focus record (this machine handed the root
# off), never a mirror.
own_ids=""
for f in "$(rw_state_dir)/machine-id" "$(rw_state_dir_at "$HOME")/machine-id"; do
  [ -s "$f" ] && own_ids="$own_ids $(head -n1 "$f")"
done
owned_dir="$(rw_state_dir_at "$HOME")/owned"

# --- 2. Restored sessions nobody owns any more -------------------------------
# Sessions the endpoint mirrors with owner=worker still want: rw-<mid>-<ep>.
wanted=""
if [ -d "$owned_dir" ]; then
  wanted="$(for record in "$owned_dir"/*/record.json; do
    [ -f "$record" ] || continue
    jq -r --arg own "$own_ids" '
      select(.owner == "worker")
      | (.focus_machine_id // "") as $f
      | select(($f != "") and ((" " + $own + " ") | contains(" " + $f + " ") | not))
      | ($f | gsub("-"; "") | .[0:8]) as $mid
      | (.endpoints // [])[] | "rw-" + $mid + "-" + .' "$record" 2>/dev/null
  done)"
fi
snapshot_sessions=""
workspace_common="$RW_PLUGIN_DIR/../tmux-workspace-resurrect/scripts/common.sh"
if [ -f "$workspace_common" ]; then
  snapshot_file="$(
    # shellcheck source=/dev/null
    source "$workspace_common" && printf '%s/last' "$(workspace_resurrect_dir)"
  )"
  if [ -f "$snapshot_file" ]; then
    snapshot_sessions="$(awk -F '\t' '$1 == "pane" || $1 == "window" { print $2 }' "$snapshot_file" | sort -u)"
  fi
fi
removed=0
while IFS= read -r session; do
  case "$session" in rw-*) ;; *) continue ;; esac
  printf '%s\n' "$snapshot_sessions" | grep -Fqx -- "$session" || continue # not restored
  printf '%s\n' "$wanted" | grep -Fqx -- "$session" && continue            # still owned
  if tmux kill-session -t "=$session" 2>/dev/null; then
    removed=$((removed + 1))
    say "killed restored session $session: no worker-owned mirror lists its endpoint"
    rw_log "worker post-restore: killed restored session $session (closed before the snapshot was refreshed)"
  fi
done <<<"$sessions"
if [ "$removed" -gt 0 ]; then
  sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
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

stamped=0
if [ -d "$owned_dir" ]; then
  now="$(rw_now_iso)"
  live_json="$(printf '%s\n' "$sessions" | jq -R . | jq -sc 'map(select(length > 0))')"
  for record in "$owned_dir"/*/record.json; do
    [ -f "$record" ] || continue
    focus_id="$(jq -r '.focus_machine_id // ""' "$record" 2>/dev/null || true)"
    case " $own_ids " in
      *" $focus_id "*) [ -n "$focus_id" ] && continue ;;
    esac
    # Session names are rw-<focus machine short id>-<endpoint id>.
    if json="$(jq -c --arg at "$now" --argjson live "$live_json" '
        ((.focus_machine_id // "") | gsub("-"; "") | .[0:8]) as $mid
        | { restored_at: $at,
            restored_endpoints: [ (.endpoints // [])[]
              | select(("rw-" + $mid + "-" + .) as $name | $live | index($name)) ] }
      ' "$record" 2>/dev/null)" && [ -n "$json" ]; then
      if rw_write_json_atomic "$(dirname "$record")/restored.json" "$json"; then
        stamped=$((stamped + 1))
      else
        failed=$((failed + 1))
        say "could not write restored.json beside $record"
      fi
    else
      failed=$((failed + 1))
      say "unreadable mirror record $record"
    fi
  done
fi
say "recorded the restore for $stamped mirror record(s)"

if [ "$failed" -eq 0 ]; then done_with 0; else done_with 1; fi
