#!/usr/bin/env bash

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure Homebrew is in PATH (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Setup pyenv. On macOS this is installed by Brewfile; on Linux it may need to
# bootstrap itself after build dependencies are installed.
if ! command -v pyenv &> /dev/null; then
    echo "pyenv not found; installing pyenv..."
    curl -fsSL https://pyenv.run | bash
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
fi

if ! command -v pyenv &> /dev/null; then
    echo "Error: pyenv not found after installation."
    exit 1
fi

eval "$(pyenv init -)"

# Install latest stable Python 3.11.x (excludes release candidates, betas, and alphas)
echo "Installing latest stable Python 3.11..."
LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*3\.11\.[0-9]+$' | grep -v -E '(rc|b|a|dev)' | tail -1 | tr -d ' ')
pyenv install -s "$LATEST_PYTHON"
pyenv global "$LATEST_PYTHON"
echo "✓ Python $LATEST_PYTHON installed!"

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip

# Install system-wide libraries
echo "Installing system-wide Python libraries..."
pip install -r "$DOTFILES_DIR/requirements.txt"
echo "✓ System-wide libraries installed!"

# Setup pipx for isolated CLI tools
echo "Setting up pipx..."
pipx ensurepath

# Install useful system-wide CLI tools (idempotent: skip/upgrade if already
# installed so reruns don't fail on an already-provisioned worker)
if pipx list --short 2>/dev/null | grep -q '^httpie '; then
    echo "httpie already installed via pipx; upgrading..."
    pipx upgrade httpie
else
    echo "Installing httpie via pipx..."
    pipx install httpie  # Better curl for API testing
fi
echo "✓ pipx configured!"
