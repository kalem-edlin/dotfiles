#!/usr/bin/env bash
# Run after TPM: replace tmux-resurrect's direct save/restore paths and the
# user-facing bindings with guarded local wrappers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmux set-option -gq @resurrect-save-script-path "$SCRIPT_DIR/resurrect_save.sh"
tmux set-option -gq @resurrect-restore-script-path "$SCRIPT_DIR/resurrect_restore.sh"
# Every binding below ends in `|| true`: run-shell opens view mode on a
# non-zero exit, which takes over the pane after the dialog already showed
# the problem. Restores pass TMUX_RESTORE_DIALOG=1 so failures use the dialog.
tmux bind-key C-s run-shell "bash '$SCRIPT_DIR/manual_resurrect_save.sh' '#{@remote-host}' '#{pane_id}' || true"
tmux bind-key C-M-r confirm-before -p "Restore last tmux snapshot over the LIVE landscape? (y/n)" \
  "run-shell 'TMUX_RESTORE_DIALOG=1 bash $SCRIPT_DIR/resurrect_restore.sh || true'"
tmux bind-key M-F11 run-shell "TMUX_RESTORE_DIALOG=1 bash '$SCRIPT_DIR/resurrect_restore.sh' || true"
