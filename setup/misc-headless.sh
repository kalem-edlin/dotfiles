#!/bin/bash

# Headless variant of misc.sh — skips GUI services, login items, and notifications.
# Used for Mac Mini server / agentic hub setup.

# Ensure Homebrew is in PATH (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

###############################################################################
# Oh My Zsh                                                                   #
###############################################################################

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Installing Oh My Zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
  echo "✓ Oh My Zsh installed!"
else
  echo "✓ Oh My Zsh already installed"
fi

###############################################################################
# SSH Key                                                                     #
###############################################################################

SSH_KEY="$HOME/.ssh/id_ed25519"

if [ ! -f "$SSH_KEY" ]; then
  echo "Generating SSH key..."
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh

  ssh-keygen -t ed25519 -C "$(git config user.email || echo 'user@machine')" -f "$SSH_KEY" -N ""

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

if ! xcode-select -p &> /dev/null; then
  echo "Installing Xcode Command Line Tools..."
  xcode-select --install &> /dev/null

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

###############################################################################
# Skipped for headless: SketchyBar, AeroSpace, Login Items, Notifier         #
###############################################################################

echo "⏭ Skipping SketchyBar (GUI)"
echo "⏭ Skipping AeroSpace (GUI)"
echo "⏭ Skipping Login Items (GUI)"
echo "⏭ Skipping Notifier (GUI)"

###############################################################################
# xcodemake                                                                   #
###############################################################################

echo "Configuring xcodemake..."

if [ ! -f /usr/local/bin/xcodemake ]; then
  curl -O https://raw.githubusercontent.com/johnno1962/xcodemake/main/xcodemake

  chmod +x xcodemake
  sudo mv xcodemake /usr/local/bin/

  echo "✓ xcodemake configured!"
else
  echo "✓ xcodemake already exists"
fi

###############################################################################
# Claude Code                                                                 #
###############################################################################

if [ "${SKIP_CLAUDE_CODE:-}" = "1" ]; then
  echo "⏭ Skipping Claude Code installation (SKIP_CLAUDE_CODE=1)"
elif ! command -v claude &> /dev/null; then
  echo "Installing Claude Code..."
  echo "  → Downloading Claude Code installer..."
  TEMP_SCRIPT=$(mktemp)

  if curl -fsSL https://claude.ai/install.sh -o "$TEMP_SCRIPT" 2>&1; then
    if [ -s "$TEMP_SCRIPT" ]; then
      echo "  → Running Claude Code installer..."
      bash "$TEMP_SCRIPT" || {
        echo "⚠ Claude Code installation failed or was cancelled"
        rm -f "$TEMP_SCRIPT"
      }
      rm -f "$TEMP_SCRIPT"

      if command -v claude &> /dev/null; then
        echo "✓ Claude Code installed!"
      else
        echo "⚠ Claude Code installer completed but 'claude' command not found"
      fi
    else
      echo "⚠ Claude Code installer script appears to be empty"
      rm -f "$TEMP_SCRIPT"
    fi
  else
    echo "⚠ Failed to download Claude Code installer"
    rm -f "$TEMP_SCRIPT"
  fi
else
  echo "✓ Claude Code already installed"
fi


echo ""
echo "✓ Headless misc setup complete!"
