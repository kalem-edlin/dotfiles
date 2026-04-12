#!/usr/bin/env bash
# Clipboard handler for tmux yank — works locally (pbcopy) and over SSH (OSC 52)
# Used as tmux copy-pipe command

input=$(cat)

if [ -n "$SSH_TTY" ]; then
  # Over SSH: send OSC 52 wrapped in DCS passthrough for tmux
  encoded=$(printf '%s' "$input" | base64 | tr -d '\n')
  # Use current tty (SSH_TTY can go stale after tmux restarts)
  target=$(tty)
  [ "$target" = "not a tty" ] && target="$SSH_TTY"
  printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$encoded" > "$target"
else
  # Local: use pbcopy
  printf '%s' "$input" | pbcopy
fi
