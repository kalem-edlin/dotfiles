#!/bin/bash

set -u

if [[ -f /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

if command -v fnm &> /dev/null; then
  eval "$(fnm env --use-on-cd --shell bash)"
fi

echo "Configuring Obsidian Headless..."

# Vault login, sync setup, and local vault paths are user/runtime-owned.
# This script only verifies the headless CLI is available.
if command -v ob &> /dev/null; then
  echo "✓ Obsidian Headless installed: $(command -v ob)"
  ob --version
else
  echo "⚠ Obsidian Headless not found. Run 'make node' to install obsidian-headless."
  exit 1
fi

echo "✓ Obsidian Headless configured"
