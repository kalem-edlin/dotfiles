#!/usr/bin/env bash
# Idempotently PREPENDS the autosave-freshness chip to status-right, so it
# renders to the LEFT of catppuccin's directory/host chips.
#
# Invoked via `run-shell` in tmux.conf AFTER the TPM line, so catppuccin and
# tmux-continuum have already finished rewriting/prepending to status-right
# (continuum's own add_resurrect_save_interpolation does the same
# append-if-absent dance -- see
# ~/.config/tmux/plugins/tmux-continuum/scripts/helpers.sh).
#
# Any existing copy is stripped before prepending rather than short-
# circuiting on "already present". That keeps repeated `source-file` calls
# from stacking duplicates AND migrates the chip to the front for anyone who
# already loaded the earlier version that appended it to the end.

set -u

interp="#(~/.config/tmux/scripts/autosave_indicator.sh)"
current="$(tmux show-option -gqv status-right 2>/dev/null)" || exit 0

# Strip every existing occurrence (bash 3.2-safe: no ${var//find/replace}
# with a variable pattern containing glob metacharacters).
stripped="$current"
while :; do
  case "$stripped" in
    *"$interp"*)
      stripped="${stripped%%"$interp"*}${stripped#*"$interp"}"
      ;;
    *) break ;;
  esac
done

tmux set-option -gq status-right "${interp}${stripped}"
