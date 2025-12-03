#!/bin/bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup pyenv (requires pyenv installed via brew)
eval "$(pyenv init -)"

# Install latest Python
echo "Installing Python latest..."
LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d ' ')
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

# Install useful system-wide CLI tools
pipx install httpie  # Better curl for API testing
echo "✓ pipx configured!"

