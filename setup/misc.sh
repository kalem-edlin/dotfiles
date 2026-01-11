#!/bin/bash

# Ensure Homebrew is in PATH (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Miscellaneous setup tasks

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

###############################################################################
# SketchyBar                                                                  #
###############################################################################

SKETCHYBAR_CONFIG="$HOME/.config/sketchybar"

if [ -d "$SKETCHYBAR_CONFIG" ]; then
  echo "Setting up SketchyBar..."
  
  # Make all plugin scripts executable
  chmod +x "$SKETCHYBAR_CONFIG/sketchybarrc" 2>/dev/null || true
  find "$SKETCHYBAR_CONFIG/plugins" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  find "$SKETCHYBAR_CONFIG/items" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
  
  # Start sketchybar service (runs on startup)
  if command -v sketchybar &> /dev/null; then
    brew services start sketchybar 2>/dev/null || true
    echo "✓ SketchyBar configured and service started"
  else
    echo "⚠ sketchybar not installed"
  fi
else
  echo "⚠ SketchyBar config not found at $SKETCHYBAR_CONFIG"
fi

###############################################################################
# AeroSpace                                                                   #
###############################################################################

if command -v aerospace &> /dev/null; then
  # AeroSpace uses its own start-at-login setting in aerospace.toml
  # Just ensure it's running now
  if ! pgrep -x "AeroSpace" > /dev/null; then
    open -a "AeroSpace" 2>/dev/null || true
  fi
  echo "✓ AeroSpace configured (uses start-at-login in config)"
else
  echo "⚠ AeroSpace not installed"
fi

###############################################################################
# Login Items (apps that start on login)                                      #
###############################################################################

echo "Configuring Login Items..."

# Function to add login item if not already present
add_login_item() {
  local app_path="$1"
  local app_name=$(basename "$app_path" .app)
  
  if [ -d "$app_path" ]; then
    # Check if already in login items
    if ! osascript -e "tell application \"System Events\" to get the name of every login item" 2>/dev/null | grep -q "$app_name"; then
      osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$app_path\", hidden:false}" >/dev/null 2>&1
      echo "  → Added $app_name to Login Items"
    else
      echo "  → $app_name already in Login Items"
    fi
  else
    echo "  ⚠ $app_name not installed"
  fi
}

# Add apps to Login Items
add_login_item "/Applications/Raycast.app"
add_login_item "/Applications/superwhisper.app"
add_login_item "/Applications/BeardedSpice.app"
add_login_item "/Applications/OrbStack.app"
add_login_item "/Applications/kindaVim.app"

echo ""
echo "✓ Misc setup complete!"

###############################################################################
# xcodemake                                                                   #
###############################################################################

echo "Configuring xcodemake..."

if [ ! -f /usr/local/bin/xcodemake ]; then
  curl -O https://raw.githubusercontent.com/johnno1962/xcodemake/main/xcodemake
  
  # Make it executable and move it
  chmod +x xcodemake
  sudo mv xcodemake /usr/local/bin/
  
  echo "✓ xcodemake configured!"
else
  echo "✓ xcodemake already exists"
fi

###############################################################################
# Claude Code                                                                 #
###############################################################################

echo "Installing Claude Code..."

if ! command -v claude-code &> /dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
  echo "✓ Claude Code installed!"
else
  echo "✓ Claude Code already installed"
fi