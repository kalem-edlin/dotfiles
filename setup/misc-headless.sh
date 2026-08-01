#!/usr/bin/env bash

set -u

# Headless variant of misc.sh — skips GUI services, login items, and notifications.
# Used for Mac Mini server / agentic hub setup and Linux SSH hosts.

OS_NAME="$(uname -s)"
SETUP_USER="${SUDO_USER:-${USER:-$(id -un)}}"
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

  if ! ssh-keygen -t ed25519 -C "$(git config user.email || echo 'user@machine')" -f "$SSH_KEY" -N ""; then
    echo "✗ ssh-keygen failed to generate $SSH_KEY" >&2
    exit 1
  fi

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
# tmux-resurrect save timer (headless worker durability net)                 #
###############################################################################
#
# tmux-continuum's autosave is a `#()` status-line interpolation that only
# ever fires while a client is rendering the status line — a fully detached
# worker tmux server never autosaves. This installs a direct periodic timer
# that invokes tmux-resurrect's save entrypoint on its own, independent of
# any attached client. See setup/templates/tmux-resurrect-save.sh and
# docs/tasks/tmux-remote-workspaces/initial-plan.md, "Remote-side tmux
# durability". Continuum itself is untouched — it still runs normally
# wherever a client is attached (e.g. this same worker, interactively).

TEMPLATES_DIR="$DOTFILES_DIR/setup/templates"
RESURRECT_WRAPPER="$TEMPLATES_DIR/tmux-resurrect-save.sh"
RESURRECT_STATE_DIR="$HOME/.local/state/tmux-workspace-resurrect"

if [[ "$OS_NAME" = "Darwin" ]]; then
  echo "Configuring tmux-resurrect save timer (launchd)..."

  chmod +x "$RESURRECT_WRAPPER" 2>/dev/null || true
  mkdir -p "$HOME/Library/LaunchAgents" "$RESURRECT_STATE_DIR"

  # launchd's default environment does not include Homebrew's bin directory
  # on PATH, so a bare `tmux` lookup that works fine in this provisioning
  # shell (Homebrew was added to PATH above) silently fails under launchd.
  # Resolve the absolute path now and bake it into the plist as
  # TMUX_RESURRECT_SAVE_TMUX_BIN so the wrapper never depends on launchd's
  # PATH. See docs/tasks/headless-install.md, "7. Fix macOS launchd
  # execution".
  TMUX_BIN_RESOLVED="$(command -v tmux 2>/dev/null || true)"
  if [[ -z "$TMUX_BIN_RESOLVED" ]]; then
    echo "✗ tmux not found on PATH — cannot configure the tmux-resurrect save timer." >&2
    echo "  Install tmux (e.g. 'brew install tmux') and re-run setup." >&2
    exit 1
  fi
  if [[ ! -x "$TMUX_BIN_RESOLVED" ]]; then
    echo "✗ Resolved tmux at $TMUX_BIN_RESOLVED is not executable." >&2
    exit 1
  fi

  PLIST_LABEL="com.kalem.tmux-resurrect-save"
  PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

  sed \
    -e "s#__WRAPPER_PATH__#$RESURRECT_WRAPPER#g" \
    -e "s#__LOG_PATH__#$RESURRECT_STATE_DIR/launchd-save.log#g" \
    -e "s#__TMUX_BIN__#$TMUX_BIN_RESOLVED#g" \
    "$TEMPLATES_DIR/${PLIST_LABEL}.plist" >"$PLIST_DEST.tmp"

  if ! PLUTIL_LINT_OUT="$(plutil -lint "$PLIST_DEST.tmp" 2>&1)"; then
    echo "✗ Rendered plist failed plutil -lint: $PLIST_DEST.tmp" >&2
    echo "$PLUTIL_LINT_OUT" >&2
    rm -f "$PLIST_DEST.tmp"
    exit 1
  fi

  if cmp -s "$PLIST_DEST.tmp" "$PLIST_DEST" 2>/dev/null; then
    rm -f "$PLIST_DEST.tmp"
    echo "  ✓ $PLIST_DEST already up to date"
  else
    mv "$PLIST_DEST.tmp" "$PLIST_DEST"
    chmod 644 "$PLIST_DEST"
    echo "  → Rendered $PLIST_DEST"
  fi

  # Validate the tmux-resurrect save entrypoint exists/executable before
  # loading the timer. FAIL rather than auto-repair.
  #
  # ORDERING NOTE: in the current `make setup-headless` flow (Darwin), the
  # Makefile runs `misc-headless brew-headless python neovim node obsidian
  # install-headless` — misc-headless (this script) runs BEFORE
  # install-headless, and install-headless is what runs TPM's
  # install_plugins and clones tmux-resurrect into
  # ~/.config/tmux/plugins/tmux-resurrect. That means this check is
  # EXPECTED TO FAIL on a fully-fresh machine's first `make setup-headless`
  # pass. That is a Makefile ordering gap, not a bug in this validation —
  # do not weaken this check to work around it; fix the ordering instead
  # (run plugin install before misc-headless, or re-run misc-headless after
  # install-headless).
  RESURRECT_SAVE_SCRIPT="$HOME/.config/tmux/plugins/tmux-resurrect/scripts/save.sh"
  if [[ ! -f "$RESURRECT_SAVE_SCRIPT" ]] || [[ ! -x "$RESURRECT_SAVE_SCRIPT" ]]; then
    echo "✗ tmux-resurrect save entrypoint not found/executable: $RESURRECT_SAVE_SCRIPT" >&2
    echo "  TPM plugin install has not run yet. In the current setup-headless" >&2
    echo "  flow, misc-headless runs BEFORE install-headless, so this is" >&2
    echo "  expected on a machine's first setup pass. Run the dotfiles install" >&2
    echo "  target first:" >&2
    echo "    make install-headless   (or 'make install' on non-headless machines)" >&2
    echo "  then re-run:" >&2
    echo "    make misc-headless" >&2
    exit 1
  fi

  # Idempotent (re)load: bootout is a no-op if the agent isn't currently
  # loaded (stderr suppressed), then bootstrap loads and starts it fresh.
  # This is the modern replacement for `launchctl load/unload -w`. Both
  # failures below are fatal, not warnings — a job that fails to
  # (re)load is a broken durability net, not a degraded-but-fine state.
  launchctl bootout "gui/$(id -u)" "$PLIST_DEST" >/dev/null 2>&1 || true

  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"; then
    echo "✗ launchctl bootstrap failed for $PLIST_DEST" >&2
    echo "  check: launchctl print gui/$(id -u)/${PLIST_LABEL}" >&2
    exit 1
  fi

  if ! launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 2>&1; then
    echo "✗ tmux-resurrect-save timer failed to load — check: launchctl print gui/$(id -u)/${PLIST_LABEL}" >&2
    exit 1
  fi
  echo "  ✓ tmux-resurrect-save timer status: loaded (StartInterval 300s)"

  # Prove the wrapper actually resolves the tmux binary and the resurrect
  # save script under a launchd-like MINIMAL environment (no Homebrew, no
  # provisioning-shell PATH) — not merely that it works in this
  # provisioning shell's environment, which is exactly the class of bug
  # this fix addresses (see docs/tasks/headless-install.md, "7. Fix macOS
  # launchd execution"). The extra env var mirrors what the rendered
  # plist's EnvironmentVariables dict sets for the real launchd job.
  echo "  → Verifying wrapper under a launchd-like minimal environment..."
  if ! env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      TMUX_RESURRECT_SAVE_TMUX_BIN="$TMUX_BIN_RESOLVED" \
      "$RESURRECT_WRAPPER" --check; then
    echo "✗ tmux-resurrect-save.sh --check failed under a launchd-like minimal environment." >&2
    echo "  The loaded launchd job would fail the same way at its next scheduled run." >&2
    exit 1
  fi
  echo "  ✓ wrapper resolves tmux and the save script under a minimal PATH"
else
  echo "✓ Linux tmux-resurrect save timer (systemd) is managed by setup/linux-headless.sh"
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
