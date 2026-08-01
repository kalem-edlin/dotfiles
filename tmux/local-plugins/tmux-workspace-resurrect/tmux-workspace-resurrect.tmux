#!/usr/bin/env bash

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$PLUGIN_DIR/config.json"

if ! command -v jq >/dev/null 2>&1 || ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
  tmux display-message "tmux-workspace-resurrect: config.json is invalid or jq is unavailable"
  exit 0
fi

autosave_interval="$(jq -er '.autosave_interval_minutes | numbers' "$CONFIG_FILE" 2>/dev/null || echo 5)"
restore_mode="$(jq -er '.restore_mode | strings' "$CONFIG_FILE" 2>/dev/null || echo queue)"

tmux set-option -gq @continuum-save-interval "$autosave_interval"
tmux set-option -gq @continuum-restore "on"
tmux set-option -gq @resurrect-processes "false"
tmux set-option -gq @workspace-resurrect-config "$CONFIG_FILE"
tmux set-option -gq @workspace-resurrect-restore-mode "$restore_mode"

append_resurrect_hook() {
  local hook_name="$1"
  local command="$2"
  local option="@resurrect-hook-${hook_name}"
  local existing

  existing="$(tmux show-option -gqv "$option")"
  case "; $existing; " in
    *"; $command; "*) return ;;
  esac

  if [ -n "$existing" ]; then
    tmux set-option -gq "$option" "$existing; $command"
  else
    tmux set-option -gq "$option" "$command"
  fi
}

append_resurrect_hook "post-save-all" "bash '$PLUGIN_DIR/scripts/save.sh'"
append_resurrect_hook "post-restore-all" "bash '$PLUGIN_DIR/scripts/restore.sh'"

tmux bind-key C-g run-shell "bash '$PLUGIN_DIR/scripts/doctor.sh'"

# Best-effort immediate save when a client cleanly detaches. This is an
# optimization on top of, NOT a substitute for, the direct periodic save
# timer that setup-headless installs on workers (launchd on macOS, a
# systemd --user timer on Linux; see
# setup/templates/tmux-resurrect-save.sh). That timer is the correctness
# net: it is the only thing that saves a fully detached worker server at
# all, since tmux-continuum's autosave never fires without a client
# rendering the status line. This hook only shaves the gap between "client
# detaches" and "the next periodic tick" for the ordinary clean-detach case.
# It is known to NOT fire on signal-based client termination
# (https://github.com/tmux/tmux/issues/1174); behavior on an abrupt
# SSH/TCP drop, as opposed to a clean `detach-client`, is unverified.
# Failures here are guarded to stay silent — this must never surface an
# error to a detaching user.
tmux set-hook -g client-detached \
  "run-shell -b \"bash '$PLUGIN_DIR/../../plugins/tmux-resurrect/scripts/save.sh' quiet >/dev/null 2>&1 || true\""
