#!/bin/bash

# Ensure Homebrew is in PATH (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Miscellaneous setup tasks

###############################################################################
# SSH Key                                                                     #
###############################################################################

SSH_KEY="$HOME/.ssh/id_ed25519"

if [ ! -f "$SSH_KEY" ]; then
  echo "Generating SSH key..."
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  
  # Generate Ed25519 key (more secure and shorter than RSA)
  ssh-keygen -t ed25519 -C "$(git config user.email || echo 'user@machine')" -f "$SSH_KEY" -N ""
  
  # Start ssh-agent and add key to keychain
  eval "$(ssh-agent -s)"
  ssh-add --apple-use-keychain "$SSH_KEY"
  
  echo "✓ SSH key generated!"
  echo ""
  echo "  Add this public key to GitHub/GitLab:"
  echo ""
  cat "${SSH_KEY}.pub"
  echo ""
else
  echo "✓ SSH key already exists"
fi

###############################################################################
# Xcode Command Line Tools                                                    #
###############################################################################

# Install Xcode Command Line Tools (required for git, compilers, etc.)
if ! xcode-select -p &> /dev/null; then
  echo "Installing Xcode Command Line Tools..."
  xcode-select --install &> /dev/null

  # Wait until the Xcode Command Line Tools are installed
  until xcode-select -p &> /dev/null; do
    sleep 5
  done

  echo "✓ Xcode Command Line Tools installed!"
else
  echo "✓ Xcode Command Line Tools already installed"
fi

###############################################################################
# GitHub CLI                                                                  #
###############################################################################

# Authenticate GitHub CLI
if command -v gh &> /dev/null; then
  if ! gh auth status &> /dev/null; then
    echo ""
    echo "GitHub CLI: Logging in..."
    gh auth login
  else
    echo "✓ GitHub CLI authenticated"
  fi
else
  echo "⚠ GitHub CLI (gh) not installed"
fi

echo ""
echo "✓ Misc setup complete!"

