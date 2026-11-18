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
#   1. Take the boot lock ($STATE_DIR/boot-restore.lock: mkdir-based, owner
#      pid and boot time recorded, bounded wait). A lock whose owner is dead
#      or which was taken before the current boot is stale and reclaimed.
#      Every caller goes through it, so two laptop panes hitting `no-server`
#      at once, or the LaunchAgent and an attach loop, never start or restore
#      twice. The verified save refuses to run while it has a live owner.
#   2. Live server. If a guarded restore is running on it (the shared
#      lifecycle lock below has kind=restore), wait for it. If the only
#      session left is the bootstrap one (a restore that died before
#      restoring anything), run the guarded restore again. If other sessions
#      exist and the last restore did not complete, exit 1: never restore
#      over a partial landscape. Otherwise a no-op.
#   3. No server: exit 0 when there is no snapshot. Otherwise start the
#      server with the user's tmux.conf and a bootstrap session, and publish
#      the incomplete-restore marker for the new server pid at once, so no
#      save can publish the bootstrap-only landscape. The config load fires
#      Continuum's restore-on-start, which runs the same guarded restore
#      (@resurrect-restore-script-path = tmux/scripts/resurrect_restore.sh).
#      Wait for it; if it never starts (Continuum skips when it sees another
#      tmux process), run the guarded restore here. Success is the guarded
#      restore removing the marker. A failed attempt that restored nothing is
#      retried once.
#   4. Remove the bootstrap session (rw-worker-post-restore.sh, chained into
#      post-restore-all, already removes it before the marker clears) and run
#      rw-worker-post-restore.sh, which re-applies the hidden endpoint options
#      to every rw-* session and records the restore beside the worker's
#      mirror records.
#
# The lifecycle lock and marker are the ones tmux/scripts/resurrect_save.sh
# (the verified save) and tmux/scripts/resurrect_restore.sh (the guarded
# restore) share: ${TMPDIR:-/tmp}/tmux-resurrect-<server pid>-verified-save.lock
# and ...-restore-incomplete. TMPDIR is taken from the tmux server's own
# global environment, which is what its Continuum restore and its
# client-detached saves see.
#
# Output (this script's and every child's) is appended to
# $STATE_DIR/boot-restore.log (save results are in workspace-resurrect.log).
# Exit status: 0 on restore, on a no-op, and when there is nothing to
# restore; 75 when another caller held the boot lock past the timeout (try
# again later; a caller must not build anything in the meantime); 1 on any
# other failure.
#
# --check: validate that tmux, the guarded restore, the upstream restore and
# the worker post-restore resolve, with no side effects. Used by setup and
# the doctor under a launchd-like minimal environment.
#
# --restoring: exit 0 when a restore is in progress or incomplete on this
# machine (live boot lock, a server holding the bootstrap session, a guarded
# restore running, or the incomplete-restore marker for the live server),
# else 1. No output, no side effects. The attach loop's probe uses it to
# back off instead of judging a session absent.
#
# --state: print one word, no side effects: `none` (no server, no boot
# restore running), `restoring` (live boot lock, a guarded restore running,
# or a bootstrap session with no marker), `incomplete <marker>` (a live
# server whose last restore did not complete and that nothing is restoring:
# saves are refused), or `ready`. rw reads it
# before it creates an endpoint session (rw_worker_server_sh in
# tmux-remote-workspaces/scripts/common.sh).
#
# --start [<session> <dir>]: the default run, for a caller that needs a
# server: once the restore is done, <session> is created (in <dir>) before
# the bootstrap session goes, so the server never exits in between. With no
# snapshot at all it still starts the server: Continuum's restore-on-start
# then finds nothing, and the incomplete-restore marker its failed guarded
# restore leaves is removed, since no snapshot exists to protect. A server
# on a worker is only ever started through this script: a bare
# `tmux new-session` loads tmux.conf, whose Continuum restore lands in the
# new session's server and leaves the marker behind.
#
# Every default or --start run first removes incomplete-restore markers
# whose server pid is gone (garbage from crashed or killed servers).

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
BOOT_LOCK="$STATE_DIR/boot-restore.lock"
EXIT_LOCK_TIMEOUT=75
# Guarded restore attempts per run while nothing but the bootstrap session
# has come back.
MAX_ATTEMPTS=2

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

# boot_time: seconds since the epoch at which this machine booted (the same
# value on every read until the next boot). Empty when unknown.
boot_time() {
  if [ -n "${TMUX_RESURRECT_BOOT_TIME:-}" ]; then
    printf '%s\n' "$TMUX_RESURRECT_BOOT_TIME"
  elif [ -r /proc/stat ]; then
    awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null
  else
    { sysctl -n kern.boottime 2>/dev/null || /usr/sbin/sysctl -n kern.boottime 2>/dev/null; } |
      sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p'
  fi
}

# boot_lock_live: the boot lock exists, its owner is alive, and it was taken
# during this boot. A lock from an earlier boot (the state dir survives a
# reboot, and its pid may have been recycled) is never live.
boot_lock_live() {
  local owner="" taken="" now
  [ -d "$BOOT_LOCK" ] || return 1
  IFS= read -r owner <"$BOOT_LOCK/pid" 2>/dev/null || true
  IFS= read -r taken <"$BOOT_LOCK/boot" 2>/dev/null || true
  is_uint "$owner" || return 1
  kill -0 "$owner" 2>/dev/null || return 1
  now="$(boot_time)"
  if is_uint "$taken" && is_uint "$now" && [ "$taken" != "$now" ]; then
    return 1
  fi
  return 0
}

server_pid() {
  local pid
  pid="$("$TMUX_BIN" display-message -p '#{pid}' 2>/dev/null || true)"
  is_uint "$pid" && printf '%s\n' "$pid"
}

# lifecycle_paths <server pid>: sets lifecycle_tmpdir, lifecycle_lock and
# restore_incomplete. The TMPDIR is the server's own (its Continuum restore
# and its saves compute these paths with it): `show-environment -g` prints
# TMPDIR=<dir>, or fails with "unknown variable" / prints -TMPDIR when the
# server has none, which means /tmp. Any other answer falls back to the
# caller's TMPDIR.
lifecycle_paths() {
  local pid="$1" out
  out="$("$TMUX_BIN" show-environment -g TMPDIR 2>&1 || true)"
  case "$out" in
    TMPDIR=*) lifecycle_tmpdir="${out#TMPDIR=}" ;;
    -TMPDIR | *"unknown variable"*) lifecycle_tmpdir="" ;;
    *) lifecycle_tmpdir="${TMPDIR:-}" ;;
  esac
  lifecycle_lock="${lifecycle_tmpdir:-/tmp}/tmux-resurrect-${pid}-verified-save.lock"
  restore_incomplete="${lifecycle_tmpdir:-/tmp}/tmux-resurrect-${pid}-restore-incomplete"
}

lock_kind() {
  local kind=""
  IFS= read -r kind <"$lifecycle_lock/kind" 2>/dev/null || true
  printf '%s\n' "$kind"
}

restore_running() {
  [ -d "$lifecycle_lock" ] && [ "$(lock_kind)" = "restore" ]
}

boot_session_exists() {
  "$TMUX_BIN" has-session -t "=$BOOT_SESSION" 2>/dev/null
}

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

if [ "${1:-}" = "--restoring" ]; then
  unset TMUX TMUX_PANE
  boot_lock_live && exit 0
  "$TMUX_BIN" list-sessions >/dev/null 2>&1 || exit 1
  boot_session_exists && exit 0
  pid="$(server_pid)" || exit 1
  lifecycle_paths "$pid"
  restore_running && exit 0
  [ -e "$restore_incomplete" ] && exit 0
  exit 1
fi

# restore_owner_live: a guarded restore holds the lifecycle lock and its
# owner is alive.
restore_owner_live() {
  local owner=""
  restore_running || return 1
  IFS= read -r owner <"$lifecycle_lock/pid" 2>/dev/null || true
  ! is_uint "$owner" || kill -0 "$owner" 2>/dev/null
}

if [ "${1:-}" = "--state" ]; then
  unset TMUX TMUX_PANE
  if ! "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
    if boot_lock_live; then echo restoring; else echo none; fi
    exit 0
  fi
  if boot_lock_live; then
    echo restoring
    exit 0
  fi
  pid="$(server_pid)" || {
    echo none
    exit 0
  }
  lifecycle_paths "$pid"
  # A restore that gave up leaves the marker, and the bootstrap session too
  # when it brought sessions back: that is incomplete, not in progress.
  if restore_owner_live; then
    echo restoring
  elif [ -e "$restore_incomplete" ]; then
    printf 'incomplete %s\n' "$restore_incomplete"
  elif boot_session_exists; then
    echo restoring
  else
    echo ready
  fi
  exit 0
fi

start_session=""
start_dir=""
if [ "${1:-}" = "--start" ]; then
  shift
  if [ "$#" -gt 0 ]; then
    start_session="$1"
    start_dir="${2:-$HOME}"
    shift
    [ "$#" -eq 0 ] || shift
  fi
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

boot_lock_owned=0
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  if [ "$boot_lock_owned" -eq 1 ]; then
    local owner=""
    IFS= read -r owner <"$BOOT_LOCK/pid" 2>/dev/null || true
    if [ "$owner" = "$$" ]; then
      rm -f "$BOOT_LOCK/pid" "$BOOT_LOCK/boot" 2>/dev/null || true
      rmdir "$BOOT_LOCK" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

waited_for_boot_lock=0
wait_started=$SECONDS
while ! mkdir "$BOOT_LOCK" 2>/dev/null; do
  owner=""
  IFS= read -r owner <"$BOOT_LOCK/pid" 2>/dev/null || true
  # A lock directory without a pid file younger than a few seconds is an
  # owner between its mkdir and its pid write; anything else that is not
  # live (dead owner, previous boot) is stale.
  if [ -n "$owner" ] || [ $((SECONDS - wait_started)) -ge 5 ]; then
    if ! boot_lock_live; then
      log "removing stale boot lock (pid ${owner:-none})"
      rm -f "$BOOT_LOCK/pid" "$BOOT_LOCK/boot" 2>/dev/null || true
      rmdir "$BOOT_LOCK" 2>/dev/null || true
      continue
    fi
  fi
  [ "$waited_for_boot_lock" -eq 1 ] || log "waiting for boot restore held by pid ${owner:-unknown}"
  waited_for_boot_lock=1
  if [ $((SECONDS - wait_started)) -ge "$BOOT_LOCK_TIMEOUT" ]; then
    log "timed out after ${BOOT_LOCK_TIMEOUT}s waiting for the boot lock (pid ${owner:-unknown})"
    exit "$EXIT_LOCK_TIMEOUT"
  fi
  sleep 0.2
done
printf '%s\n' "$$" >"$BOOT_LOCK/pid"
boot_time >"$BOOT_LOCK/boot"
boot_lock_owned=1

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

expand_dir() {
  local host
  host="$(hostname 2>/dev/null || true)"
  printf '%s\n' "$1" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}

resurrect_dir_without_server() {
  local configured="${TMUX_RESURRECT_RESTORE_DIR:-}"
  if [ -z "$configured" ]; then
    if [ -d "$HOME/.tmux/resurrect" ]; then
      configured="$HOME/.tmux/resurrect"
    else
      configured="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
    fi
  fi
  expand_dir "$configured"
}

resurrect_dir_from_server() {
  local configured
  configured="$("$TMUX_BIN" show-option -gqv @resurrect-dir 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    expand_dir "$configured"
  else
    resurrect_dir_without_server
  fi
}

# run_guarded_restore: the guarded restore, run here. tmux-resurrect's
# from-scratch restore creates sessions with `tmux -S "${TMUX%%,*}"`, so it
# must run with TMUX naming this server, as it does under Continuum and the
# prefix bindings (both run inside the server). Format:
# <socket path>,<server pid>,<session index>.
run_guarded_restore() {
  local socket_path
  socket_path="$("$TMUX_BIN" display-message -p '#{socket_path}' 2>/dev/null || true)"
  [ -n "$socket_path" ] || {
    log "cannot resolve the tmux server socket path"
    return 1
  }
  TMUX="$socket_path,$pid,0" TMPDIR="$lifecycle_tmpdir" TMUX_RESURRECT_RESTORE_TMUX_BIN="$TMUX_BIN" \
    TMUX_RESURRECT_RESTORE_PLUGIN_DIR="$PLUGIN_DIR" bash "$GUARDED_RESTORE"
}

# restore_into_server <continuum wait seconds>
# Drives the server ($pid) to a completed restore: waits for a restore that
# Continuum starts (or is already running), runs the guarded restore here
# when none runs, and retries while nothing but the bootstrap session has
# come back. Never restores over sessions a failed attempt left behind.
# Returns 0 when the marker is gone.
attempts=0
restore_into_server() {
  local wait_seconds="$1" started=$SECONDS
  while [ $((SECONDS - started)) -lt "$wait_seconds" ]; do
    restore_running && break
    [ -e "$restore_incomplete" ] || break
    sleep 0.2
  done
  while :; do
    if restore_running; then
      log "waiting for the running guarded restore on server $pid"
      wait_for_restore_to_finish || fail "guarded restore on server $pid did not finish within ${RESTORE_TIMEOUT}s"
    fi
    [ -e "$restore_incomplete" ] || return 0
    if [ "$(other_session_count)" -gt 0 ]; then
      log "restore on server $pid is partial; not restoring over the sessions it left"
      return 1
    fi
    [ "$attempts" -lt "$MAX_ATTEMPTS" ] || return 1
    attempts=$((attempts + 1))
    log "running the guarded restore on server $pid (attempt $attempts)"
    if ! run_guarded_restore && ! restore_running; then
      log "guarded restore attempt $attempts failed"
    fi
  done
}

# ensure_start_session: with --start <session>, create it (once the restore
# is done, before the bootstrap session goes) unless it exists.
ensure_start_session() {
  [ -n "$start_session" ] || return 0
  "$TMUX_BIN" has-session -t "=$start_session" 2>/dev/null && return 0
  if "$TMUX_BIN" new-session -d -s "$start_session" -c "${start_dir:-$HOME}"; then
    log "created session $start_session for the caller"
  else
    log "could not create session $start_session for the caller"
    return 1
  fi
}

# finish: create the caller's session (--start), drop the bootstrap session
# and run the worker post-restore.
finish() {
  local restored
  restored="$(other_session_count)"
  ensure_start_session || true
  kill_boot_session
  log "restore complete on server $pid: $restored session(s) (guarded restores run here: $attempts)"
  if [ "$restored" -gt 0 ]; then
    run_post_restore || exit 1
  fi
  exit 0
}

# start_without_restore: the server ($pid) was started for --start but there
# is no snapshot. Continuum's restore-on-start fires about a second after the
# config loads, finds no snapshot, and its guarded restore fails and leaves
# the incomplete-restore marker. Wait for that attempt (bounded), remove the
# marker (there is nothing for it to protect), then hand over the server.
start_without_restore() {
  local started=$SECONDS
  while [ $((SECONDS - started)) -lt "$CONTINUUM_WAIT" ]; do
    if restore_running; then
      wait_for_restore_to_finish || fail "guarded restore on server $pid did not finish within ${RESTORE_TIMEOUT}s"
      break
    fi
    [ -e "$restore_incomplete" ] && break
    sleep 0.2
  done
  if [ -e "$restore_incomplete" ]; then
    rm -f "$restore_incomplete" ||
      fail "cannot remove the incomplete-restore marker $restore_incomplete"
    log "removed $restore_incomplete: Continuum's restore found no snapshot, so there is nothing for it to protect"
  fi
  ensure_start_session || true
  kill_boot_session
  if "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
    log "started server $pid with no snapshot to restore"
    exit 0
  fi
  fail "server $pid exited before the caller's session was created"
}

# sweep_stale_markers <live server pid or ''>: remove incomplete-restore
# markers whose tmux server is gone. A marker is named after its server's
# pid; once that server has exited, no save or restore will ever read it
# again. A marker of the live server, or of any live tmux process (another
# -L server), stays. Looks in $TMPDIR, /tmp and the macOS per-user temp dir,
# or only in the colon-separated TMUX_RESURRECT_MARKER_DIRS (tests).
sweep_stale_markers() {
  local live="$1" dirs dir f p
  dirs="${TMUX_RESURRECT_MARKER_DIRS:-${TMPDIR:-/tmp}:/tmp:$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}"
  local IFS=:
  for dir in $dirs; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for f in "${dir%/}"/tmux-resurrect-*-restore-incomplete; do
      [ -e "$f" ] || continue
      p="${f##*/tmux-resurrect-}"
      p="${p%-restore-incomplete}"
      is_uint "$p" || continue
      [ "$p" != "$live" ] || continue
      if kill -0 "$p" 2>/dev/null && ps -p "$p" -o comm= 2>/dev/null | grep -q tmux; then
        continue
      fi
      rm -f "$f" 2>/dev/null && log "removed stale incomplete-restore marker $f (server pid $p is gone)"
    done
  done
}

# give_up <reason>: leave the server if a failed restore brought sessions
# back (the marker keeps saves off it; the doctor reports it), else let it
# exit so the next attempt starts clean.
give_up() {
  if [ "$(other_session_count)" -eq 0 ]; then
    kill_boot_session
  fi
  fail "$1"
}

# ---------------------------------------------------------------------------
# Live server.
# ---------------------------------------------------------------------------

sweep_stale_markers "$(server_pid || true)"

if "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
  pid="$(server_pid)" || fail "cannot resolve the tmux server pid"
  lifecycle_paths "$pid"
  if restore_running; then
    log "a guarded restore is running on server $pid; waiting"
    wait_for_restore_to_finish || fail "guarded restore on server $pid did not finish within ${RESTORE_TIMEOUT}s"
    [ -e "$restore_incomplete" ] || finish
  fi
  if [ "$(other_session_count)" -eq 0 ]; then
    # Only the bootstrap session: a restore that died before restoring
    # anything (or a wrapper killed mid-run). Restore again.
    log "server $pid holds only the bootstrap session; restoring"
    [ -e "$restore_incomplete" ] ||
      printf '%s\n' "boot restore pending by pid $$" >"$restore_incomplete" ||
      fail "cannot publish the incomplete-restore marker $restore_incomplete"
    restore_into_server 0 || give_up "guarded restore on server $pid did not complete; saves stay blocked by $restore_incomplete"
    finish
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
start_args=()
[ -f "$TMUX_CONF" ] && start_args=(-f "$TMUX_CONF")
if [ ! -e "$snapshot_dir/last" ]; then
  if [ -z "$start_session" ]; then
    log "no tmux server and no snapshot at $snapshot_dir/last; nothing to restore"
    exit 0
  fi
  log "no snapshot at $snapshot_dir/last; starting tmux server (config ${TMUX_CONF}) for session $start_session"
  "$TMUX_BIN" ${start_args[@]+"${start_args[@]}"} new-session -d -s "$BOOT_SESSION" -c "$HOME" ||
    fail "could not start the tmux server"
  pid="$(server_pid)" || fail "tmux server started but its pid is unreadable"
  lifecycle_paths "$pid"
  start_without_restore
fi
[ -x "$UPSTREAM_RESTORE" ] || fail "tmux-resurrect restore script is not executable: $UPSTREAM_RESTORE"
[ -f "$GUARDED_RESTORE" ] || fail "guarded restore not found: $GUARDED_RESTORE"

log "starting tmux server (config ${TMUX_CONF}) to restore $(readlink "$snapshot_dir/last" 2>/dev/null || echo last)"
# ${a[@]+...}: an empty array under `set -u` is an error in bash 3.2, which
# is what /usr/bin/env finds on launchd's PATH.
"$TMUX_BIN" ${start_args[@]+"${start_args[@]}"} new-session -d -s "$BOOT_SESSION" -c "$HOME" ||
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
  if [ -n "$start_session" ]; then
    log "no snapshot at $restore_dir_live/last (from @resurrect-dir); keeping the server for session $start_session"
    rm -f "$restore_incomplete" 2>/dev/null || true
    start_without_restore
  fi
  log "no snapshot at $restore_dir_live/last (from @resurrect-dir); stopping the bootstrap server"
  if [ "$(other_session_count)" -eq 0 ]; then
    kill_boot_session
    rm -f "$restore_incomplete" 2>/dev/null || true
  fi
  exit 0
fi

restore_into_server "$CONTINUUM_WAIT" ||
  give_up "guarded restore on server $pid did not complete; saves stay blocked by $restore_incomplete"
finish
