#!/usr/bin/env bash
# Exclusive restore entrypoint shared by the manual binding and Continuum.
# Saves remain disabled until the upstream restore and all synchronous
# post-restore hooks have returned successfully.

set -u

TMUX_BIN="${TMUX_RESURRECT_RESTORE_TMUX_BIN:-tmux}"
PLUGIN_DIR="${TMUX_RESURRECT_RESTORE_PLUGIN_DIR:-$HOME/.config/tmux/plugins/tmux-resurrect}"
RESTORE_SCRIPT="$PLUGIN_DIR/scripts/restore.sh"
lock_dir=""
lock_owned=0
restore_incomplete=""
restore_succeeded=0
restore_result=""

# run-shell hides stderr, so a binding that sets TMUX_RESTORE_DIALOG=1 also
# gets the reason in the shared dialog. Continuum and tests keep stderr only.
fail() {
  printf 'tmux guarded restore: %s\n' "$1" >&2
  if [ "${TMUX_RESTORE_DIALOG:-}" = 1 ]; then
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dialog.sh" \
      --title "Tmux restore failed" -- "$1" 2>/dev/null || true
  fi
  exit 1
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

cleanup() {
  if [ "$restore_succeeded" -ne 1 ] && [ -n "$restore_incomplete" ]; then
    printf '%s\n' "restore started by pid $$ did not complete" >"$restore_incomplete" 2>/dev/null || true
  fi
  if [ "$lock_owned" -eq 1 ] && [ -n "$lock_dir" ]; then
    owner=""
    IFS= read -r owner <"$lock_dir/pid" || true
    if [ "$owner" = "$$" ]; then
      rm -f "$lock_dir/pid" "$lock_dir/started_at" "$lock_dir/kind" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
    fi
  fi
  [ -z "$restore_result" ] || rm -f "$restore_result" 2>/dev/null || true
}

[ "$#" -eq 0 ] || fail "this wrapper does not accept arguments"
command -v "$TMUX_BIN" >/dev/null 2>&1 || fail "tmux is not executable: $TMUX_BIN"
"$TMUX_BIN" list-sessions >/dev/null 2>&1 || fail "no tmux server with sessions is running"
[ -x "$RESTORE_SCRIPT" ] || fail "tmux-resurrect restore script is not executable: $RESTORE_SCRIPT"

server_pid="$("$TMUX_BIN" display-message -p '#{pid}' 2>/dev/null || true)"
is_uint "$server_pid" || fail "cannot resolve the tmux server pid"
lock_dir="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-verified-save.lock"
restore_incomplete="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-restore-incomplete"

# Restore never waits behind a save or another restore. Waiting would permit a
# user-requested restore to run later against a landscape that has changed.
if ! mkdir "$lock_dir" 2>/dev/null; then
  owner=""
  IFS= read -r owner <"$lock_dir/pid" || true
  if is_uint "$owner" && ! kill -0 "$owner" 2>/dev/null; then
    rm -f "$lock_dir/pid" "$lock_dir/started_at" "$lock_dir/kind" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    mkdir "$lock_dir" 2>/dev/null || fail "save or restore lifecycle operation is already active"
  else
    fail "save or restore lifecycle operation is already active"
  fi
fi

lock_owned=1
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" >"$lock_dir/pid" || fail "cannot record restore lock owner"
date +%s >"$lock_dir/started_at" || fail "cannot record restore start time"
printf '%s\n' restore >"$lock_dir/kind" || fail "cannot mark restore lock"

# This marker deliberately survives wrapper crashes and explicit upstream
# failures for this tmux server PID. A later successful guarded restore is the
# only operation that clears it.
printf '%s\n' "restore started by pid $$" >"$restore_incomplete" ||
  fail "cannot publish incomplete-restore guard"

# The upstream script does not propagate post-restore hook failures. Give the
# workspace hook a per-attempt result path so this wrapper can distinguish a
# complete restore from a swallowed hook failure or readiness timeout.
restore_result="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-restore-result.$$"
restore_attempt="${server_pid}-$$-$(date +%s)"
export TMUX_WORKSPACE_RESTORE_ATTEMPT="$restore_attempt"
export TMUX_WORKSPACE_RESTORE_RESULT_FILE="$restore_result"

if ! "$RESTORE_SCRIPT"; then
  fail "tmux-resurrect or a restore hook returned an error"
fi

[ "$(sed -n '1p' "$restore_result" 2>/dev/null || true)" = "success" ] ||
  fail "workspace post-restore did not report successful completion"

rm -f "$restore_incomplete" || fail "cannot clear incomplete-restore guard"
restore_succeeded=1
