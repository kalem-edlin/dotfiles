#!/usr/bin/env bash

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup/lib.sh
. "$DOTFILES_DIR/setup/lib.sh"

# Put Homebrew/fnm on PATH if either is already present (e.g. fnm installed
# via Brewfile on macOS). Failure here is fine and expected on a completely
# clean Linux account — fnm genuinely isn't installed yet, that's exactly
# what this script is about to fix below.
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

# Pinned Node, the same on every machine (laptop and workers). Move it
# deliberately, on every machine at once, together with the globals below.
NODE_VERSION=24.18.0
echo "Installing Node $NODE_VERSION..."
fnm install "$NODE_VERSION"
fnm default "$NODE_VERSION"
fnm use "$NODE_VERSION"

# Configure npm
npm config set loglevel warn
npm config set fund false

# Retired globals. Pi moved from @mariozechner/pi-coding-agent (frozen at
# 0.73.1) to @earendil-works/pi-coding-agent; both ship a `pi` bin, so npm
# refuses the new one while the old one is installed. Codex is no longer used.
for retired in @mariozechner/pi-coding-agent @openai/codex; do
    if npm ls -g --depth=0 "$retired" >/dev/null 2>&1; then
        echo "Removing the retired $retired..."
        npm uninstall -g "$retired"
    fi
done

# Global npm packages, pinned so every machine runs the same versions. The
# pi pin matters most: the pif extensions are written against it, and rw's
# pi adapter compares focus and worker versions. To bump one, change it here
# and rerun `make node` on every machine.
PI_VERSION=0.85.1
echo "Installing global npm packages..."
packages=(
    @burneikis/pi-fzfp@2.4.0
    @burneikis/pi-vim@1.7.0
    @cometix/ccline@1.1.2
    "@earendil-works/pi-coding-agent@$PI_VERSION"
    @mermaid-js/mermaid-cli@11.17.0
    @sasazame/ccresume@2.0.0
    @tavily/cli@1.0.1
    @vtsls/language-server@0.3.0
    agent-browser@0.31.1
    bun@1.3.14
    ccexp@4.0.0
    eas-cli@24.13.0
    eslint@10.5.0
    figma-use@0.13.5
    happy-coder@1.1.9
    obsidian-headless@0.0.12
    oxfmt@0.72.0
    pnpm@11.9.0
    pyright@1.1.411
    rembg@1.0.6
    serve@14.2.6
    tsx@4.22.4
    turbo@2.10.0
    typescript@6.0.3
    vercel@54.17.3
    vscode-langservers-extracted@4.10.0
    yarn@1.22.22
)

npm install -g "${packages[@]}"

bun install -g btca opencode-ai

echo "✓ Node $NODE_VERSION (via fnm) and global npm packages installed!"
