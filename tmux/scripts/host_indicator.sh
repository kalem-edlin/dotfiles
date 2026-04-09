#!/usr/bin/env bash
# Sets tmux catppuccin host module options with a color derived from hostname.
# Called via `run` in tmux.conf before TPM loads.

hostname=$(hostname -s | tr '[:upper:]' '[:lower:]')

case "$hostname" in
  kalem*|kalemedlin*) color="#89b4fa" ;;  # catppuccin blue (light baby blue)
  *)
    hash=$(printf '%s' "$hostname" | cksum | awk '{print $1}')
    colors=("#fab387" "#a6e3a1" "#f5c2e7" "#f9e2af" "#b4befe" "#f2cdcd" "#94e2d5" "#f5e0dc" "#a6d189" "#eba0ac")
    idx=$(( hash % ${#colors[@]} ))
    color="${colors[$idx]}"
    ;;
esac

tmux set -g @catppuccin_host_color "$color"
tmux set -g @catppuccin_host_icon "󰍹"
tmux set -g @catppuccin_host_text "$hostname"
