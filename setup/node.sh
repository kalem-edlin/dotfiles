#!/usr/bin/env bash

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup/lib.sh
. "$DOTFILES_DIR/setup/lib.sh"

# Put Homebrew/fnm on PATH if either is already present (e.g. fnm installed
# via Brewfile on macOS). Failure here is fine and expected on a completely
# clean Linux account — fnm genuinely isn't installed yet, that's exactly
# what this script is about to fix below. See
# docs/tasks/headless-install.md, "3. Fix the Linux first-run environment
# boundary".
activate_fnm || true

# Setup fnm. On macOS this is installed by Brewfile; on Linux it may need to
# bootstrap itself before npm globals can be installed.
if ! command -v fnm &> /dev/null; then
    echo "fnm not found; installing fnm..."
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
fi

if ! activate_fnm; then
    echo "Error: fnm not found after installation."
    exit 1
fi

# Install latest LTS Node
echo "Installing Node LTS..."
fnm install --lts
fnm default lts-latest
fnm use lts-latest

# Configure npm
npm config set loglevel warn
npm config set fund false

# Install global npm packages
echo "Installing global npm packages..."
packages=(
    @burneikis/pi-fzfp
    @burneikis/pi-vim
    @cometix/ccline
    @mariozechner/pi-coding-agent
    @openai/codex
    @sasazame/ccresume
    @vtsls/language-server
    bun
    ccexp
    eas-cli
    eslint
    happy-coder
    obsidian-headless
    pnpm
    pyright
    rembg
    serve
    tsx
    turbo
    typescript
    vercel
    vscode-langservers-extracted
    yarn
)

npm install -g "${packages[@]}"

bun install -g btca opencode-ai

echo "✓ Node LTS (via fnm) and global npm packages installed!"
