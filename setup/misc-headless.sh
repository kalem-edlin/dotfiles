#!/usr/bin/env bash

set -u

# Headless variant of misc.sh — skips GUI services, login items, and notifications.
# Used for Mac Mini server / agentic hub setup and Linux SSH hosts.

OS_NAME="$(uname -s)"
SETUP_USER="${SUDO_USER:-${USER:-$(id -un)}}"

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

if command -v zsh &> /dev/null; then
  ZSH_PATH="$(command -v zsh)"
  if [[ "${SHELL:-}" != "$ZSH_PATH" ]] && command -v chsh &> /dev/null; then
    echo "Setting zsh as the login shell..."
    if [[ "$OS_NAME" = "Darwin" ]]; then
      grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
      chsh -s "$ZSH_PATH" "$SETUP_USER" 2>/dev/null || echo "⚠ Could not change shell automatically; run: chsh -s $ZSH_PATH"
    elif command -v sudo &> /dev/null; then
      sudo chsh -s "$ZSH_PATH" "$SETUP_USER" 2>/dev/null || echo "⚠ Could not change shell automatically; run: chsh -s $ZSH_PATH"
    else
      chsh -s "$ZSH_PATH" "$SETUP_USER" 2>/dev/null || echo "⚠ Could not change shell automatically; run: chsh -s $ZSH_PATH"
    fi
  fi
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
  if [[ "$OS_NAME" = "Darwin" ]]; then
    ssh-add --apple-use-keychain "$SSH_KEY"
  else
    ssh-add "$SSH_KEY"
  fi

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
# Platform build tools                                                        #
###############################################################################

if [[ "$OS_NAME" = "Darwin" ]]; then
  if ! xcode-select -p &> /dev/null; then
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install &> /dev/null

    until xcode-select -p &> /dev/null; do
      sleep 5
    done

    echo "✓ Xcode Command Line Tools installed!"
  else
    # Check if tools are outdated by verifying pkgutil receipt matches available OS
    CLT_VERSION=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | grep version | awk '{print $2}')
    OS_VERSION=$(sw_vers -productVersion)
    OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

    if [ -n "$CLT_VERSION" ]; then
      CLT_MAJOR=$(echo "$CLT_VERSION" | cut -d. -f1)
      if [ "$CLT_MAJOR" -lt "$OS_MAJOR" ]; then
        echo "Xcode Command Line Tools are outdated (v$CLT_VERSION for macOS $OS_VERSION). Reinstalling..."
        sudo rm -rf /Library/Developer/CommandLineTools
        xcode-select --install &> /dev/null

        until xcode-select -p &> /dev/null; do
          sleep 5
        done

        echo "✓ Xcode Command Line Tools updated!"
      else
        echo "✓ Xcode Command Line Tools up to date (v$CLT_VERSION)"
      fi
    else
      echo "✓ Xcode Command Line Tools already installed"
    fi
  fi
else
  echo "✓ Linux build tools are managed by setup/linux-headless.sh"
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

if [[ "$OS_NAME" != "Darwin" ]]; then
  echo "⏭ Skipping xcodemake (macOS/Xcode only)"
elif [ ! -f /usr/local/bin/xcodemake ]; then
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
