#!/usr/bin/env bash
#
# setup/linux-headless.sh — Linux orchestration for `make setup-headless`
# (Linux branch). Adopts the shared install layer in setup/lib.sh instead of
# maintaining its own third copy of the stow/TPM/rw logic, and stops
# converting required failures into warnings. See docs/headless-vs-local.md
# for the shared-contract design and docs/headless-workers.md for the
# required worker contract this script installs toward.
#
# `make setup-linux-headless` runs this script and THEN gates on
# `setup/headless-doctor.sh` (exit-propagating) — this script no longer needs
# to be the final validator, but it must never print its own success banner
# after a required step failed, and its own exit code must reflect reality.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_USER="${SUDO_USER:-${USER:-$(id -un)}}"

# shellcheck source=setup/lib.sh
. "$DOTFILES_DIR/setup/lib.sh"

# ~/.local/bin holds `claude` (installed by misc-headless.sh below), `rw`
# (linked by install_headless_dotfiles below via lib.sh's link_rw), and the
# worktree-slot/worktree-claim entrypoints the `worktrees` package stows
# later in this same script. Put it FIRST on PATH now so every later step in
# THIS process — including the upstream Neovim fallback and verify_commands
# — resolves managed user-local commands ahead of old distro packages.
export PATH="$HOME/.local/bin:$PATH"

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

# ---------------------------------------------------------------------------
# Platform / init-system boundary
# ---------------------------------------------------------------------------

# v1 supports only systemd-based Linux workers: the durability timer
# (install_tmux_resurrect_save_timer below) requires a working `systemd
# --user` instance plus linger. Fail EARLY and clearly — before installing
# any package — rather than let an Alpine/OpenRC host or a userless
# container reach package installation and only discover the durability gap
# at the very end. apk stays in the package-manager mapping below for a
# possible future non-systemd implementation, but this script does not
# pretend to support it today. See docs/headless-vs-local.md, "Platform
# support boundary".
check_systemd_support() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemctl not found." >&2
    echo "This installer supports only systemd-based Linux distributions (v1 boundary)." >&2
    echo "Alpine/OpenRC and other non-systemd init systems are out of contract." >&2
    echo "See docs/headless-vs-local.md, 'Platform support boundary'." >&2
    exit 1
  fi

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "Error: 'systemctl --user show-environment' could not connect to a systemd user instance." >&2
    echo "This usually means no systemd --user manager is running for this account (e.g. a" >&2
    echo "container without a real login session, or an account that has never completed a" >&2
    echo "full PAM login session)." >&2
    echo "This installer requires a working systemd --user instance; unsupported init/user-service" >&2
    echo "environments are out of contract for v1. Try logging in via a real interactive SSH" >&2
    echo "session (not 'su'/'docker exec' without a session), or have an already-privileged" >&2
    echo "session run: loginctl enable-linger \"$SETUP_USER\"" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------

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

# install_required_packages <package> ... — every failure is collected and
# reported together, then the function returns nonzero. Called as a plain
# statement (not inside an `if`), so `set -e` aborts the script immediately
# afterward — a required package failure is fatal, not a warning.
install_required_packages() {
  local package
  local failed=()

  for package in "$@"; do
    if install_one "$package"; then
      echo "  ok $package (required)"
    else
      echo "  FAILED $package (required)"
      failed+=("$package")
    fi
  done

  if [[ "${#failed[@]}" -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: required package(s) failed to install: ${failed[*]}" >&2
    echo "These are part of the worker contract (docs/headless-workers.md," >&2
    echo "'Required worker contract'); aborting rather than claiming success." >&2
    return 1
  fi
}

# install_optional_packages <package> ... — failures are warnings only, and
# every install attempt is explicitly labeled "(optional)" in output so a
# reader never has to guess whether a given package was part of the
# contract.
install_optional_packages() {
  local package

  for package in "$@"; do
    if install_one "$package"; then
      echo "  ok $package (optional)"
    else
      echo "  warn: could not install optional package: $package"
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
      # Best-effort: a stale/unreachable metadata cache here does not doom
      # the install — install_required_packages below will surface any real
      # per-package failure explicitly and fatally.
      run_sudo dnf makecache --refresh || true
      ;;
    pacman)
      run_sudo pacman -Sy --noconfirm
      ;;
    zypper)
      # Best-effort, same reasoning as dnf above.
      run_sudo zypper --non-interactive refresh || true
      ;;
    apk)
      run_sudo apk update
      ;;
  esac
}

install_linux_packages() {
  echo "Installing Linux headless packages with $PKG_MANAGER..."

  local required=()
  local optional=()

  # REQUIRED: the contract commands from docs/headless-workers.md,
  # "Required worker contract" (zsh, git, git-lfs, stow, tmux, jq, rsync,
  # tar, nvim, an ssh client) plus the minimal build toolchain genuinely
  # needed for npm packages with native addons installed by setup/node.sh
  # (make/gcc/g++/pkg-config or the distro's build-essentials equivalent),
  # plus gh (GitHub CLI) for parity with Brewfile.headless:27, which already
  # installs it on macOS headless workers (see headless-doctor.sh's cmd:gh
  # check). gh is only REQUIRED here on distros confidently known to ship it
  # in their default repos (apt/dnf/pacman); elsewhere it is OPTIONAL with a
  # comment explaining why, so an unsupported distro degrades to a warning
  # instead of a hard failure.
  #
  # git-delta is ALSO required (apt/dnf/pacman/zypper, package "git-delta")
  # for the same reason gh is: git/.gitconfig unconditionally sets `pager =
  # delta` and a [delta] diffFilter, so a missing delta breaks ordinary
  # `git log`/`git diff` outright, not just a nice-to-have degradation (see
  # headless-doctor.sh's cmd:delta check and docs/headless-vs-local.md,
  # "Known parity gaps"). Confirmed available via `apt-cache policy
  # git-delta` on agents-roll (Ubuntu 24.04, universe repo) 2026-08-02; dnf/
  # pacman/zypper all carry a "git-delta" package in their default repos
  # too. apk stays OPTIONAL under the name "delta" below, matching gh's apk
  # treatment (unreachable branch today per check_systemd_support, and less
  # confidence in Alpine's package set generally).
  #
  # OPTIONAL: everything else — conveniences (ripgrep, fd, bat, fzf, tree,
  # btop, zoxide, lsof, ctags, eza, zsh-autosuggestions, ...) and the
  # pyenv/Python build-dependency headers (python.sh is not part of the
  # required command contract). eza and zsh-autosuggestions are genuine
  # conveniences (README.md's "guarded convenience" promise, zsh/.zshrc's
  # `command -v eza`/plugin source_if_exists guards) -- never required,
  # because zsh/.zshrc and the alias definitions already degrade silently
  # when either is absent.
  case "$PKG_MANAGER" in
    apt)
      required=(
        bash zsh git git-lfs stow curl ca-certificates openssh-client
        tmux neovim jq rsync tar make gcc g++ pkg-config gh git-delta
      )
      optional=(
        cmake ninja-build unzip xz-utils ripgrep fd-find bat fzf tree btop
        zoxide lsof python3 python3-pip python3-venv pipx universal-ctags
        gnupg libssl-dev zlib1g-dev libbz2-dev libreadline-dev
        libsqlite3-dev llvm libncursesw5-dev tk-dev libxml2-dev
        libxmlsec1-dev libffi-dev liblzma-dev postgresql-client libpq-dev
        eza zsh-autosuggestions
      )
      ;;
    dnf)
      required=(
        bash zsh git git-lfs stow curl ca-certificates openssh-clients
        tmux neovim jq rsync tar make gcc gcc-c++ pkgconf-pkg-config gh
        git-delta
      )
      optional=(
        cmake ninja-build unzip xz ripgrep fd-find bat fzf tree btop zoxide
        lsof python3 python3-pip pipx ctags openssl-devel zlib-devel bzip2
        bzip2-devel readline-devel sqlite sqlite-devel xz-devel tk-devel
        libffi-devel postgresql postgresql-devel eza zsh-autosuggestions
      )
      ;;
    pacman)
      required=(
        bash zsh git git-lfs stow curl ca-certificates openssh
        tmux neovim jq rsync tar base-devel pkgconf gh git-delta
      )
      optional=(
        cmake ninja unzip xz ripgrep fd bat fzf tree btop zoxide lsof
        python python-pip python-pipx ctags openssl zlib bzip2 readline
        sqlite tk libffi postgresql-libs eza zsh-autosuggestions
      )
      ;;
    zypper)
      required=(
        bash zsh git git-lfs stow curl ca-certificates openssh
        tmux neovim jq rsync tar make gcc gcc-c++ pkg-config git-delta
      )
      optional=(
        cmake ninja unzip xz ripgrep fd bat fzf tree btop zoxide lsof
        python3 python3-pip python3-venv pipx ctags libopenssl-devel
        zlib-devel libbz2-devel readline-devel sqlite3-devel xz-devel
        tk-devel libffi-devel postgresql-devel eza zsh-autosuggestions
        # gh: package name is correct, but unlike apt/dnf/pacman we are not
        # confident it ships in every openSUSE default repo config (Leap vs
        # Tumbleweed vary) -- keep optional so a miss degrades to a warning,
        # not a hard failure.
        gh
      )
      ;;
    apk)
      # Kept for a possible future non-systemd durability implementation —
      # check_systemd_support above already aborts before this function can
      # be reached on a typical (non-systemd) Alpine host.
      required=(
        bash zsh git git-lfs stow curl ca-certificates openssh-client
        tmux neovim jq rsync tar make gcc g++ build-base pkgconf
      )
      optional=(
        cmake ninja unzip xz ripgrep fd bat fzf tree btop zoxide lsof
        python3 py3-pip py3-pipx ctags openssl-dev zlib-dev bzip2-dev
        readline-dev sqlite-dev xz-dev tk-dev libffi-dev postgresql-dev
        eza zsh-autosuggestions
        # delta: package name is correct (Alpine ships git-delta's binary
        # under the plain name "delta"), but we are less confident it is
        # present/enabled in every Alpine repo config than on apt/dnf/
        # pacman/zypper -- keep optional so a miss degrades to a warning,
        # not a hard failure (this branch is currently unreachable anyway
        # per the check_systemd_support comment above).
        delta
        # gh: package name is correct, but it lives in Alpine's "community"
        # repo, which is not guaranteed enabled on every minimal Alpine
        # install (and this branch is currently unreachable anyway per the
        # comment above) -- keep optional so a missing/disabled repo
        # degrades to a warning, not a hard failure.
        gh
      )
      ;;
  esac

  install_required_packages "${required[@]}"
  install_optional_packages "${optional[@]}"

  if [[ "${INSTALL_DOCKER:-1}" = "1" ]]; then
    case "$PKG_MANAGER" in
      apt) install_optional_packages docker.io docker-compose-plugin ;;
      dnf) install_optional_packages docker docker-compose-plugin ;;
      pacman) install_optional_packages docker docker-compose ;;
      zypper) install_optional_packages docker docker-compose ;;
      apk) install_optional_packages docker docker-cli-compose ;;
    esac
  fi

  # git-lfs is required above, so if this fails it is a real regression in
  # the worker contract, not an optional nicety — no `|| true` here.
  if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --skip-repo
  fi

  # git/.gitconfig unconditionally sets `pager = delta`. git-delta is now a
  # REQUIRED package on apt/dnf/pacman/zypper above (see the comment on
  # install_linux_packages' required/optional split), so install_required_
  # packages already aborts the whole script (via `set -e`) before this
  # point is ever reached on those managers if the install genuinely failed.
  # This check remains as defense-in-depth for the one path where delta is
  # still OPTIONAL (apk -- unreachable today per check_systemd_support) and
  # as a second, independent confirmation that the binary is actually on
  # PATH (not just that the package manager reported success) -- it prints a
  # loud, impossible-to-miss warning instead of silently leaving `git log`/
  # `git diff` broken.
  if command -v delta >/dev/null 2>&1; then
    echo "  ok git-delta (delta) available: $(command -v delta)"
  else
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "! WARNING: git-delta (delta) is not installed on this distribution.     !"
    echo "! git/.gitconfig unconditionally sets 'pager = delta' -- git log/diff   !"
    echo "! will fail (or fall back badly) until delta is installed manually.     !"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
  fi

  if [[ "${INSTALL_DOCKER:-1}" = "1" ]] && command -v docker >/dev/null 2>&1; then
    # Docker is not part of the required worker contract (headless-doctor
    # does not check it) — enabling the service and adding the group are
    # both best-effort conveniences.
    if command -v systemctl >/dev/null 2>&1; then
      run_sudo systemctl enable --now docker 2>/dev/null || true
    fi

    if getent group docker >/dev/null 2>&1 && [[ -n "$SETUP_USER" ]]; then
      run_sudo usermod -aG docker "$SETUP_USER" 2>/dev/null || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------

# zsh/.zshrc assumes en_US.UTF-8. Minimal VPS images frequently do not have
# it generated. Best-effort only: generate it cheaply where that's a single
# well-known step (Debian/Ubuntu's /etc/locale.gen), otherwise just report
# the available UTF-8 fallback. Never fatal — headless-doctor reports locale
# as an optional/WARN check, not a required one.
locale_is_available() {
  local target_normalized="enusutf8"
  local available normalized

  for available in $(locale -a 2>/dev/null); do
    normalized="$(printf '%s' "$available" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
    if [[ "$normalized" == "$target_normalized" ]]; then
      return 0
    fi
  done
  return 1
}

ensure_locale() {
  echo "Checking locale availability (en_US.UTF-8)..."

  if ! command -v locale >/dev/null 2>&1; then
    echo "  warn: 'locale' command not available; skipping locale check."
    return 0
  fi

  if locale_is_available; then
    echo "  ok en_US.UTF-8 (or equivalent) is available"
    return 0
  fi

  echo "  en_US.UTF-8 not found in 'locale -a'"

  if [[ "$PKG_MANAGER" == "apt" ]] && [[ -f /etc/locale.gen ]]; then
    echo "  attempting to generate en_US.UTF-8 via /etc/locale.gen (Debian/Ubuntu)..."
    if run_sudo sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
      && run_sudo locale-gen >/dev/null; then
      echo "  -> ran locale-gen; re-checking..."
    else
      echo "  warn: locale-gen attempt failed; continuing with an available fallback."
    fi
  else
    echo "  skipping best-effort generation on $PKG_MANAGER (no cheap single-step path here)."
  fi

  if locale_is_available; then
    echo "  ok en_US.UTF-8 is now available after locale-gen"
    return 0
  fi

  local chosen=""
  for available in $(locale -a 2>/dev/null); do
    case "$available" in
      *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*)
        chosen="$available"
        break
        ;;
    esac
  done

  if [[ -n "$chosen" ]]; then
    echo "  NOTICE: en_US.UTF-8 is unavailable. Shells will fall back to an available"
    echo "  UTF-8 locale ($chosen). headless-doctor also reports this."
  else
    echo "  NOTICE: en_US.UTF-8 is unavailable and no UTF-8 locale was found via 'locale -a'."
    echo "  Shells may run without a UTF-8 locale until one is installed manually."
  fi
}

# ---------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------

install_tailscale() {
  # Tailscale is part of the ordinary worker connectivity contract. Allow an
  # explicit opt-out for deliberately public/LAN-only workers, but install it
  # by default on every Linux headless host.
  if [[ "${INSTALL_TAILSCALE:-1}" != "1" ]]; then
    echo "Skipping Tailscale because INSTALL_TAILSCALE=${INSTALL_TAILSCALE}."
    return
  fi

  if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale already installed."
    return
  fi

  echo "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh

  if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale installed. Authenticate this worker with: sudo tailscale up"
  else
    echo "Error: Tailscale installation completed but the tailscale command is unavailable."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Stripe CLI (optional — not part of the required worker contract)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Dotfiles (now a thin wrapper over setup/lib.sh — see the Makefile's
# `install`/`install-headless` targets for the equivalent local pattern)
# ---------------------------------------------------------------------------

# Same package set as the Makefile's HEADLESS_STOW_PACKAGES /
# HEADLESS_CONFIG_PACKAGES, kept in sync deliberately (see
# docs/headless-vs-local.md for the shared-contract design).
install_headless_dotfiles() {
  echo "Installing headless dotfiles..."

  link_config_package nvim
  link_config_package tmux

  # Requires ~/.config/tmux to already be linked (just above).
  install_tmux_plugins

  ensure_ssh_dirs

  backup_conflicts claude codex eza git pi ssh vim worktrees zsh
  stow_packages claude codex eza git pi ssh vim worktrees zsh

  # codex ships no config.toml in the stowed package (codex writes project
  # trust entries straight into that file, so symlinking it would dirty the
  # repo on every run); seed a starter one only if none exists yet. See
  # setup/lib.sh's seed_codex_config.
  seed_codex_config

  link_rw

  # Cosmetic permission tightening on a file the required stow_packages call
  # above just created (as a symlink into this repo); stow's own fatal-on-
  # error behavior is the actual gate here, this chmod is idempotent
  # belt-and-suspenders and never the sole guard against a wide-open key.
  chmod 600 "$DOTFILES_DIR/ssh/.ssh/config" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# tmux-resurrect save timer (systemd --user)
# ---------------------------------------------------------------------------

install_tmux_resurrect_save_timer() {
  # systemd --user timer that invokes tmux-resurrect's save entrypoint
  # directly, independent of any attached tmux client. tmux-continuum's
  # autosave is a status-line `#()` interpolation that only fires while a
  # client renders it — a fully detached worker tmux server never
  # autosaves otherwise. See setup/templates/tmux-resurrect-save.sh and
  # docs/tasks/tmux-remote-workspaces/initial-plan.md, "Remote-side tmux
  # durability".
  echo "Configuring tmux-resurrect save timer (systemd --user)..."

  # check_systemd_support already ran (and would have exited) before any
  # installation happened, so systemctl is guaranteed present here. Kept as
  # a defensive, fatal (not skip) check rather than trusting that nothing
  # upstream changed the environment mid-run.
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemctl not found — this should have been caught by check_systemd_support." >&2
    exit 1
  fi

  local templates_dir="$DOTFILES_DIR/setup/templates"
  local wrapper_script="$templates_dir/tmux-resurrect-save.sh"
  local unit_dir="$HOME/.config/systemd/user"
  local service_dest="$unit_dir/tmux-resurrect-save.service"
  local timer_dest="$unit_dir/tmux-resurrect-save.timer"

  chmod +x "$wrapper_script" 2>/dev/null || true
  mkdir -p "$unit_dir"

  # systemd --user's default environment may not include the directory tmux
  # lives in on PATH, so a bare `tmux` lookup that works fine in this
  # provisioning shell can silently fail under the timer. Resolve the
  # absolute path now and bake it into the unit as
  # TMUX_RESURRECT_SAVE_TMUX_BIN so the wrapper never depends on systemd's
  # PATH — mirrors the same fix for launchd on macOS (setup/misc-headless.sh,
  # setup/templates/com.kalem.tmux-resurrect-save.plist).
  local tmux_bin_resolved
  tmux_bin_resolved="$(command -v tmux 2>/dev/null || true)"
  if [ -z "$tmux_bin_resolved" ]; then
    echo "ERROR: tmux not found on PATH — cannot configure the tmux-resurrect save timer." >&2
    exit 1
  fi

  sed \
    -e "s#__WRAPPER_PATH__#$wrapper_script#g" \
    -e "s#__TMUX_BIN__#$tmux_bin_resolved#g" \
    "$templates_dir/tmux-resurrect-save.service" >"$service_dest.tmp"
  mv "$service_dest.tmp" "$service_dest"
  cp "$templates_dir/tmux-resurrect-save.timer" "$timer_dest"

  # A headless box has no login session, so systemd --user would normally
  # stop (and this timer with it) once the provisioning SSH session ends.
  # Enable linger so the user systemd instance keeps running independent of
  # any login. Missed runs while the server/tmux is down are meaningless
  # (Persistent=no in the timer unit), so linger is what actually keeps the
  # timer alive long-term, not catch-up semantics. Verified below and fatal
  # if it does not end up "yes" — a timer that cannot survive logout is not
  # a real durability net.
  if loginctl show-user "$SETUP_USER" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
    echo "  ok loginctl linger already enabled for $SETUP_USER"
  else
    echo "  enabling loginctl linger for $SETUP_USER"
    run_sudo loginctl enable-linger "$SETUP_USER"
  fi

  if ! loginctl show-user "$SETUP_USER" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
    echo "ERROR: loginctl show-user $SETUP_USER -p Linger did not report Linger=yes after enable-linger." >&2
    echo "The save timer would not survive logout without linger — this is fatal for the" >&2
    echo "worker durability contract, not a warning." >&2
    exit 1
  fi

  systemctl --user daemon-reload
  systemctl --user enable --now tmux-resurrect-save.timer

  if systemctl --user is-active --quiet tmux-resurrect-save.timer; then
    echo "  ok tmux-resurrect-save.timer active (OnUnitActiveSec=5min)"
  else
    echo "ERROR: tmux-resurrect-save.timer is NOT active — check: systemctl --user status tmux-resurrect-save.timer" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Internal fast-fail verification (headless-doctor is still the authoritative
# gate at the Make level — see the Makefile's `setup-linux-headless` target —
# but this script's own exit code must independently reflect reality too).
# ---------------------------------------------------------------------------

verify_commands() {
  local command_name
  local missing=0
  local nvim_version nvim_major nvim_minor
  local required_commands=(
    zsh git git-lfs stow tmux nvim jq curl rsync tar
    node npm pi codex claude ob
  )

  if [[ "${INSTALL_TAILSCALE:-1}" = "1" ]]; then
    required_commands+=(tailscale)
  fi

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "ERROR: required command not found after setup: $command_name" >&2
      missing=1
    fi
  done

  if command -v nvim >/dev/null 2>&1; then
    nvim_version="$(nvim --version 2>/dev/null | sed -n '1s/^NVIM v\([0-9][0-9.]*\).*$/\1/p')"
    nvim_major="${nvim_version%%.*}"
    nvim_minor="${nvim_version#*.}"
    nvim_minor="${nvim_minor%%.*}"
    if [[ ! "$nvim_major" =~ ^[0-9]+$ ]] || [[ ! "$nvim_minor" =~ ^[0-9]+$ ]] || \
       (( nvim_major == 0 && nvim_minor < 10 )); then
      echo "ERROR: Neovim >= 0.10 is required after setup; found ${nvim_version:-unreadable} at $(command -v nvim)." >&2
      missing=1
    fi
  fi

  # Stripe is intentionally NOT in required_commands above — it is not part
  # of the required worker contract (headless-doctor treats it as
  # optional/WARN too).
  if command -v stripe >/dev/null 2>&1; then
    echo "  ok stripe (optional): $(command -v stripe)"
  else
    echo "  note: stripe CLI not found (optional; not part of the required worker contract)"
  fi

  if ! git lfs env >/dev/null 2>&1; then
    echo "ERROR: 'git lfs env' failed." >&2
    missing=1
  fi

  return "$missing"
}

# ---------------------------------------------------------------------------
# Main sequence
# ---------------------------------------------------------------------------
#
# Order: platform/init-system boundary (fatal, before any install) ->
# packages (required/optional split, fatal on required failure) -> locale
# (best-effort, never fatal) -> Tailscale (required unless opted out) ->
# misc-headless.sh (ssh key, oh-my-zsh, Claude Code, gh) -> node.sh (installs
# fnm+Node as a CHILD process) -> activate_fnm IN THIS PROCESS (fixes the
# child-process PATH boundary — fnm/Node changes made inside a child process
# do not propagate back to this script) -> Stripe CLI (npm fallback now
# has a working, activated fnm) -> python.sh / neovim.sh / obsidian.sh
# (obsidian.sh activates its own fnm too, so it works standalone) ->
# dotfiles via lib.sh (stow, TPM, rw, ssh dirs) -> systemd save timer + fatal
# linger verification -> internal verify_commands -> success banner (only
# reachable if everything above succeeded).

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: setup/linux-headless.sh is only for Linux."
  exit 1
fi

check_systemd_support

detect_package_manager
prepare_package_manager
install_linux_packages

ensure_locale

install_tailscale

"$DOTFILES_DIR/setup/misc-headless.sh"

"$DOTFILES_DIR/setup/node.sh"

# setup/node.sh ran as a CHILD process — its fnm/Node PATH changes do not
# return to THIS process. Activate fnm here too so every step below
# (Stripe's npm fallback, verify_commands, dotfile/timer installation) can
# resolve node/npm/pi/codex/ob in its OWN process, not just inside node.sh's
# and obsidian.sh's separate child processes. Deliberately NOT `|| true`:
# node.sh just installed fnm+Node moments ago, so failure to activate it
# here means something is genuinely wrong and the rest of the run (which
# needs node-installed tools) should not proceed pretending success.
activate_fnm

# Stripe is optional (see verify_commands above) — a failure here is a
# warning, not fatal.
install_stripe_cli || echo "warn: Stripe CLI installation failed (optional; not part of the required worker contract)."

"$DOTFILES_DIR/setup/python.sh"
"$DOTFILES_DIR/setup/neovim.sh"
"$DOTFILES_DIR/setup/obsidian.sh"

install_headless_dotfiles
install_tmux_resurrect_save_timer

verify_commands

echo ""
echo "Linux headless install phase complete — running postflight doctor next (make setup-linux-headless gates success on it)."
echo "Open a new login shell to pick up zsh, fnm, pyenv, Docker group changes, and PATH updates."
