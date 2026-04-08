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
if [ "${BREWFILE_HEADLESS:-}" = "1" ]; then
  echo "Using headless Brewfile (CLI tools only)..."
  brew bundle --file="$DOTFILES_DIR/Brewfile.headless"
else
  brew bundle --file="$DOTFILES_DIR/Brewfile"
fi

# Post-install steps
echo "Linking libpq..."
brew link --force libpq 2>/dev/null || true

echo "✓ Homebrew packages installed!"
