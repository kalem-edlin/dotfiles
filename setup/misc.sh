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

###############################################################################
# Notifier (Jamf)                                                             #
###############################################################################

echo "Installing Notifier..."

NOTIFIER_APP="/Applications/Utilities/Notifier.app"

if [ ! -d "$NOTIFIER_APP" ]; then
  # Get the latest release info from GitHub API
  LATEST_RELEASE=$(curl -s https://api.github.com/repos/jamf/Notifier/releases/latest)
  
  # Try to extract PKG URL using jq if available, otherwise use grep
  if command -v jq &> /dev/null; then
    PKG_URL=$(echo "$LATEST_RELEASE" | jq -r '.assets[] | select(.name | endswith(".pkg")) | .browser_download_url' | head -1)
  else
    # Fallback to grep method
    PKG_URL=$(echo "$LATEST_RELEASE" | grep -o '"browser_download_url": "[^"]*\.pkg[^"]*"' | head -1 | cut -d'"' -f4)
  fi
  
  if [ -z "$PKG_URL" ] || [ "$PKG_URL" = "null" ]; then
    echo "⚠ Could not find PKG download URL for Notifier"
    echo "  You can manually install from: https://github.com/jamf/Notifier/releases"
  else
    # Download to temp directory
    TEMP_DIR=$(mktemp -d)
    PKG_FILE="$TEMP_DIR/Notifier.pkg"
    
    echo "  → Downloading Notifier from GitHub..."
    curl -L -o "$PKG_FILE" "$PKG_URL"
    
    if [ -f "$PKG_FILE" ]; then
      echo "  → Installing Notifier..."
      sudo installer -pkg "$PKG_FILE" -target /
      
      # Clean up
      rm -rf "$TEMP_DIR"
      
      if [ -d "$NOTIFIER_APP" ]; then
        echo "✓ Notifier installed!"
      else
        echo "⚠ Notifier installation may have failed"
      fi
    else
      echo "⚠ Failed to download Notifier"
      rm -rf "$TEMP_DIR"
    fi
  fi
else
  echo "✓ Notifier already installed"
fi

# Check if Notifier has notification permissions and create symlink
if [ -d "$NOTIFIER_APP" ]; then
  NOTIFIER_BIN="$NOTIFIER_APP/Contents/MacOS/Notifier"
  if [ -f "$NOTIFIER_BIN" ]; then
    # Create symlink in ~/.local/bin if it doesn't exist
    LOCAL_BIN="$HOME/.local/bin"
    NOTIFIER_SYMLINK="$LOCAL_BIN/notifier"
    
    mkdir -p "$LOCAL_BIN"
    if [ ! -L "$NOTIFIER_SYMLINK" ] && [ ! -f "$NOTIFIER_SYMLINK" ]; then
      ln -s "$NOTIFIER_BIN" "$NOTIFIER_SYMLINK"
      echo "  → Created symlink: notifier → $NOTIFIER_BIN"
    elif [ -L "$NOTIFIER_SYMLINK" ]; then
      # Check if symlink is correct
      if [ "$(readlink "$NOTIFIER_SYMLINK")" != "$NOTIFIER_BIN" ]; then
        rm "$NOTIFIER_SYMLINK"
        ln -s "$NOTIFIER_BIN" "$NOTIFIER_SYMLINK"
        echo "  → Updated symlink: notifier → $NOTIFIER_BIN"
      fi
    fi
    
    # Try to trigger permission prompt by running a test notification
    # This will either work (if permission granted) or show the error
    if ! "$NOTIFIER_BIN" --type banner --message "test" &>/dev/null; then
      echo ""
      echo "⚠ Notifier needs notification permissions:"
      echo "  → Open System Settings → Notifications"
      echo "  → Enable notifications for 'Notifier - Notifications' and 'Notifier - Alerts'"
      echo "  → Or run: open 'x-apple.systempreferences:com.apple.preference.notifications'"
    fi
  fi
fi

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

# Skip Claude Code installation if SKIP_CLAUDE_CODE is set
if [ "${SKIP_CLAUDE_CODE:-}" = "1" ]; then
  echo "⏭ Skipping Claude Code installation (SKIP_CLAUDE_CODE=1)"
elif ! command -v claude &> /dev/null; then
  echo "Installing Claude Code..."
  echo "  → Downloading Claude Code installer..."
  # Download the installer script first to check if it's valid
  TEMP_SCRIPT=$(mktemp)
  
  if curl -fsSL https://claude.ai/install.sh -o "$TEMP_SCRIPT" 2>&1; then
    if [ -s "$TEMP_SCRIPT" ]; then
      echo "  → Running Claude Code installer..."
      # Run with explicit bash and show output
      # Note: This may prompt for user interaction
      bash "$TEMP_SCRIPT" || {
        echo "⚠ Claude Code installation failed or was cancelled"
        rm -f "$TEMP_SCRIPT"
        # Don't exit - continue with rest of setup
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
echo "✓ Misc setup complete!"