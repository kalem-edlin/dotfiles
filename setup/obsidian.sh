#!/bin/bash

set -u

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup/lib.sh
. "$DOTFILES_DIR/setup/lib.sh"

# Activates fnm (Homebrew locations on macOS, ~/.local/share/fnm on Linux)
# if it's installed. Must work standalone (e.g. `make obsidian` run on its
# own) as well as immediately after setup/node.sh installed fnm+Node in a
# SEPARATE process on a completely clean Linux account — that's exactly the
# case that used to break here.
activate_fnm || true

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
