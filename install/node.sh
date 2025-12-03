#!/bin/bash

# Setup nvm (requires nvm installed via brew)
mkdir -p ~/.nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$(brew --prefix)/opt/nvm/nvm.sh" ] && \. "$(brew --prefix)/opt/nvm/nvm.sh"

# Install latest LTS Node
echo "Installing Node LTS..."
nvm install --lts
nvm alias default 'lts/*'

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

echo "✓ Node LTS and global npm packages installed!"

