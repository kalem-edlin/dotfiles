.PHONY: all setup setup-headless setup-headless-darwin setup-headless-unsupported \
	setup-linux-headless setup-linux-headless-run headless-doctor \
	install install-headless brew brew-headless brew-cleanup brew-cleanup-force \
	brew-cleanup-headless brew-cleanup-headless-force \
	neovim node python macos obsidian obsidian-cli misc misc-headless uninstall reload help

# Dotfiles directory (absolute path). Resolved from this Makefile's own
# location (not the caller's cwd) so `make -C somewhere/else -f
# path/to/Makefile ...` and plain `cd dotfiles && make ...` behave
# identically. See docs/tasks/headless-install.md, "Make repository path
# resolution robust".
DOTFILES := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Ensure Homebrew is in PATH (for stow and other tools)
BREW_PREFIX := $(shell if [ -f /opt/homebrew/bin/brew ]; then echo /opt/homebrew; elif [ -f /usr/local/bin/brew ]; then echo /usr/local; fi)
export PATH := $(BREW_PREFIX)/bin:$(PATH)

# Packages that go to ~/.config/ (full local install)
CONFIG_PACKAGES := aerospace ghostty nvim sketchybar tmux

# Packages that use stow (contain dotfiles for ~) (full local install)
STOW_PACKAGES := claude codex git kindavim pi ssh vim worktrees zsh

# Headless variants: CLI-only subsets of the above (no aerospace, ghostty,
# sketchybar, kindavim — GUI/local-specific). Kept as explicit lists rather
# than derived/filtered from CONFIG_PACKAGES/STOW_PACKAGES so the difference
# between local and headless package sets stays visible here, not hidden in
# logic. See docs/tasks/headless-install.md, "Unify the shared local and
# headless setup contract".
HEADLESS_CONFIG_PACKAGES := nvim tmux
HEADLESS_STOW_PACKAGES := claude codex git pi ssh vim worktrees zsh

# App settings paths
CURSOR_USER_DIR := $(HOME)/Library/Application Support/Cursor/User
OBSIDIAN_DIR := $(HOME)/Library/Mobile Documents/iCloud~md~obsidian/Documents/brain/.obsidian
OBSIDIAN_VAULT := $(HOME)/Library/Mobile Documents/iCloud~md~obsidian/Documents/brain

all: help

# Full setup for a new machine
setup:
	@echo "Requesting sudo access..."
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@$(MAKE) brew neovim node obsidian python macos install misc
	@echo ""
	@echo "✓ Setup complete!"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "MANUAL STEPS REQUIRED:"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "1. Disable Spotlight shortcut (Cmd+Space) for Raycast:"
	@echo "   System Settings → Keyboard → Keyboard Shortcuts → Spotlight"
	@echo "   → Uncheck 'Show Spotlight search'"
	@echo ""
	@echo "2. Grant accessibility permissions when prompted for:"
	@echo "   - Raycast, AeroSpace, sketchybar"
	@echo ""
	@echo "3. Grant notification permissions for Notifier:"
	@echo "   System Settings → Notifications"
	@echo "   → Enable notifications for 'Notifier - Notifications' and 'Notifier - Alerts'"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@$(MAKE) reload

# Headless setup for server/agentic hub (no GUI apps, services, or login
# items). Platform-dispatched via prerequisites (NOT a recursive `$(MAKE)`
# call inside this target's own recipe) so `make -n setup-headless` is a
# genuine, non-mutating dry run: GNU Make always executes any recipe LINE
# that textually contains `$(MAKE)`/`${MAKE}`, even under -n, which is
# exactly what made the old compound recipe invoke real sudo during a dry
# run. This target has no recipe of its own, so there is nothing for that
# rule to trigger on. See docs/tasks/headless-install.md, "4. Make the macOS
# Make path fail fast".
#
# Never run as `sudo make setup-headless` — run as the target user. The
# Darwin and Linux lanes below acquire sudo only for their own specific
# privileged steps.
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
setup-headless: setup-headless-darwin
else ifeq ($(UNAME_S),Linux)
setup-headless: setup-linux-headless
else
setup-headless: setup-headless-unsupported
endif

setup-headless-darwin:
	@chmod +x "$(DOTFILES)/setup/macos-headless.sh"
	@"$(DOTFILES)/setup/macos-headless.sh"

setup-headless-unsupported:
	@echo "Unsupported platform: $(UNAME_S)"
	@exit 1

# Linux headless setup without Homebrew or GUI dependencies. headless-doctor
# is a second, gating step run AFTER the script: postflight validation is
# authoritative, not advisory, so this only "succeeds" if the doctor also
# passes. See docs/tasks/headless-install.md, "5. Make package and
# postflight validation authoritative".
setup-linux-headless: setup-linux-headless-run headless-doctor

setup-linux-headless-run:
	@echo "Running Linux headless setup..."
	@chmod +x "$(DOTFILES)/setup/linux-headless.sh"
	@"$(DOTFILES)/setup/linux-headless.sh"

# Read-only postflight validator (auto-detects Darwin/Linux; pass --profile
# explicitly via setup/headless-doctor.sh for local). Exit code propagates:
# do not wrap this in `|| true` anywhere it gates a target.
headless-doctor:
	@chmod +x "$(DOTFILES)/setup/headless-doctor.sh"
	@"$(DOTFILES)/setup/headless-doctor.sh"

# Install all dotfile configurations
## Thin wrapper over setup/lib.sh: each logical step is its own recipe line
## (so Make's normal "abort on nonzero" behavior already gives fail-fast
## semantics — no step here uses `|| true`), sourcing lib.sh fresh each time
## with DOTFILES_DIR set from $(DOTFILES). See docs/tasks/headless-install.md,
## "Unify the shared local and headless setup contract".
install:
	@echo "Installing dotfile configurations..."
	@mkdir -p ~/.config
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; for pkg in $(CONFIG_PACKAGES); do link_config_package "$$pkg"; done'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; install_tmux_plugins'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; ensure_ssh_dirs'
	@# Back up and REMOVE any existing files that would conflict with stow.
	@# This ensures dotfiles repo is authoritative; after stowing, app changes
	@# will flow back to the repo as git unstaged changes via the symlinks.
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; backup_conflicts $(STOW_PACKAGES)'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; stow_packages $(STOW_PACKAGES)'
	@# rw (tmux-remote-workspaces dispatcher) lives inside the tmux plugin;
	@# expose it on PATH so it can be run outside tmux keybindings too
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; link_rw'
	@# Cursor settings
	@if [ -d "$(DOTFILES)/cursor" ]; then \
		echo "  → Linking cursor settings"; \
		for file in settings.json keybindings.json; do \
			if [ -f "$(DOTFILES)/cursor/$$file" ]; then \
				if [ -L "$(CURSOR_USER_DIR)/$$file" ]; then \
					case "$$(readlink "$(CURSOR_USER_DIR)/$$file")" in \
						"$(DOTFILES)"*) echo "    $$file already linked" ;; \
						*) echo "    replacing stale $$file symlink"; rm "$(CURSOR_USER_DIR)/$$file"; ln -s "$(DOTFILES)/cursor/$$file" "$(CURSOR_USER_DIR)/$$file" ;; \
					esac; \
				elif [ -f "$(CURSOR_USER_DIR)/$$file" ]; then \
					echo "    backing up $$file"; \
					mv "$(CURSOR_USER_DIR)/$$file" "$(CURSOR_USER_DIR)/$$file.bak"; \
					ln -s "$(DOTFILES)/cursor/$$file" "$(CURSOR_USER_DIR)/$$file"; \
				else \
					ln -s "$(DOTFILES)/cursor/$$file" "$(CURSOR_USER_DIR)/$$file"; \
				fi \
			fi \
			done \
		fi
	@# Obsidian desktop settings (macOS iCloud vault only)
	@if [ "$$(uname -s)" = "Darwin" ] && [ -d "$(DOTFILES)/obsidian" ]; then \
		echo "  → Linking obsidian settings"; \
		mkdir -p "$(OBSIDIAN_DIR)"; \
		for file in app.json appearance.json core-plugins.json community-plugins.json daily-notes.json hotkeys.json; do \
			if [ -f "$(DOTFILES)/obsidian/$$file" ]; then \
				if [ -L "$(OBSIDIAN_DIR)/$$file" ]; then \
					case "$$(readlink "$(OBSIDIAN_DIR)/$$file")" in \
						"$(DOTFILES)"*) echo "    $$file already linked" ;; \
						*) echo "    replacing stale $$file symlink"; rm "$(OBSIDIAN_DIR)/$$file"; ln -s "$(DOTFILES)/obsidian/$$file" "$(OBSIDIAN_DIR)/$$file" ;; \
					esac; \
				elif [ -f "$(OBSIDIAN_DIR)/$$file" ]; then \
					echo "    backing up $$file"; \
					mv "$(OBSIDIAN_DIR)/$$file" "$(OBSIDIAN_DIR)/$$file.bak"; \
					ln -s "$(DOTFILES)/obsidian/$$file" "$(OBSIDIAN_DIR)/$$file"; \
				else \
					ln -s "$(DOTFILES)/obsidian/$$file" "$(OBSIDIAN_DIR)/$$file"; \
				fi \
			fi \
		done; \
		for plugdir in "$(DOTFILES)"/obsidian/plugins/*/; do \
			[ -d "$$plugdir" ] || continue; \
			plug=$$(basename "$$plugdir"); \
			mkdir -p "$(OBSIDIAN_DIR)/plugins/$$plug"; \
			if [ -f "$$plugdir/data.json" ]; then \
				if [ -L "$(OBSIDIAN_DIR)/plugins/$$plug/data.json" ]; then \
					case "$$(readlink "$(OBSIDIAN_DIR)/plugins/$$plug/data.json")" in \
						"$(DOTFILES)"*) echo "    plugins/$$plug/data.json already linked" ;; \
						*) echo "    replacing stale plugins/$$plug/data.json symlink"; rm "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; ln -s "$$plugdir/data.json" "$(OBSIDIAN_DIR)/plugins/$$plug/data.json" ;; \
					esac; \
				elif [ -f "$(OBSIDIAN_DIR)/plugins/$$plug/data.json" ]; then \
					echo "    backing up plugins/$$plug/data.json"; \
					mv "$(OBSIDIAN_DIR)/plugins/$$plug/data.json" "$(OBSIDIAN_DIR)/plugins/$$plug/data.json.bak"; \
					ln -s "$$plugdir/data.json" "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; \
				else \
					ln -s "$$plugdir/data.json" "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; \
				fi \
			fi \
		done; \
		if [ -f "$(DOTFILES)/obsidian/.obsidian.vimrc" ]; then \
			if [ -L "$(OBSIDIAN_VAULT)/.obsidian.vimrc" ]; then \
				case "$$(readlink "$(OBSIDIAN_VAULT)/.obsidian.vimrc")" in \
					"$(DOTFILES)"*) echo "    .obsidian.vimrc already linked" ;; \
					*) echo "    replacing stale .obsidian.vimrc symlink"; rm "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; ln -s "$(DOTFILES)/obsidian/.obsidian.vimrc" "$(OBSIDIAN_VAULT)/.obsidian.vimrc" ;; \
				esac; \
			elif [ -f "$(OBSIDIAN_VAULT)/.obsidian.vimrc" ]; then \
				echo "    backing up .obsidian.vimrc"; \
				mv "$(OBSIDIAN_VAULT)/.obsidian.vimrc" "$(OBSIDIAN_VAULT)/.obsidian.vimrc.bak"; \
				ln -s "$(DOTFILES)/obsidian/.obsidian.vimrc" "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; \
			else \
				ln -s "$(DOTFILES)/obsidian/.obsidian.vimrc" "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; \
			fi; \
		fi \
	fi
	@chmod 600 "$(DOTFILES)/ssh/.ssh/config" 2>/dev/null || true
	@echo "✓ Dotfiles installed!"

# Install dotfiles for headless setup (CLI-only configs, no GUI apps). Thin
# wrapper over setup/lib.sh, same pattern as `install` above but with the
# headless package lists. Both `install` and `install-headless` now: fail on
# TPM errors (no `|| true`), protect the first .bak on rerun, and link rw.
install-headless:
	@echo "Installing headless dotfile configurations..."
	@mkdir -p ~/.config
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; for pkg in $(HEADLESS_CONFIG_PACKAGES); do link_config_package "$$pkg"; done'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; install_tmux_plugins'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; ensure_ssh_dirs'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; backup_conflicts $(HEADLESS_STOW_PACKAGES)'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; stow_packages $(HEADLESS_STOW_PACKAGES)'
	@DOTFILES_DIR="$(DOTFILES)" bash -euo pipefail -c '. "$(DOTFILES)/setup/lib.sh"; link_rw'
	@chmod 600 "$(DOTFILES)/ssh/.ssh/config" 2>/dev/null || true
	@echo "✓ Headless dotfiles installed!"

# Run headless misc setup (no GUI services or login items)
misc-headless:
	@echo "Running headless miscellaneous setup..."
	@chmod +x setup/misc-headless.sh
	@./setup/misc-headless.sh

# Uninstall all dotfile configurations
uninstall:
	@echo "Removing dotfile configurations..."
	@for pkg in $(CONFIG_PACKAGES); do \
		if [ -L ~/.config/$$pkg ]; then \
			echo "  → Removing $$pkg"; \
			rm ~/.config/$$pkg; \
		fi \
	done
	@for pkg in $(STOW_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			echo "  → Unstowing $$pkg"; \
			stow -D -t ~ $$pkg 2>/dev/null || true; \
		fi \
	done
	@# Obsidian desktop settings (macOS iCloud vault only)
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		echo "  → Removing obsidian settings symlinks"; \
		for file in app.json appearance.json core-plugins.json community-plugins.json daily-notes.json hotkeys.json; do \
			if [ -L "$(OBSIDIAN_DIR)/$$file" ]; then \
				case "$$(readlink "$(OBSIDIAN_DIR)/$$file")" in \
					"$(DOTFILES)"*) \
						rm "$(OBSIDIAN_DIR)/$$file"; \
						if [ -f "$(OBSIDIAN_DIR)/$$file.bak" ]; then \
							mv "$(OBSIDIAN_DIR)/$$file.bak" "$(OBSIDIAN_DIR)/$$file"; \
							echo "    restored $$file from backup"; \
						fi \
						;; \
				esac; \
			fi; \
		done; \
		for plugdir in "$(DOTFILES)"/obsidian/plugins/*/; do \
			[ -d "$$plugdir" ] || continue; \
			plug=$$(basename "$$plugdir"); \
			if [ -L "$(OBSIDIAN_DIR)/plugins/$$plug/data.json" ]; then \
				case "$$(readlink "$(OBSIDIAN_DIR)/plugins/$$plug/data.json")" in \
					"$(DOTFILES)"*) \
						rm "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; \
						if [ -f "$(OBSIDIAN_DIR)/plugins/$$plug/data.json.bak" ]; then \
							mv "$(OBSIDIAN_DIR)/plugins/$$plug/data.json.bak" "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; \
							echo "    restored plugins/$$plug/data.json from backup"; \
						fi \
						;; \
				esac; \
			fi; \
		done; \
		if [ -L "$(OBSIDIAN_VAULT)/.obsidian.vimrc" ]; then \
			case "$$(readlink "$(OBSIDIAN_VAULT)/.obsidian.vimrc")" in \
				"$(DOTFILES)"*) \
					rm "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; \
					if [ -f "$(OBSIDIAN_VAULT)/.obsidian.vimrc.bak" ]; then \
						mv "$(OBSIDIAN_VAULT)/.obsidian.vimrc.bak" "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; \
						echo "    restored .obsidian.vimrc from backup"; \
					fi \
					;; \
			esac; \
		fi \
	fi
	@# Cursor settings
	@echo "  → Removing cursor settings symlinks"
	@for file in settings.json keybindings.json; do \
		if [ -L "$(CURSOR_USER_DIR)/$$file" ]; then \
			rm "$(CURSOR_USER_DIR)/$$file"; \
			if [ -f "$(CURSOR_USER_DIR)/$$file.bak" ]; then \
				mv "$(CURSOR_USER_DIR)/$$file.bak" "$(CURSOR_USER_DIR)/$$file"; \
				echo "    restored $$file from backup"; \
			fi \
		fi \
	done
	@echo "✓ Dotfiles removed!"

# Install Homebrew and all packages from Brewfile
brew:
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@echo "Installing Homebrew packages from Brewfile..."
	@chmod +x setup/brew.sh
	@./setup/brew.sh
	@echo "Installing Cursor extensions..."
	@chmod +x setup/cursor-extensions.sh
	@./setup/cursor-extensions.sh

# Install Homebrew CLI-only packages (no GUI casks)
brew-headless:
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@echo "Installing Homebrew CLI packages (headless)..."
	@chmod +x setup/brew.sh
	@BREWFILE_HEADLESS=1 ./setup/brew.sh

# Show what `brew bundle cleanup` would remove for the full local Brewfile —
# a DRY RUN, nothing is removed. `brew bundle cleanup --force` can delete
# formulae/casks that were installed manually and are simply absent from the
# Brewfile, so this is deliberately opt-in and two-step rather than run
# automatically by `setup`/`setup-headless`. See
# docs/tasks/headless-install.md, "Remove destructive cleanup from ordinary
# setup". Review the plan, then run `make brew-cleanup-force` to apply it.
brew-cleanup:
	@echo "The following would be removed by 'brew bundle cleanup' (dry run; nothing changed):"
	@brew bundle cleanup --file="$(DOTFILES)/Brewfile"
	@echo ""
	@echo "Nothing was removed. Review the list above, then run:"
	@echo "  make brew-cleanup-force"

# DESTRUCTIVE: actually removes packages not in Brewfile. Run `make
# brew-cleanup` first and review its output.
brew-cleanup-force:
	@echo "Removing packages not in Brewfile (forced)..."
	@brew bundle cleanup --file="$(DOTFILES)/Brewfile" --force

# Headless-Brewfile equivalents of the two targets above (Brewfile.headless
# instead of Brewfile). Not run automatically by setup-headless.
brew-cleanup-headless:
	@echo "The following would be removed by 'brew bundle cleanup' (dry run; nothing changed):"
	@brew bundle cleanup --file="$(DOTFILES)/Brewfile.headless"
	@echo ""
	@echo "Nothing was removed. Review the list above, then run:"
	@echo "  make brew-cleanup-headless-force"

brew-cleanup-headless-force:
	@echo "Removing packages not in Brewfile.headless (forced)..."
	@brew bundle cleanup --file="$(DOTFILES)/Brewfile.headless" --force

# Install Neovim Python provider and verify tmux/neovim prerequisites
neovim:
	@echo "Setting up Neovim support..."
	@chmod +x setup/neovim.sh
	@./setup/neovim.sh

# Install Node.js via fnm and global npm packages
node:
	@echo "Installing Node.js and npm packages..."
	@chmod +x setup/node.sh
	@./setup/node.sh

# Install Python via pyenv
python:
	@echo "Installing Python..."
	@chmod +x setup/python.sh
	@./setup/python.sh

# Configure macOS system preferences
macos:
	@echo "Configuring macOS preferences..."
	@chmod +x setup/macos.sh
	@./setup/macos.sh

# Configure Obsidian Headless tooling
obsidian:
	@echo "Configuring Obsidian Headless tooling..."
	@chmod +x setup/obsidian.sh
	@./setup/obsidian.sh

# Backward-compatible alias
obsidian-cli: obsidian

# Miscellaneous setup (Xcode tools, npm config, GitHub CLI check)
misc:
	@echo "Running miscellaneous setup..."
	@chmod +x setup/misc.sh
	@./setup/misc.sh

# Reload all configs
reload:
	@echo "Reloading configurations..."
	@echo "  → aerospace"; aerospace reload-config 2>/dev/null || true
	@echo "  → sketchybar"; sketchybar --reload 2>/dev/null || true
	@echo "  → bat"; bat cache --build 2>/dev/null || true
	@if [ -n "$$TMUX" ]; then \
		echo "  → tmux"; tmux source-file ~/.config/tmux/tmux.conf 2>/dev/null || true; \
	else \
		echo "  → tmux (skipped, not in session)"; \
	fi
	@echo "  → ghostty (restart app manually)"
	@echo "  → neovim (restart app manually)"
	@echo "  → vim (restart app manually)"
	@echo "  → cursor (restart app manually)"
	@echo "  → kindavim (restart app manually)"
	@echo "  → claude (restart app/CLI manually)"
	@echo "  → codex (restart CLI and review /hooks manually)"
	@echo "  → zsh completions"; rm -f ~/.zcompdump* 2>/dev/null || true
	@echo "✓ Configs reloaded!"

help:
	@echo "Dotfiles Management"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  setup           Full setup (brew + node + python + macos + install + misc)"
	@echo "  setup-headless  Platform-aware headless setup for macOS or Linux (never sudo make ...)"
	@echo "  setup-linux-headless  Linux headless setup, then headless-doctor gates success"
	@echo "  install         Symlink dotfiles to ~/.config/, ~, and app settings"
	@echo "  install-headless  CLI-only dotfiles install (no GUI packages)"
	@echo "  headless-doctor  Read-only postflight validator; exit 0 only if the worker contract is met"
	@echo "  uninstall       Remove dotfile symlinks"
	@echo "  brew         Install Homebrew + all packages from Brewfile"
	@echo "  brew-headless  Install Homebrew CLI-only packages (Brewfile.headless)"
	@echo "  brew-cleanup  Show what 'brew bundle cleanup' would remove (dry run)"
	@echo "  brew-cleanup-force  Actually remove packages not in Brewfile (destructive)"
	@echo "  brew-cleanup-headless / brew-cleanup-headless-force  Same, for Brewfile.headless"
	@echo "  neovim      Install pynvim provider and verify Neovim/tmux"
	@echo "  node         Install Node.js (fnm) and global npm packages"
	@echo "  python       Install Python (pyenv)"
	@echo "  macos        Configure macOS system preferences"
	@echo "  obsidian     Configure Obsidian Headless (ob)"
	@echo "  misc         Xcode tools, npm config, GitHub CLI auth check"
	@echo "  reload       Reload all configs (aerospace, sketchybar, bat, tmux)"
	@echo "  help         Show this help message"
