#!/usr/bin/env bash
# Idempotently PREPENDS the autosave-freshness chip to status-right, so it
# renders to the LEFT of catppuccin's directory/host chips.
#
# Invoked via `run-shell` in tmux.conf AFTER the TPM line, so catppuccin and
# tmux-continuum have already finished rewriting/prepending to status-right
# (continuum's own add_resurrect_save_interpolation does the same
# prepend-if-absent operation -- see
# ~/.config/tmux/plugins/tmux-continuum/scripts/helpers.sh).
#
# Any existing copy is stripped before prepending rather than short-
# circuiting on "already present". That keeps repeated `source-file` calls
# from stacking duplicates AND migrates the chip to the front for anyone who
# already loaded the earlier version that appended it to the end.

set -u

# tmux format-expands the #() command line in status-line (active pane)
# context BEFORE running it, so #{@rw-worker} arrives as $1: empty for a
# local pane, the worker alias for a remote-backed one. The script then
# renders local or remote autosave freshness accordingly.
interp="#(~/.config/tmux/scripts/autosave_indicator.sh '#{@rw-worker}')"
# Pre-worker-argument form; still present in status-right on live servers
# that loaded the earlier version, so it must be stripped too or a reload
# would stack both chips.
legacy_interp="#(~/.config/tmux/scripts/autosave_indicator.sh)"
current="$(tmux show-option -gqv status-right 2>/dev/null)" || exit 0

# Strip every existing occurrence of either form (bash 3.2-safe: no
# ${var//find/replace} with a variable pattern containing glob
# metacharacters).
stripped="$current"
while :; do
  case "$stripped" in
    *"$interp"*)
      stripped="${stripped%%"$interp"*}${stripped#*"$interp"}"
      ;;
    *"$legacy_interp"*)
      stripped="${stripped%%"$legacy_interp"*}${stripped#*"$legacy_interp"}"
      ;;
    *) break ;;
  esac
done

tmux set-option -gq status-right "${interp}${stripped}"
