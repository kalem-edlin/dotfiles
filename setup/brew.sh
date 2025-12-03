#!/bin/bash

# Install Homebrew (skip if already installed)
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Update Homebrew
brew update

# Install everything from Brewfile
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
brew bundle --file="$DOTFILES_DIR/Brewfile"

echo "✓ Homebrew packages installed!"
