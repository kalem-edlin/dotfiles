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
  BUNDLE_FILE="$DOTFILES_DIR/Brewfile.headless"
else
  BUNDLE_FILE="$DOTFILES_DIR/Brewfile"
fi
# Newer Homebrew refuses to load formulae/casks from third-party taps unless
# they are trusted (per-machine state in ~/.homebrew/trust.json), so a fresh
# worker fails `brew bundle` on every non-official tap the Brewfile uses.
# Trust each tap the bundle file references — both explicit `tap "..."` lines
# and fully-qualified `brew "user/repo/formula"` names — before bundling.
if brew trust --help &> /dev/null; then
  {
    sed -n 's/^tap "\([^"]*\)".*/\1/p' "$BUNDLE_FILE"
    sed -n 's/^brew "\([^"/]*\/[^"/]*\)\/[^"]*".*/\1/p' "$BUNDLE_FILE"
    sed -n 's/^cask "\([^"/]*\/[^"/]*\)\/[^"]*".*/\1/p' "$BUNDLE_FILE"
  } | sort -u | while read -r tap; do
    [ -n "$tap" ] || continue
    echo "Trusting tap: $tap"
    brew trust --tap "$tap" || echo "⚠ could not trust tap $tap (continuing)" >&2
  done
fi

if ! brew bundle --file="$BUNDLE_FILE"; then
  echo "✗ brew bundle failed for $BUNDLE_FILE — packages are missing; aborting." >&2
  exit 1
fi

# tmux is pinned at the same version on every machine: laptop and workers
# drive each other's servers (rw), and replacing the binary under a live
# server breaks client calls until the server restarts. Homebrew can only
# install the current version, so warn when that is not the pin; move the
# pin deliberately (unpin, upgrade, pin) with a server restart on each host.
TMUX_VERSION=3.8
brew pin tmux
tmux_installed="$(brew list --versions tmux | awk '{print $2}')"
if [ "$tmux_installed" != "$TMUX_VERSION" ]; then
  echo "⚠ tmux $tmux_installed is installed (pinned); the repo pins $TMUX_VERSION." >&2
fi

# Post-install steps
echo "Linking libpq..."
brew link --force libpq 2>/dev/null || true

echo "✓ Homebrew packages installed!"
