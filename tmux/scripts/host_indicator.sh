#!/usr/bin/env bash
# Outputs hostname with a color derived from the machine name.
# Used in tmux status bar to visually distinguish machines.

hostname=$(hostname -s | tr '[:upper:]' '[:lower:]')

# Hash the hostname to pick a tmux colour (from the 256-color palette)
# Reserve light blue (colour117) for the local dev machine
case "$hostname" in
  kalem*|kalemedlin*|Kalem*) color="colour117" ;;
  *)
    hash=$(printf '%s' "$hostname" | cksum | awk '{print $1}')
    # Pick from a curated set of distinct, readable colors (avoiding dark/muddy ones)
    colors=(colour209 colour114 colour175 colour216 colour147 colour180 colour109 colour218 colour150 colour167)
    idx=$(( hash % ${#colors[@]} ))
    color="${colors[$idx]}"
    ;;
esac

printf "#[fg=%s]%s" "$color" "$hostname"
