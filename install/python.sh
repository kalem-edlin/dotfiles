#!/bin/bash

# Setup pyenv (requires pyenv installed via brew)
eval "$(pyenv init -)"

# Install latest Python
echo "Installing Python latest..."
LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d ' ')
pyenv install -s "$LATEST_PYTHON"
pyenv global "$LATEST_PYTHON"

echo "✓ Python $LATEST_PYTHON installed!"

