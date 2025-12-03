#!/bin/bash

# Setup fnm (requires fnm installed via brew)
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
    @anthropic-ai/claude-code
    @cometix/ccline
    bun
    eas-cli
    pnpm
    rembg
    serve
    tsx
    turbo
    vercel
    yarn
)

npm install -g "${packages[@]}"

echo "✓ Node LTS (via fnm) and global npm packages installed!"

