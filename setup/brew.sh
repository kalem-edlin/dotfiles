#!/bin/bash

# Install Homebrew (skip if already installed)
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Ensure Homebrew is in PATH for this session (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Update Homebrew
brew update

# Install everything from Brewfile
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
brew bundle --file="$DOTFILES_DIR/Brewfile"

echo "✓ Homebrew packages installed!"
