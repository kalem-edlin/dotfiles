#!/usr/bin/env bash
# Reconcile display-only metadata with what is really running.
#
#   (no args)    every pane's @remote-host / @workspace-resurrect-skip, then
#                the transfer options below (plugin load)
#   --transfers  only the background-transfer options (libexec/rw-bg calls
#                this when a transfer starts and when it ends)
#
# Panes: endpoint intent may outlive or precede attachment; host/directory
# chips and workspace-resurrect skipping must only activate while
# attach-loop.sh really owns the local pane's process tree.
#
# Transfers: every bg/<root_id>/ job whose runner is alive sets the global
# options
#   @rw-transfer        "handoff <root_rel>" / "handback <root_rel>", several
#                       joined with ", "
#   @rw-transfer-label  the chip text: "handing off <name>…", "handing back
#                       <name>…", or "<n> transfers…"
# and both are unset when none runs. While one runs, a chip that shows the
# label (and renders empty without it) is prepended to status-right once;
# it is a plain format, so it appears and disappears with the option,
# without waiting for status-interval.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# catppuccin mocha, as tmux/scripts/autosave_indicator.sh: yellow icon, gray
# text cell, the theme's own status separators. Commas inside the
# conditional are escaped (#,).
RW_TRANSFER_CHIP='#{?@rw-transfer-label,#[fg=#f9e2af#,bg=#1e1e2e]#{@catppuccin_status_left_separator}#[fg=#1e1e2e#,bg=#f9e2af]⇄ #[fg=#cdd6f4#,bg=#313244] #{@rw-transfer-label}#[fg=#313244#,bg=#1e1e2e]#{@catppuccin_status_right_separator},}'

wire_transfer_chip() {
  local current
  current="$(tmux show-option -gqv status-right 2>/dev/null)" || return 0
  case "$current" in *"$RW_TRANSFER_CHIP"*) return 0 ;; esac
  tmux set-option -gq status-right "${RW_TRANSFER_CHIP}${current}"
}

refresh_transfers() {
  local dir job pid verb rel n=0 list="" label=""
  dir="$(rw_bg_dir)"
  for job in "$dir"/*; do
    [ -f "$job/job.json" ] || continue
    pid="$(cat "$job/pid" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      [ -n "$pid" ] && rm -rf "$job" # a runner that died without cleaning up
      continue
    fi
    verb="$(jq -r '.verb // empty' "$job/job.json" 2>/dev/null)"
    rel="$(jq -r '.root_rel // empty' "$job/job.json" 2>/dev/null)"
    [ -n "$verb" ] && [ -n "$rel" ] || continue
    n=$((n + 1))
    list="${list:+$list, }$verb $rel"
    case "$verb" in
      handoff) label="handing off ${rel##*/}…" ;;
      *) label="handing back ${rel##*/}…" ;;
    esac
  done
  if [ "$n" -eq 0 ]; then
    tmux set-option -gqu @rw-transfer 2>/dev/null || true
    tmux set-option -gqu @rw-transfer-label 2>/dev/null || true
    return 0
  fi
  [ "$n" -eq 1 ] || label="$n transfers…"
  tmux set-option -gq @rw-transfer "$list" 2>/dev/null || true
  tmux set-option -gq @rw-transfer-label "$label" 2>/dev/null || true
  wire_transfer_chip
}

if [ "${1:-}" = "--transfers" ]; then
  refresh_transfers
  exit 0
fi

processes="$(ps axo pid=,ppid=,command= 2>/dev/null || true)"
while IFS= read -r pane_id; do
  [ -n "$pane_id" ] || continue
  pane_pid="$(tmux display-message -pt "$pane_id" -F '#{pane_pid}' 2>/dev/null || true)"
  worker="$(rw_pane_get "$pane_id" @rw-worker)"
  if [ -n "$pane_pid" ] && [ -n "$worker" ] &&
    printf '%s\n' "$processes" |
      rw_ps_tree_matches '(^|/)attach-loop\.sh([[:space:]]|$)' "$pane_pid"; then
    rw_pane_set "$pane_id" @remote-host "$worker"
    rw_pane_set "$pane_id" @workspace-resurrect-skip "1"
  else
    rw_pane_unset "$pane_id" @remote-host
    rw_pane_unset "$pane_id" @workspace-resurrect-skip
  fi
done < <(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || true)

refresh_transfers
