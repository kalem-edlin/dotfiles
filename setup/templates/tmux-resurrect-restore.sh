#!/usr/bin/env bash
#
# Boot-time tmux restore for a headless worker (contract C6 in
# docs/tasks/mini-remote-sessions.md; runbook in docs/headless-workers.md,
# "Boot-time restore").
#
# Callers:
#   - launchd user agent com.kalem.tmux-resurrect-restore (RunAtLoad) on
#     macOS, systemd user service tmux-resurrect-restore.service on Linux:
#     brings the worker's sessions back after a reboot, before any laptop
#     connects.
#   - the laptop attach loop's `no-server` path, over ssh
#     (tmux-remote-workspaces/scripts/attach-loop.sh).
#
# Flow:
#   1. Take the boot lock ($STATE_DIR/boot-restore.lock, mkdir-based, pid
#      recorded, dead owner reclaimed, bounded wait). Every caller goes
#      through it, so two laptop panes hitting `no-server` at once, or the
#      LaunchAgent and an attach loop, never start or restore twice.
#   2. Live server with sessions: no restore. If a guarded restore is running
#      on it right now (the shared lifecycle lock below has kind=restore),
#      wait for it and, once it succeeds, run the worker post-restore. Else a
#      pure no-op. A live server whose last restore failed exits 1.
#   3. No server: exit 0 when there is no snapshot. Otherwise start the
#      server with the user's tmux.conf and a bootstrap session, and publish
#      the incomplete-restore marker for the new server pid at once, so no
#      save can publish the bootstrap-only landscape. The config load fires
#      Continuum's restore-on-start, which runs the same guarded restore
#      (@resurrect-restore-script-path = tmux/scripts/resurrect_restore.sh).
#      Wait for it; if it never starts (Continuum skips when it sees another
#      tmux process), run the guarded restore here. Success is the guarded
#      restore removing the marker.
#   4. Remove the bootstrap session and run rw-worker-post-restore.sh, which
#      re-applies the hidden endpoint options to every rw-* session and
#      stamps the worker's mirror records.
#
# The lifecycle lock and marker are the ones tmux/scripts/resurrect_save.sh
# (the verified save) and tmux/scripts/resurrect_restore.sh (the guarded
# restore) share: ${TMPDIR:-/tmp}/tmux-resurrect-<server pid>-verified-save.lock
# and ...-restore-incomplete. TMPDIR is taken from the tmux server's own
# global environment, which is what its Continuum restore and its
# client-detached saves see.
#
# Output (this script's and every child's) is appended to
# $STATE_DIR/boot-restore.log, next to the save timer's launchd-save.log.
# Exit status: 0 on restore, on a no-op, and when there is nothing to
# restore; nonzero only on a real failure.
#
# --check: validate that tmux, the guarded restore, the upstream restore and
# the worker post-restore resolve, with no side effects. Used by setup and
# the doctor under a launchd-like minimal environment.

set -u

TMUX_BIN="${TMUX_RESURRECT_RESTORE_TMUX_BIN:-${TMUX_RESURRECT_SAVE_TMUX_BIN:-tmux}}"
TMUX_CFG_DIR="${TMUX_RESURRECT_RESTORE_TMUX_CFG_DIR:-$HOME/.config/tmux}"
TMUX_CONF="${TMUX_RESURRECT_RESTORE_TMUX_CONF:-$TMUX_CFG_DIR/tmux.conf}"
PLUGIN_DIR="${TMUX_RESURRECT_RESTORE_PLUGIN_DIR:-$TMUX_CFG_DIR/plugins/tmux-resurrect}"
UPSTREAM_RESTORE="$PLUGIN_DIR/scripts/restore.sh"
GUARDED_RESTORE="${TMUX_RESURRECT_GUARDED_RESTORE_SCRIPT:-$TMUX_CFG_DIR/scripts/resurrect_restore.sh}"
RW_POST_RESTORE="${TMUX_RESURRECT_RW_POST_RESTORE_SCRIPT:-$TMUX_CFG_DIR/local-plugins/tmux-remote-workspaces/scripts/rw-worker-post-restore.sh}"
STATE_DIR="${TMUX_WORKSPACE_RESURRECT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-workspace-resurrect}"
BOOT_SESSION="_tmux_restore_boot"

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

uint_or() {
  if is_uint "${1:-}"; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# Seconds to wait for another caller holding the boot lock.
BOOT_LOCK_TIMEOUT="$(uint_or "${TMUX_RESURRECT_RESTORE_LOCK_TIMEOUT:-}" 300)"
# Seconds to wait for Continuum's restore-on-start to take the lifecycle
# lock. It fires one second after the config finishes loading, which has
# already happened when `new-session` returns.
CONTINUUM_WAIT="$(uint_or "${TMUX_RESURRECT_RESTORE_CONTINUUM_WAIT:-}" 10)"
# Seconds to wait for a running guarded restore to finish.
RESTORE_TIMEOUT="$(uint_or "${TMUX_RESURRECT_RESTORE_TIMEOUT:-}" 300)"

if [ "${1:-}" = "--check" ]; then
  status=0
  resolved_tmux="$(command -v "$TMUX_BIN" 2>/dev/null || true)"
  if [ -z "$resolved_tmux" ] || [ ! -x "$resolved_tmux" ]; then
    echo "tmux-resurrect-restore --check: FAIL - tmux binary not resolvable (tried '$TMUX_BIN', PATH=$PATH)"
    status=1
  else
    echo "tmux-resurrect-restore --check: tmux binary OK: $resolved_tmux"
  fi
  for pair in "upstream restore:$UPSTREAM_RESTORE:x" "guarded restore:$GUARDED_RESTORE:f" \
    "worker post-restore:$RW_POST_RESTORE:f"; do
    name="${pair%%:*}"
    rest="${pair#*:}"
    path="${rest%:*}"
    mode="${rest##*:}"
    if [ ! -f "$path" ] || { [ "$mode" = x ] && [ ! -x "$path" ]; }; then
      echo "tmux-resurrect-restore --check: FAIL - $name missing or not executable: $path"
      status=1
    else
      echo "tmux-resurrect-restore --check: $name OK: $path"
    fi
  done
  [ "$status" -ne 0 ] || echo "tmux-resurrect-restore --check: OK"
  exit "$status"
fi

[ "$#" -eq 0 ] || {
  echo "tmux-resurrect-restore: unknown argument: $1" >&2
  exit 2
}

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 0700 "$STATE_DIR" 2>/dev/null || true
LOG_FILE="$STATE_DIR/boot-restore.log"
exec >>"$LOG_FILE" 2>&1
chmod 0600 "$LOG_FILE" 2>/dev/null || true

log() {
  printf '[%s] tmux-resurrect-restore[%s]: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$1"
}

fail() {
  log "FAIL: $1"
  exit 1
}

# We are never "inside" tmux here; a stray TMUX would point every tmux call
# at whatever server the caller happened to be in.
unset TMUX TMUX_PANE

resolved_tmux="$(command -v "$TMUX_BIN" 2>/dev/null || true)"
[ -n "$resolved_tmux" ] && [ -x "$resolved_tmux" ] ||
  fail "tmux binary not found/executable (tried '$TMUX_BIN', PATH=$PATH)"
TMUX_BIN="$resolved_tmux"
# tmux-resurrect, Continuum and the workspace hooks call bare `tmux`, which
# launchd's and systemd's minimal PATH cannot resolve.
PATH="$(dirname "$TMUX_BIN"):$PATH"
export PATH
# launchd starts jobs without a locale; the server and every pane it spawns
# inherit this environment.
export LANG="${LANG:-en_US.UTF-8}"

boot_lock="$STATE_DIR/boot-restore.lock"
boot_lock_owned=0
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  if [ "$boot_lock_owned" -eq 1 ]; then
    local owner=""
    IFS= read -r owner <"$boot_lock/pid" 2>/dev/null || true
    if [ "$owner" = "$$" ]; then
      rm -f "$boot_lock/pid" 2>/dev/null || true
      rmdir "$boot_lock" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

waited_for_boot_lock=0
wait_started=$SECONDS
while ! mkdir "$boot_lock" 2>/dev/null; do
  owner=""
  IFS= read -r owner <"$boot_lock/pid" 2>/dev/null || true
  if is_uint "$owner" && ! kill -0 "$owner" 2>/dev/null; then
    log "removing boot lock left by dead pid $owner"
    rm -f "$boot_lock/pid" 2>/dev/null || true
    rmdir "$boot_lock" 2>/dev/null || true
    continue
  fi
  # A lock directory with no pid file older than a few seconds is a crash
  # between mkdir and the pid write.
  if [ -z "$owner" ] && [ $((SECONDS - wait_started)) -ge 5 ]; then
    log "removing boot lock with no owner"
    rmdir "$boot_lock" 2>/dev/null || true
    continue
  fi
  [ "$waited_for_boot_lock" -eq 1 ] || log "waiting for boot restore held by pid ${owner:-unknown}"
  waited_for_boot_lock=1
  [ $((SECONDS - wait_started)) -lt "$BOOT_LOCK_TIMEOUT" ] ||
    fail "timed out after ${BOOT_LOCK_TIMEOUT}s waiting for the boot lock (pid ${owner:-unknown})"
  sleep 0.2
done
printf '%s\n' "$$" >"$boot_lock/pid"
boot_lock_owned=1

server_pid() {
  local pid
  pid="$("$TMUX_BIN" display-message -p '#{pid}' 2>/dev/null || true)"
  is_uint "$pid" && printf '%s\n' "$pid"
}

# The TMPDIR the tmux server (and so its Continuum restore and its saves)
# computes lifecycle paths with.
server_tmpdir_value() {
  local line
  line="$("$TMUX_BIN" show-environment -g TMPDIR 2>/dev/null || true)"
  case "$line" in
    TMPDIR=*) printf '%s\n' "${line#TMPDIR=}" ;;
    *) printf '\n' ;;
  esac
}

lifecycle_paths() {
  local pid="$1" tmpdir
  tmpdir="$(server_tmpdir_value)"
  lifecycle_tmpdir="$tmpdir"
  lifecycle_lock="${tmpdir:-/tmp}/tmux-resurrect-${pid}-verified-save.lock"
  restore_incomplete="${tmpdir:-/tmp}/tmux-resurrect-${pid}-restore-incomplete"
}

lock_kind() {
  local kind=""
  IFS= read -r kind <"$lifecycle_lock/kind" 2>/dev/null || true
  printf '%s\n' "$kind"
}

restore_running() {
  [ -d "$lifecycle_lock" ] && [ "$(lock_kind)" = "restore" ]
}

# wait_for_restore_to_finish: bounded wait while a guarded restore holds the
# lifecycle lock. Returns 1 on timeout.
wait_for_restore_to_finish() {
  local started=$SECONDS owner=""
  while restore_running; do
    IFS= read -r owner <"$lifecycle_lock/pid" 2>/dev/null || true
    if is_uint "$owner" && ! kill -0 "$owner" 2>/dev/null; then
      # The guarded restore's own cleanup did not run; its marker stays and
      # is what reports the failure.
      return 0
    fi
    [ $((SECONDS - started)) -lt "$RESTORE_TIMEOUT" ] || return 1
    sleep 0.2
  done
  return 0
}

other_session_count() {
  "$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null |
    grep -cvx -- "$BOOT_SESSION" || true
}

kill_boot_session() {
  "$TMUX_BIN" kill-session -t "=$BOOT_SESSION" 2>/dev/null || true
}

run_post_restore() {
  if [ ! -f "$RW_POST_RESTORE" ]; then
    log "worker post-restore missing, skipped: $RW_POST_RESTORE"
    return 0
  fi
  if bash "$RW_POST_RESTORE"; then
    log "worker post-restore done"
  else
    log "worker post-restore failed"
    return 1
  fi
}

resurrect_dir_without_server() {
  local configured host
  configured="${TMUX_RESURRECT_RESTORE_DIR:-}"
  if [ -z "$configured" ]; then
    if [ -d "$HOME/.tmux/resurrect" ]; then
      configured="$HOME/.tmux/resurrect"
    else
      configured="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
    fi
  fi
  host="$(hostname 2>/dev/null || true)"
  printf '%s\n' "$configured" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}

resurrect_dir_from_server() {
  local configured host
  configured="$("$TMUX_BIN" show-option -gqv @resurrect-dir 2>/dev/null || true)"
  [ -n "$configured" ] || {
    resurrect_dir_without_server
    return
  }
  host="$(hostname 2>/dev/null || true)"
  printf '%s\n' "$configured" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}

# ---------------------------------------------------------------------------
# Live server: no restore, at most wait for one that is already running.
# ---------------------------------------------------------------------------

if "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
  pid="$(server_pid)" || fail "cannot resolve the tmux server pid"
  lifecycle_paths "$pid"
  if restore_running; then
    log "a guarded restore is running on server $pid; waiting"
    wait_for_restore_to_finish || fail "guarded restore on server $pid did not finish within ${RESTORE_TIMEOUT}s"
    [ ! -e "$restore_incomplete" ] || fail "guarded restore on server $pid did not complete ($restore_incomplete)"
    if [ "$(other_session_count)" -gt 0 ]; then
      kill_boot_session
    fi
    log "restore on server $pid completed; running worker post-restore"
    run_post_restore || exit 1
    exit 0
  fi
  if [ -e "$restore_incomplete" ]; then
    fail "server $pid is live but its last restore did not complete ($restore_incomplete); run the guarded restore (prefix C-M-r) or restart the server"
  fi
  log "server $pid already has sessions; nothing to restore"
  exit 0
fi

# ---------------------------------------------------------------------------
# No server: start one and restore into it.
# ---------------------------------------------------------------------------

snapshot_dir="$(resurrect_dir_without_server)"
if [ ! -e "$snapshot_dir/last" ]; then
  log "no tmux server and no snapshot at $snapshot_dir/last; nothing to restore"
  exit 0
fi
[ -x "$UPSTREAM_RESTORE" ] || fail "tmux-resurrect restore script is not executable: $UPSTREAM_RESTORE"
[ -f "$GUARDED_RESTORE" ] || fail "guarded restore not found: $GUARDED_RESTORE"

start_args=()
[ -f "$TMUX_CONF" ] && start_args=(-f "$TMUX_CONF")
log "starting tmux server (config ${TMUX_CONF}) to restore $(readlink "$snapshot_dir/last" 2>/dev/null || echo last)"
"$TMUX_BIN" "${start_args[@]}" new-session -d -s "$BOOT_SESSION" -c "$HOME" ||
  fail "could not start the tmux server"
pid="$(server_pid)" || fail "tmux server started but its pid is unreadable"
lifecycle_paths "$pid"

# Block saves until a guarded restore succeeds on this server. The guarded
# restore owns this marker from here on and removes it only on success.
if [ ! -e "$restore_incomplete" ]; then
  printf '%s\n' "boot restore pending by pid $$" >"$restore_incomplete" ||
    fail "cannot publish the incomplete-restore marker $restore_incomplete"
fi

restore_dir_live="$(resurrect_dir_from_server)"
if [ ! -e "$restore_dir_live/last" ]; then
  # The config points @resurrect-dir somewhere without a snapshot.
  log "no snapshot at $restore_dir_live/last (from @resurrect-dir); stopping the bootstrap server"
  if [ "$(other_session_count)" -eq 0 ]; then
    kill_boot_session
    rm -f "$restore_incomplete" 2>/dev/null || true
  fi
  exit 0
fi

# Phase 1: give Continuum's restore-on-start the chance to run.
ran_here=0
seen_restore=0
started=$SECONDS
while [ $((SECONDS - started)) -lt "$CONTINUUM_WAIT" ]; do
  if restore_running; then
    seen_restore=1
    break
  fi
  [ -e "$restore_incomplete" ] || break
  sleep 0.2
done

if [ "$seen_restore" -eq 0 ] && [ -e "$restore_incomplete" ] && ! restore_running; then
  # Continuum did not fire (another tmux process was running, auto-restore
  # halted, or no Continuum in this config). Run the guarded restore here.
  log "Continuum did not start a restore within ${CONTINUUM_WAIT}s; running the guarded restore"
  ran_here=1
  # tmux-resurrect's from-scratch restore creates sessions with
  # `tmux -S "${TMUX%%,*}"`, so it must run with TMUX naming this server, as
  # it does under Continuum and the prefix bindings (both run inside the
  # server). Format: <socket path>,<server pid>,<session index>.
  socket_path="$("$TMUX_BIN" display-message -p '#{socket_path}' 2>/dev/null || true)"
  [ -n "$socket_path" ] || fail "cannot resolve the tmux server socket path"
  if TMUX="$socket_path,$pid,0" TMPDIR="$lifecycle_tmpdir" TMUX_RESURRECT_RESTORE_TMUX_BIN="$TMUX_BIN" \
    TMUX_RESURRECT_RESTORE_PLUGIN_DIR="$PLUGIN_DIR" bash "$GUARDED_RESTORE"; then
    :
  elif restore_running; then
    # Continuum started late and won the lifecycle lock; wait for it below.
    log "guarded restore deferred to a restore that started concurrently"
  fi
fi

if restore_running; then
  log "waiting for the running guarded restore on server $pid"
  wait_for_restore_to_finish || fail "guarded restore on server $pid did not finish within ${RESTORE_TIMEOUT}s"
fi

if [ -e "$restore_incomplete" ]; then
  if [ "$(other_session_count)" -eq 0 ]; then
    # Nothing came back; let the server exit so the next attempt starts clean.
    kill_boot_session
  fi
  fail "guarded restore on server $pid did not complete (ran_here=$ran_here); saves stay blocked by $restore_incomplete"
fi

restored="$(other_session_count)"
kill_boot_session
log "restore complete on server $pid: $restored session(s) (ran_here=$ran_here)"
if [ "$restored" -gt 0 ]; then
  run_post_restore || exit 1
fi
exit 0
