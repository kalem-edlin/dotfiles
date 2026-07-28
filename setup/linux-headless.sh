#!/usr/bin/env bash

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_USER="${SUDO_USER:-${USER:-$(id -un)}}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required when not running as root."
    exit 1
  fi
  SUDO=(sudo)
fi

run_sudo() {
  "${SUDO[@]}" "$@"
}

install_one() {
  local package="$1"

  case "$PKG_MANAGER" in
    apt)
      run_sudo apt-get install -y "$package"
      ;;
    dnf)
      run_sudo dnf install -y "$package"
      ;;
    pacman)
      run_sudo pacman -S --needed --noconfirm "$package"
      ;;
    zypper)
      run_sudo zypper --non-interactive install "$package"
      ;;
    apk)
      run_sudo apk add "$package"
      ;;
  esac
}

install_packages() {
  local package

  for package in "$@"; do
    if install_one "$package"; then
      echo "  ok $package"
    else
      echo "  warn: could not install $package"
    fi
  done
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    echo "Error: unsupported Linux package manager. Expected apt, dnf, pacman, zypper, or apk."
    exit 1
  fi
}

prepare_package_manager() {
  case "$PKG_MANAGER" in
    apt)
      run_sudo apt-get update
      ;;
    dnf)
      run_sudo dnf makecache --refresh || true
      ;;
    pacman)
      run_sudo pacman -Sy --noconfirm
      ;;
    zypper)
      run_sudo zypper --non-interactive refresh || true
      ;;
    apk)
      run_sudo apk update
      ;;
  esac
}

install_linux_packages() {
  echo "Installing Linux headless packages with $PKG_MANAGER..."

  case "$PKG_MANAGER" in
    apt)
      install_packages \
        bash zsh git git-lfs stow curl ca-certificates openssh-client \
        tmux neovim make gcc g++ build-essential pkg-config cmake ninja-build \
        unzip tar xz-utils ripgrep fd-find bat fzf jq tree btop zoxide \
        python3 python3-pip python3-venv pipx universal-ctags gnupg \
        libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
        llvm libncursesw5-dev tk-dev libxml2-dev libxmlsec1-dev libffi-dev \
        liblzma-dev postgresql-client libpq-dev

      if [[ "${INSTALL_DOCKER:-1}" = "1" ]]; then
        install_packages docker.io docker-compose-plugin
      fi
      ;;
    dnf)
      install_packages \
        bash zsh git git-lfs stow curl ca-certificates openssh-clients \
        tmux neovim make gcc gcc-c++ pkgconf-pkg-config cmake ninja-build \
        unzip tar xz ripgrep fd-find bat fzf jq tree btop zoxide \
        python3 python3-pip pipx ctags \
        openssl-devel zlib-devel bzip2 bzip2-devel readline-devel sqlite \
        sqlite-devel xz-devel tk-devel libffi-devel postgresql postgresql-devel

      if [[ "${INSTALL_DOCKER:-1}" = "1" ]]; then
        install_packages docker docker-compose-plugin
      fi
      ;;
    pacman)
      install_packages \
        bash zsh git git-lfs stow curl ca-certificates openssh \
        tmux neovim base-devel pkgconf cmake ninja unzip tar xz \
        ripgrep fd bat fzf jq tree btop zoxide \
        python python-pip python-pipx ctags \
        openssl zlib bzip2 readline sqlite tk libffi postgresql-libs

      if [[ "${INSTALL_DOCKER:-1}" = "1" ]]; then
        install_packages docker docker-compose
      fi
      ;;
    zypper)
      install_packages \
        bash zsh git git-lfs stow curl ca-certificates openssh \
        tmux neovim make gcc gcc-c++ pkg-config cmake ninja unzip tar xz \
        ripgrep fd bat fzf jq tree btop zoxide \
        python3 python3-pip python3-venv pipx ctags \
        libopenssl-devel zlib-devel libbz2-devel readline-devel sqlite3-devel \
        xz-devel tk-devel libffi-devel postgresql-devel

      if [[ "${INSTALL_DOCKER:-1}" = "1" ]]; then
        install_packages docker docker-compose
      fi
      ;;
    apk)
      install_packages \
        bash zsh git git-lfs stow curl ca-certificates openssh-client \
        tmux neovim make gcc g++ build-base pkgconf cmake ninja unzip tar xz \
        ripgrep fd bat fzf jq tree btop zoxide \
        python3 py3-pip py3-pipx ctags \
        openssl-dev zlib-dev bzip2-dev readline-dev sqlite-dev xz-dev \
        tk-dev libffi-dev postgresql-dev

      if [[ "${INSTALL_DOCKER:-1}" = "1" ]]; then
        install_packages docker docker-cli-compose
      fi
      ;;
  esac

  if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --skip-repo || true
  fi

  if [[ "${INSTALL_DOCKER:-1}" = "1" ]] && command -v docker >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      run_sudo systemctl enable --now docker 2>/dev/null || true
    fi

    if getent group docker >/dev/null 2>&1 && [[ -n "$SETUP_USER" ]]; then
      run_sudo usermod -aG docker "$SETUP_USER" 2>/dev/null || true
    fi
  fi
}

install_tailscale() {
  if [[ "${INSTALL_TAILSCALE:-0}" != "1" ]]; then
    echo "Skipping Tailscale. Set INSTALL_TAILSCALE=1 to install it."
    return
  fi

  if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale already installed."
    return
  fi

  echo "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
}

install_stripe_cli_with_npm() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "warn: npm unavailable; could not install Stripe CLI fallback."
    return 1
  fi

  npm install -g @stripe/cli
}

install_stripe_cli() {
  if command -v stripe >/dev/null 2>&1; then
    echo "Stripe CLI already installed: $(command -v stripe)"
    return
  fi

  echo "Installing Stripe CLI..."

  case "$PKG_MANAGER" in
    apt)
      run_sudo mkdir -p /usr/share/keyrings
      if curl -s https://packages.stripe.dev/api/security/keypair/stripe-cli-gpg/public \
        | gpg --dearmor \
        | run_sudo tee /usr/share/keyrings/stripe.gpg >/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/stripe.gpg] https://packages.stripe.dev/stripe-cli-debian-local stable main" \
          | run_sudo tee /etc/apt/sources.list.d/stripe.list >/dev/null
        run_sudo apt-get update
        install_one stripe || install_stripe_cli_with_npm
      else
        install_stripe_cli_with_npm
      fi
      ;;
    dnf)
      cat <<'REPO' | run_sudo tee /etc/yum.repos.d/stripe.repo >/dev/null
[Stripe]
name=stripe
baseurl=https://packages.stripe.dev/stripe-cli-rpm-local/
enabled=1
gpgcheck=0
REPO
      install_one stripe || install_stripe_cli_with_npm
      ;;
    *)
      install_stripe_cli_with_npm
      ;;
  esac
}

link_config_package() {
  local package="$1"
  local target="$HOME/.config/$package"

  [[ -d "$DOTFILES_DIR/$package" ]] || return 0

  mkdir -p "$HOME/.config"

  if [[ -L "$target" ]]; then
    case "$(readlink "$target")" in
      "$DOTFILES_DIR"*) echo "  $package already linked" ;;
      *) echo "  replacing stale $package symlink"; rm "$target"; ln -s "$DOTFILES_DIR/$package" "$target" ;;
    esac
  elif [[ -e "$target" ]]; then
    echo "  $target exists; skipping"
  else
    echo "  linking $package -> $target"
    ln -s "$DOTFILES_DIR/$package" "$target"
  fi
}

backup_stow_conflicts() {
  local package="$1"
  local file relpath target

  [[ -d "$DOTFILES_DIR/$package" ]] || return 0

  while IFS= read -r file; do
    relpath="${file#"$DOTFILES_DIR/$package/"}"
    target="$HOME/$relpath"

    if [[ -L "$target" ]]; then
      case "$(readlink "$target")" in
        "$DOTFILES_DIR"*) ;;
        *) echo "  removing stale symlink $relpath"; rm "$target" ;;
      esac
    elif [[ -e "$target" ]]; then
      echo "  backing up $relpath"
      rm -f "$target.bak" 2>/dev/null || true
      mv "$target" "$target.bak"
    fi
  done < <(find "$DOTFILES_DIR/$package" -type f 2>/dev/null)
}

install_tpm() {
  if [[ ! -d "$HOME/.config/tmux/plugins/tpm" ]]; then
    echo "  installing TPM"
    git clone https://github.com/tmux-plugins/tpm "$HOME/.config/tmux/plugins/tpm"
  else
    echo "  TPM already installed"
  fi

  if [[ -d "$HOME/.config/tmux/plugins/tpm" ]]; then
    echo "  installing tmux plugins"
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.config/tmux/plugins/" "$HOME/.config/tmux/plugins/tpm/bin/install_plugins" || true
  fi

  if [[ ! -d "$HOME/.config/tmux/plugins/tmux-sessionx" ]]; then
    echo "  installing tmux-sessionx pinned commit"
    git clone https://github.com/omerxx/tmux-sessionx "$HOME/.config/tmux/plugins/tmux-sessionx"
    git -C "$HOME/.config/tmux/plugins/tmux-sessionx" checkout 3a1911e
  fi
}

install_headless_dotfiles() {
  local package

  echo "Installing headless dotfiles..."
  link_config_package nvim
  link_config_package tmux

  install_tpm

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  for package in claude git pi ssh vim zsh; do
    backup_stow_conflicts "$package"
  done

  for package in claude git pi ssh vim zsh; do
    if [[ -d "$DOTFILES_DIR/$package" ]]; then
      echo "  stowing $package"
      stow --no-folding --restow -d "$DOTFILES_DIR" -t "$HOME" "$package"
    fi
  done

  chmod 600 "$DOTFILES_DIR/ssh/.ssh/config" 2>/dev/null || true
}

verify_commands() {
  local command_name
  local missing=0

  for command_name in zsh git stow tmux nvim curl stripe; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "warn: expected command not found after setup: $command_name"
      missing=1
    fi
  done

  return "$missing"
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: setup/linux-headless.sh is only for Linux."
  exit 1
fi

detect_package_manager
prepare_package_manager
install_linux_packages
install_tailscale

"$DOTFILES_DIR/setup/misc-headless.sh"
"$DOTFILES_DIR/setup/node.sh"
install_stripe_cli
"$DOTFILES_DIR/setup/python.sh"
"$DOTFILES_DIR/setup/neovim.sh"
"$DOTFILES_DIR/setup/obsidian.sh"
install_headless_dotfiles

verify_commands || true

echo ""
echo "Linux headless setup complete."
echo "Open a new login shell to pick up zsh, fnm, pyenv, Docker group changes, and PATH updates."
