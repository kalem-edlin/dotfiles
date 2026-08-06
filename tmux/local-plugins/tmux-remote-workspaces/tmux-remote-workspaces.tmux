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
#
# NOTE: session_id/session_name/@session-uuid are fetched with one
# single-field `-F` call each rather than a TAB-joined `list-sessions -F`
# format, because tmux (observed: Homebrew 3.7b) sanitizes control
# characters -- including TAB -- to `_` in command output. That silently
# collapses a delimited multi-field record into one field and corrupts the
# split (see tmux-workspace-resurrect/scripts/save.sh for the incident this
# mirrors). A single #{...} format has nothing to delimit, so it's immune.
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  suuid="$(tmux show-option -t "$sid" -qv @session-uuid 2>/dev/null || true)"
  [ -n "$suuid" ] && continue
  sname="$(tmux display-message -t "$sid" -F '#{session_name}' 2>/dev/null || true)"
  bash "$PLUGIN_DIR/scripts/session-created-hook.sh" "$sid" "$sname"
done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null || true)

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

# Same wrap for the directory chip: a focused remote-backed pane shows its
# LIVE remote cwd, local panes keep the existing local format. The live cwd
# arrives with no ssh round-trips: endpoint sessions are created with
# set-titles on + set-titles-string '#{pane_current_path}' (see
# rw_create_remote_session in scripts/common.sh), so the worker-side tmux
# pushes its pane_current_path through the ssh tty as an OSC 0 title and the
# local pane's #{pane_title} tracks it. The m:/* guard only trusts a title
# that looks like an absolute path (programs freely overwrite titles with
# arbitrary text); anything else falls back to the static workspace root
# (@rw-workspace, pane-scoped cache).
# Format nesting note: #{b:...} silently no-ops over a nested #{?...}
# conditional, so the conditional must be OUTERMOST with a plain
# #{=/17/…:#{b:var}} in each branch (that nesting is verified working).
existing_dir_text="$(tmux show-option -gqv @catppuccin_directory_text 2>/dev/null || true)"
rw_dir_fmt="#{?#{m:/*,#{pane_title}},#{=/17/…:#{b:pane_title}},#{=/17/…:#{b:@rw-workspace}}}"
case "$existing_dir_text" in
  *'@rw-workspace'*) : ;; # already wrapped -- don't nest again
  *)
    tmux set-option -gq @catppuccin_directory_text "#{?@rw-workspace,${rw_dir_fmt},${existing_dir_text}}"
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

# --- Copy-mode forwarding for remote-backed panes ---------------------------
# A remote-backed pane is an ssh-attached worker tmux client on the outer
# pane's alternate screen, so local copy-mode ([ / PPage) scrolls the outer
# pane's pre-attach scrollback (rw ensure output and older), not the worker
# pane's real history. Endpoint sessions run with `prefix None` (the inner
# tmux is a headless display layer), so a forwarded prefix sequence would
# just be typed into the remote program -- instead rw-copy-mode.sh enters
# copy-mode server-side over ssh (`tmux copy-mode -t <session>`). Once the
# inner pane is in copy-mode, every subsequent keystroke (vi motions,
# search, y, q) already flows through the ssh tty into that mode, so entry
# is the only round trip. Yank returns to the local clipboard via OSC 52
# passthrough (allow-passthrough on). Local panes (no @rw-workspace) keep
# stock behavior. prefix ] deliberately NOT forwarded: local paste-buffer
# types the LOCAL buffer into the remote program, the useful direction.
tmux bind-key '[' if-shell -F '#{@rw-workspace}' \
  "run-shell \"bash '$PLUGIN_DIR/scripts/rw-copy-mode.sh' '#{pane_id}'\"" \
  'copy-mode'
tmux bind-key PPage if-shell -F '#{@rw-workspace}' \
  "run-shell \"bash '$PLUGIN_DIR/scripts/rw-copy-mode.sh' '#{pane_id}' --page-up\"" \
  'copy-mode -u'
