#!/bin/bash

# Ensure Homebrew is in PATH (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Setup fnm (requires fnm installed via brew)
if ! command -v fnm &> /dev/null; then
    echo "Error: fnm not found. Run 'make brew' first."
    exit 1
fi
eval "$(fnm env --use-on-cd --shell bash)"

# Install latest LTS Node
echo "Installing Node LTS..."
fnm install --lts
fnm default lts-latest

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

