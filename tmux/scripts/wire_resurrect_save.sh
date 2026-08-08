#!/usr/bin/env bash
# Run after TPM: replace tmux-resurrect's direct C-s binding and save path
# with the verified local/remote-aware wrappers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmux set-option -gq @resurrect-save-script-path "$SCRIPT_DIR/resurrect_save.sh"
tmux bind-key C-s run-shell "bash '$SCRIPT_DIR/manual_resurrect_save.sh' '#{@rw-worker}'"

