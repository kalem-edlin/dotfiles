#!/usr/bin/env bash
# Serialized, verified save entrypoint shared by Continuum, manual saves,
# clean-detach saves, and the headless launchd/systemd timer.

set -u

TMUX_BIN="${TMUX_RESURRECT_SAVE_TMUX_BIN:-tmux}"
PLUGIN_DIR="${TMUX_RESURRECT_SAVE_PLUGIN_DIR:-$HOME/.config/tmux/plugins/tmux-resurrect}"
SAVE_SCRIPT="$PLUGIN_DIR/scripts/save.sh"
PRINT_TIMESTAMP=0
success_marker=""
active_save_pid=""
lock_dir=""
lock_owned=0
restore_incomplete=""
stage_dir=""

MAX_SAVE_SECONDS="${TMUX_RESURRECT_SAVE_TIMEOUT_SECONDS:-}"

for arg in "$@"; do
  case "$arg" in
    --print-timestamp) PRINT_TIMESTAMP=1 ;;
    quiet) : ;; # Compatibility with tmux-continuum's save-script contract.
    *)
      printf 'tmux verified save: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

fail() {
  printf 'tmux verified save: %s\n' "$1" >&2
  exit 1
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

snapshot_is_sane() {
  [ -s "$1" ] || return 1
  awk -F'\t' '
    $1 == "pane" && NF == 11 { pane_ok = 1 }
    NF > 0 { last_type = $1; last_nf = NF }
    END { exit !(pane_ok && last_type == "state" && last_nf == 3) }
  ' "$1"
}

process_running() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}

terminate_tree() {
  local root="$1" child
  for child in $(pgrep -P "$root" 2>/dev/null || true); do
    terminate_tree "$child"
  done
  kill -TERM "$root" 2>/dev/null || true
}

kill_tree_hard() {
  local root="$1" child
  for child in $(pgrep -P "$root" 2>/dev/null || true); do
    kill_tree_hard "$child"
  done
  kill -KILL "$root" 2>/dev/null || true
}

prune_old_snapshots() {
  local delete_after current_snapshot
  delete_after="$("$TMUX_BIN" show-option -gqv @resurrect-delete-backup-after 2>/dev/null || true)"
  is_uint "$delete_after" || delete_after=30
  current_snapshot="$(readlink "$resurrect_dir/last" 2>/dev/null || true)"
  python3 - "$resurrect_dir" "$delete_after" "$current_snapshot" <<'PY'
import os
import re
import sys
import time

directory, days_text, current = sys.argv[1:]
days = int(days_text)
pattern = re.compile(r"^tmux_resurrect_.*\.txt$")
snapshots = []
with os.scandir(directory) as entries:
    for entry in entries:
        if not pattern.match(entry.name) or not entry.is_file(follow_symlinks=False):
            continue
        try:
            snapshots.append((entry.stat(follow_symlinks=False).st_mtime, entry.name))
        except FileNotFoundError:
            pass

# Match upstream's `ls -t ... | tail -n +6`: newest five are unconditional.
snapshots.sort(reverse=True)
now = time.time()
for modified, name in snapshots[5:]:
    # `find -mtime +N` means strictly more than N complete 24-hour periods.
    if name == current or int((now - modified) // 86400) <= days:
        continue
    for candidate in (name, name + ".workspace_state.json"):
        try:
            os.unlink(os.path.join(directory, candidate))
        except FileNotFoundError:
            pass
PY
}

cleanup() {
  if is_uint "$active_save_pid" && process_running "$active_save_pid"; then
    terminate_tree "$active_save_pid"
  fi
  if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
    rm -rf -- "$stage_dir"
    stage_dir=""
  fi
  if [ "$lock_owned" -eq 1 ] && [ -n "$lock_dir" ]; then
    local owner=""
    IFS= read -r owner <"$lock_dir/pid" || true
    # A timed-out predecessor may be reaped after another invocation takes
    # the same directory. Never let that predecessor remove the new lock.
    [ "$owner" = "$$" ] || return 0
    rm -f "$lock_dir/pid" "$lock_dir/started_at" "$lock_dir/kind" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    lock_owned=0
  fi
}

command -v "$TMUX_BIN" >/dev/null 2>&1 || fail "tmux is not executable: $TMUX_BIN"
"$TMUX_BIN" list-sessions >/dev/null 2>&1 || fail "no tmux server with sessions is running"

configured_dir="$("$TMUX_BIN" show-option -gqv @resurrect-dir 2>/dev/null || true)"
if [ -z "$configured_dir" ]; then
  if [ -d "$HOME/.tmux/resurrect" ]; then
    configured_dir="$HOME/.tmux/resurrect"
  else
    configured_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
  fi
fi
host="$(hostname 2>/dev/null || true)"
resurrect_dir="$(printf '%s\n' "$configured_dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g")"
success_marker="$resurrect_dir/.last-successful-save"
mkdir -p "$resurrect_dir" || fail "cannot create resurrect directory: $resurrect_dir"
[ -x "$SAVE_SCRIPT" ] || fail "tmux-resurrect save script is not executable: $SAVE_SCRIPT"

if ! is_uint "$MAX_SAVE_SECONDS" || [ "$MAX_SAVE_SECONDS" -lt 30 ]; then
  config_file="${TMUX_WORKSPACE_RESURRECT_CONFIG:-$HOME/.config/tmux/local-plugins/tmux-workspace-resurrect/config.json}"
  if command -v jq >/dev/null 2>&1 && [ -f "$config_file" ]; then
    MAX_SAVE_SECONDS="$(jq -er '.save_timeout_seconds | numbers' "$config_file" 2>/dev/null || true)"
  fi
fi
if ! is_uint "$MAX_SAVE_SECONDS" || [ "$MAX_SAVE_SECONDS" -lt 30 ]; then
  MAX_SAVE_SECONDS=120
fi

server_pid="$("$TMUX_BIN" display-message -p '#{pid}' 2>/dev/null || true)"
is_uint "$server_pid" || fail "cannot resolve the tmux server pid"
lock_dir="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-verified-save.lock"
restore_incomplete="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-restore-incomplete"
[ ! -e "$restore_incomplete" ] ||
  fail "restore is incomplete; run the guarded restore successfully before saving"
request_started="$(date +%s)"
waited_for_save=0
wait_started=$SECONDS
last_lock_refresh=-1
lock_owner=""
lock_started=""
lock_age_at_refresh=0
lock_refreshed_at=0
while ! mkdir "$lock_dir" 2>/dev/null; do
  waited_for_save=1
  # Lock metadata changes only when an owner starts or finishes. Refresh it
  # at most once a second; the old loop forked sed, stat, date, ps, and tr
  # ten times a second while waiting behind a long save.
  if [ "$last_lock_refresh" -lt 0 ] || [ $((SECONDS - last_lock_refresh)) -ge 1 ]; then
    previous_started="$lock_started"
    lock_owner=""
    lock_started=""
    IFS= read -r lock_owner <"$lock_dir/pid" || true
    IFS= read -r lock_started <"$lock_dir/started_at" || true
    lock_kind=""
    IFS= read -r lock_kind <"$lock_dir/kind" || true
    [ "$lock_kind" != "restore" ] ||
      fail "restore is in progress; refusing to queue a save against partial state"
    if is_uint "$lock_started" && [ "$lock_started" != "$previous_started" ]; then
      now="$(date +%s)"
      if [ "$now" -ge "$lock_started" ]; then
        lock_age_at_refresh=$((now - lock_started))
      else
        lock_age_at_refresh=0
      fi
      lock_refreshed_at=$SECONDS
    fi
    last_lock_refresh=$SECONDS
  fi
  lock_age=$((lock_age_at_refresh + SECONDS - lock_refreshed_at))
  if is_uint "$lock_owner" && ! kill -0 "$lock_owner" 2>/dev/null; then
    rm -f "$lock_dir/pid" "$lock_dir/started_at" "$lock_dir/kind" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    last_lock_refresh=-1
    continue
  fi
  if is_uint "$lock_owner" && is_uint "$lock_started" && [ "$lock_age" -gt $((MAX_SAVE_SECONDS + 30)) ]; then
    if kill -0 "$lock_owner" 2>/dev/null; then
      owner_command="$(ps -p "$lock_owner" -o command= 2>/dev/null || true)"
      case "$owner_command" in
        *resurrect_save.sh*)
          printf 'tmux verified save: terminating stale save owner %s after %ss\n' "$lock_owner" "$lock_age" >&2
          terminate_tree "$lock_owner"
          sleep 1
          kill -0 "$lock_owner" 2>/dev/null && kill_tree_hard "$lock_owner"
          ;;
        *) fail "stale save lock has an unexpected live owner: ${lock_owner:-unknown}" ;;
      esac
    fi
    # Do not remove a lock until its recorded owner is actually gone. This
    # protects an unrelated process if a PID was reused while we were
    # inspecting an old lock.
    if kill -0 "$lock_owner" 2>/dev/null; then
      fail "stale save owner did not exit: $lock_owner"
    fi
    rm -f "$lock_dir/pid" "$lock_dir/started_at" "$lock_dir/kind" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    last_lock_refresh=-1
    continue
  fi
  sleep 0.1
  [ $((SECONDS - wait_started)) -lt $((MAX_SAVE_SECONDS + 45)) ] ||
    fail "timed out waiting for another save to finish"
done

# If the save we waited for completed and published a verified marker after
# this request began, reuse that result instead of running the same expensive
# save again. A failed save leaves the old marker in place and falls through.
if [ "$waited_for_save" -eq 1 ]; then
  completed_by_other="$(sed -n '1p' "$success_marker" 2>/dev/null || true)"
  if is_uint "$completed_by_other" && [ "$completed_by_other" -ge "$request_started" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    [ "$PRINT_TIMESTAMP" -eq 0 ] || printf '%s\n' "$completed_by_other"
    exit 0
  fi
fi

printf '%s\n' "$$" >"$lock_dir/pid"
date +%s >"$lock_dir/started_at"
printf '%s\n' save >"$lock_dir/kind"
lock_owned=1
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Close the check/acquire race with a restore that failed immediately before
# this save obtained the shared lifecycle lock.
[ ! -e "$restore_incomplete" ] ||
  fail "restore is incomplete; run the guarded restore successfully before saving"

stage_dir="$(mktemp -d "$resurrect_dir/.save-stage.XXXXXX")" ||
  fail "cannot create private save staging directory"
chmod 0700 "$stage_dir" 2>/dev/null || true
snapshot_basename="tmux_resurrect_$(date +%Y%m%dT%H%M%S)_$$_${RANDOM}.txt"
staged_snapshot="$stage_dir/$snapshot_basename"
last="$stage_dir/last"
sidecar="$stage_dir/workspace_state.json"

# tmux-resurrect and its post-save hook both write only to this private
# directory. The live `last`, workspace_state.json, and success marker remain
# byte-for-byte untouched unless the complete candidate passes every check.
TMUX_RESURRECT_OVERRIDE_DIR="$stage_dir" \
TMUX_RESURRECT_OVERRIDE_FILE_PATH="$staged_snapshot" \
TMUX_RESURRECT_DIR="$stage_dir" \
  bash "$SAVE_SCRIPT" quiet &
active_save_pid=$!
save_started=$SECONDS
while process_running "$active_save_pid"; do
  if [ $((SECONDS - save_started)) -ge "$MAX_SAVE_SECONDS" ]; then
    terminate_tree "$active_save_pid"
    sleep 1
    kill -0 "$active_save_pid" 2>/dev/null && kill_tree_hard "$active_save_pid"
    wait "$active_save_pid" 2>/dev/null || true
    active_save_pid=""
    fail "save exceeded ${MAX_SAVE_SECONDS}s and was terminated"
  fi
  sleep 0.1
done
if ! wait "$active_save_pid"; then
  active_save_pid=""
  fail "tmux-resurrect returned an error"
fi
active_save_pid=""

snapshot_is_sane "$last" || {
  fail "staged snapshot is missing or malformed"
}

[ -f "$sidecar" ] || {
  fail "workspace-resurrect sidecar was not produced"
}

snapshot_name="$(readlink "$last" 2>/dev/null || printf 'last')"
if ! command -v jq >/dev/null 2>&1 ||
  ! jq -e --arg snapshot "$snapshot_name" '
    .version == 1 and
    .resurrect_snapshot == $snapshot and
    (.saved_at | type == "string" and length > 0) and
    (.panes | type == "array") and
    (.pane_coverage.complete == true) and
    (.pane_coverage.logical_ids_unique == true) and
    (.pane_coverage.expected_count == (.panes | length)) and
    (.pane_coverage.captured_count == (.panes | length)) and
    (([.panes[].pane_id] | unique | length) == (.panes | length)) and
    (([.panes[].logical_id] | unique | length) == (.panes | length)) and
    (.treemux | type == "array")
  ' "$sidecar" >/dev/null 2>&1; then
  fail "workspace-resurrect sidecar failed validation"
fi

# The tmux-resurrect snapshot is captured before its post-save hook writes the
# sidecar. Compare the identities in those two artifacts directly; checking
# the later live server can miss a pane that changed during that interval.
if ! python3 - "$last" "$sidecar" <<'PY'
import json
import sys

snapshot_ids = []
with open(sys.argv[1], encoding="utf-8", errors="surrogateescape") as stream:
    for line_number, line in enumerate(stream, 1):
        fields = line.rstrip("\n").split("\t")
        if not fields or fields[0] != "pane":
            continue
        # tmux-resurrect pane schema:
        # type, session, window, active, flags, pane, title, cwd, active,
        # command, full-command.
        if len(fields) != 11:
            raise SystemExit(f"malformed pane record at snapshot line {line_number}")
        snapshot_ids.append(f"{fields[1]}:{fields[2]}.{fields[5]}")

with open(sys.argv[2], encoding="utf-8") as stream:
    sidecar = json.load(stream)
sidecar_ids = [pane.get("logical_id") for pane in sidecar.get("panes", [])]
if (not snapshot_ids or len(snapshot_ids) != len(set(snapshot_ids)) or
        sorted(snapshot_ids) != sorted(sidecar_ids)):
    raise SystemExit("snapshot and sidecar pane logical-id coverage differ")
PY
then
  fail "workspace-resurrect sidecar does not cover the authoritative snapshot panes"
fi

agent_errors="$(jq '[.agent_capture_errors[]?] | length' "$sidecar")"
if [ "$agent_errors" -gt 0 ]; then
  affected_agents="$(jq -r '[.agent_capture_errors[]? | (.logical_id // .pane_id // "unknown")] | unique | join(", ")' "$sidecar")"
  fail "save rejected; previous checkpoint unchanged. $agent_errors agent session(s) lack verified resume IDs: ${affected_agents:-unknown}"
fi

# Keep an immutable sidecar beside every published snapshot. The legacy
# workspace_state.json name remains an atomic symlink for older restores.
published_snapshot="$resurrect_dir/$snapshot_basename"
companion_basename="$snapshot_basename.workspace_state.json"
published_companion="$resurrect_dir/$companion_basename"
mv "$staged_snapshot" "$published_snapshot" || fail "cannot publish snapshot"
mv "$sidecar" "$published_companion" || fail "cannot publish snapshot sidecar"
chmod 0600 "$published_snapshot" "$published_companion" 2>/dev/null || true

last_tmp="$resurrect_dir/.last.$$"
sidecar_tmp="$resurrect_dir/.workspace_state.json.$$"
ln -s "$snapshot_basename" "$last_tmp" || fail "cannot prepare last pointer"
ln -s "$companion_basename" "$sidecar_tmp" || fail "cannot prepare sidecar pointer"
mv -f "$last_tmp" "$resurrect_dir/last" || fail "cannot publish last pointer"
mv -f "$sidecar_tmp" "$resurrect_dir/workspace_state.json" || fail "cannot publish sidecar pointer"

completed_at="$(date +%s)"
marker_tmp="$resurrect_dir/.last-successful-save.$$"
printf '%s\n' "$completed_at" >"$marker_tmp" || fail "cannot write save-success marker"
chmod 0600 "$marker_tmp" 2>/dev/null || true
mv "$marker_tmp" "$success_marker" || fail "cannot publish save-success marker"
prune_old_snapshots
"$TMUX_BIN" set-option -gq @workspace-resurrect-last-success "$completed_at" 2>/dev/null || true
"$TMUX_BIN" refresh-client -S 2>/dev/null || true

[ "$PRINT_TIMESTAMP" -eq 0 ] || printf '%s\n' "$completed_at"
