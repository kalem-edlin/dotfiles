#!/usr/bin/env bash
# Entry point for the tmux-remote-workspaces local plugin. Loaded manually
# from tmux.conf (not TPM-managed -- this package lives inside the dotfiles
# repo already), after host_indicator.sh and after tmux-workspace-resurrect,
# before TPM starts the themed plugins.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$PLUGIN_DIR/config.json"

if ! command -v jq >/dev/null 2>&1 || ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
  tmux display-message "tmux-remote-workspaces: config.json is invalid or jq is unavailable"
  exit 0
fi

# --- Stable session UUIDs --------------------------------------------------
# session-created hook: assign a UUID to every newly created session and
# register it in sessions.jsonl (authoritative; @session-uuid is cache only
# and does not survive a server restart).
tmux set-hook -g session-created \
  "run-shell \"bash '$PLUGIN_DIR/scripts/session-created-hook.sh' '#{session_id}' '#{session_name}'\""

# Backfill already-running sessions at plugin load (covers `prefix C-r`
# config reloads and the very first load against pre-existing sessions).
while IFS=$'\t' read -r sid sname suuid; do
  [ -n "$sid" ] || continue
  [ -n "$suuid" ] && continue
  bash "$PLUGIN_DIR/scripts/session-created-hook.sh" "$sid" "$sname"
done < <(tmux list-sessions -F '#{session_id}	#{session_name}	#{@session-uuid}' 2>/dev/null || true)

# --- Per-pane remote-host status line --------------------------------------
# host_indicator.sh (tmux/scripts/host_indicator.sh) sets a single
# server-wide @catppuccin_host_text value at load time, before this plugin
# runs. Extend it minimally into a live format string: a focused remote pane
# shows its worker, local panes keep falling back to whatever
# host_indicator.sh already computed. @remote-host is a pane-scoped cache set
# by rw-ensure.sh/attach-loop.sh; format specifiers with no explicit target
# resolve against the client's active pane, which is exactly the "focused
# pane" semantics required here.
existing_host_text="$(tmux show-option -gqv @catppuccin_host_text 2>/dev/null || true)"
case "$existing_host_text" in
  *'#{@remote-host}'*) : ;; # already wrapped (e.g. config reload) -- don't nest again
  *)
    tmux set-option -gq @catppuccin_host_text "#{?@remote-host,#{@remote-host},${existing_host_text}}"
    ;;
esac

# --- Post-restore re-establishment and reconciliation ----------------------
# Chained onto the SAME @resurrect-hook-post-restore-all option
# tmux-workspace-resurrect.tmux already appended its own restore.sh to --
# this plugin loads after that one (see the file-level comment above), so
# that append has already happened by the time this runs. Appending (never
# replacing) is the same multi-consumer pattern tmux-workspace-resurrect
# itself uses for its own post-save-all/post-restore-all hooks -- duplicated
# here deliberately rather than sourced cross-plugin, matching the "sibling
# consumer, not a fork" relationship described in initial-plan.md's
# "Configuration and extensibility" section.
#
# Order matters: rw-post-restore.sh (session-UUID re-resolution + pane
# re-establishment) runs first, then libexec/reconcile (orphan disposal)
# -- matching the order Phase 2 lists them in ("Reattach remembered
# endpoints on laptop restore... Reconcile and close owned remote
# endpoints..."). Both are independently safe regardless of order (neither
# closes an endpoint the other one just touched), but running
# re-establishment first means a freshly-set @rw-* pane cache and a
# respawned attach-loop.sh are already in place by the time reconciliation
# (and anyone glancing at the pane) runs.
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

append_resurrect_hook "post-restore-all" "bash '$PLUGIN_DIR/scripts/rw-post-restore.sh'"
append_resurrect_hook "post-restore-all" "bash '$PLUGIN_DIR/libexec/reconcile'"

# --- doctor -----------------------------------------------------------------
# CLI only this wave (see README.md); no new keybinding is added to avoid
# widening the keymap changes beyond what initial-plan.md's BEHAVIOR list
# requires (prefix+q and the \ / split bindings, both wired from
# tmux.reset.conf directly).
