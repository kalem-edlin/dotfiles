#!/usr/bin/env bash
#
# setup/macos-headless.sh — Darwin orchestration for `make setup-headless`.
#
# Extracted out of the Makefile recipe (which used to be one giant `@if ...;
# \` compound shell recipe with no fail-fast behavior) for two reasons:
#
#   1. `set -euo pipefail` here means the FIRST failing step aborts the
#      whole run. No step's failure can be masked by a later echo reaching a
#      success banner.
#   2. The Makefile recipe that calls this script is a single line with no
#      `$(MAKE)` token in it. GNU Make always executes recipe lines that
#      contain a literal `$(MAKE)`/`${MAKE}`, even under `make -n` (dry
#      run) — that's what made the old recipe's `make -n setup-headless`
#      unsafe (it ran sudo and reached the cleanup command). This script
#      calls `make` itself, but that happens at real runtime, inside this
#      script — not as Makefile recipe text — so `make -n setup-headless`
#      now only ever prints "run setup/macos-headless.sh" and does nothing.
#
# Run this as the target (non-root) user via `make setup-headless`, never
# `sudo make setup-headless`. This script requests sudo once (with a
# keep-alive loop) purely as a UX convenience so Homebrew/Xcode-CLT prompts
# inside the steps below don't stall waiting for a password; each step is
# still responsible for its own specific privileged operations rather than
# assuming it is running as root.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: setup/macos-headless.sh is only for macOS." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MAKE_BIN="${MAKE:-make}"

run_make_target() {
  echo ""
  echo "==> make $1"
  "$MAKE_BIN" -C "$DOTFILES_DIR" "$1"
}

# Prime sudo. `sudo -v` alone is NOT safe here: on macOS 26 the validate-only
# path goes through a PAM conversation (pam_smartcard before pam_opendirectory)
# that demands a TTY even when NOPASSWD sudoers is configured — observed on the
# mini worker 2026-08-01, where `sudo -n true` succeeded while `sudo -v` and
# `sudo -n -v` both failed without a terminal. Try the noninteractive real
# command first so NOPASSWD/cached-timestamp environments stay headless, and
# fall back to the interactive validate for ordinary local runs.
echo "Requesting sudo access (used by brew/Xcode CLT steps below)..."
sudo -n true 2>/dev/null || sudo -v
(
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" || exit
  done
) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true' EXIT

# Order matters: packages first (TPM's install_plugins needs the tmux
# binary), then language/tool steps, then install-headless (stow + TPM
# plugins), then misc-headless (SSH key + launchd save timer) LAST — the
# launchd timer setup asserts that tmux-resurrect's save.sh already exists,
# which only install-headless creates. headless-doctor is the final gate:
# this script only reaches the success banner if it exits 0.
run_make_target brew-headless
run_make_target python
run_make_target neovim
run_make_target node
run_make_target obsidian
run_make_target install-headless
run_make_target misc-headless
run_make_target headless-doctor

echo ""
echo "OK Headless setup complete!"
echo ""
echo "======================================================================"
echo "This machine is configured for headless/SSH access."
echo "Skipped: SketchyBar, AeroSpace, Login Items, Notifier"
echo "======================================================================"
