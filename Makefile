.PHONY: all setup setup-headless install install-headless brew brew-cleanup node python macos misc misc-headless uninstall reload help

# Dotfiles directory (absolute path)
DOTFILES := $(shell pwd)

# Ensure Homebrew is in PATH (for stow and other tools)
BREW_PREFIX := $(shell if [ -f /opt/homebrew/bin/brew ]; then echo /opt/homebrew; elif [ -f /usr/local/bin/brew ]; then echo /usr/local; fi)
export PATH := $(BREW_PREFIX)/bin:$(PATH)

# Packages that go to ~/.config/
CONFIG_PACKAGES := aerospace ghostty sketchybar tmux

# Packages that use stow (contain dotfiles for ~)
STOW_PACKAGES := claude git kindavim pi ssh vim zsh

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
	@$(MAKE) brew node python macos install misc
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

# Headless setup for server/agentic hub (no GUI apps, services, or login items)
setup-headless:
	@echo "Requesting sudo access..."
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@$(MAKE) misc-headless brew-headless node python macos install-headless
	@echo ""
	@echo "Cleaning up non-headless packages..."
	@brew bundle cleanup --file="$(DOTFILES)/Brewfile.headless" --force 2>/dev/null || true
	@echo ""
	@echo "✓ Headless setup complete!"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "This machine is configured for headless/SSH access."
	@echo "Skipped: SketchyBar, AeroSpace, Login Items, Notifier"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Install all dotfile configurations
install:
	@echo "Installing dotfile configurations..."
	@mkdir -p ~/.config
	@for pkg in $(CONFIG_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			if [ -L ~/.config/$$pkg ]; then \
				case "$$(readlink ~/.config/$$pkg)" in \
					"$(DOTFILES)"*) echo "  → $$pkg already linked" ;; \
					*) echo "  → Replacing stale $$pkg symlink"; rm ~/.config/$$pkg; ln -s "$(DOTFILES)/$$pkg" ~/.config/$$pkg ;; \
				esac; \
			elif [ -e ~/.config/$$pkg ]; then \
				echo "  ⚠ ~/.config/$$pkg exists (skipping)"; \
			else \
				echo "  → Linking $$pkg → ~/.config/$$pkg"; \
				ln -s "$(DOTFILES)/$$pkg" ~/.config/$$pkg; \
			fi \
		fi \
	done
	@# Install TPM (tmux plugin manager) if not present
	@if [ ! -d ~/.config/tmux/plugins/tpm ]; then \
		echo "  → Installing TPM (tmux plugin manager)"; \
		git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm; \
	else \
		echo "  → TPM already installed"; \
	fi
	@# Install tmux plugins via TPM
	@if [ -d ~/.config/tmux/plugins/tpm ]; then \
		echo "  → Installing tmux plugins"; \
		TMUX_PLUGIN_MANAGER_PATH=~/.config/tmux/plugins/ ~/.config/tmux/plugins/tpm/bin/install_plugins || true; \
	fi
	@# TPM can't clone commit-pinned plugins on fresh installs — handle manually
	@if [ ! -d ~/.config/tmux/plugins/tmux-sessionx ]; then \
		echo "  → Installing tmux-sessionx (pinned commit)"; \
		git clone https://github.com/omerxx/tmux-sessionx ~/.config/tmux/plugins/tmux-sessionx && \
		cd ~/.config/tmux/plugins/tmux-sessionx && git checkout 3a1911e; \
	fi
	@mkdir -p ~/.ssh && chmod 700 ~/.ssh
	@# Back up and REMOVE any existing files that would conflict with stow
	@# This ensures dotfiles repo is authoritative; after stowing, app changes
	@# will flow back to the repo as git unstaged changes via the symlinks
	@for pkg in $(STOW_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			for file in $$(find "$(DOTFILES)/$$pkg" -type f 2>/dev/null); do \
				relpath=$${file#$(DOTFILES)/$$pkg/}; \
				target=~/"$$relpath"; \
				if [ -L "$$target" ]; then \
					case "$$(readlink "$$target")" in \
						"$(DOTFILES)"*) ;; \
						*) echo "  → Removing stale symlink $$relpath"; rm "$$target" ;; \
					esac; \
				elif [ -e "$$target" ]; then \
					echo "  → Backing up $$relpath"; \
					rm -f "$$target.bak" 2>/dev/null; \
					mv "$$target" "$$target.bak"; \
				fi \
			done \
		fi \
	done
	@for pkg in $(STOW_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			echo "  → Stowing $$pkg"; \
			stow --no-folding --restow -t ~ $$pkg; \
		fi \
	done
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
	@# Obsidian settings
	@if [ -d "$(DOTFILES)/obsidian" ]; then \
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
		for plugdir in $(DOTFILES)/obsidian/plugins/*/; do \
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
		done \
	fi
	@# Obsidian vimrc (lives in vault root, not .obsidian/)
	@if [ -f "$(DOTFILES)/obsidian/.obsidian.vimrc" ]; then \
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
		fi \
	fi
	@chmod 600 "$(DOTFILES)/ssh/.ssh/config" 2>/dev/null || true
	@echo "✓ Dotfiles installed!"

# Install dotfiles for headless setup (CLI-only configs, no GUI apps)
install-headless:
	@echo "Installing headless dotfile configurations..."
	@mkdir -p ~/.config
	@# Only link tmux (skip aerospace, ghostty, sketchybar)
	@if [ -d "$(DOTFILES)/tmux" ]; then \
		if [ -L ~/.config/tmux ]; then \
			case "$$(readlink ~/.config/tmux)" in \
				"$(DOTFILES)"*) echo "  → tmux already linked" ;; \
				*) echo "  → Replacing stale tmux symlink"; rm ~/.config/tmux; ln -s "$(DOTFILES)/tmux" ~/.config/tmux ;; \
			esac; \
		elif [ -e ~/.config/tmux ]; then \
			echo "  ⚠ ~/.config/tmux exists (skipping)"; \
		else \
			echo "  → Linking tmux → ~/.config/tmux"; \
			ln -s "$(DOTFILES)/tmux" ~/.config/tmux; \
		fi \
	fi
	@# Install TPM (tmux plugin manager) if not present
	@if [ ! -d ~/.config/tmux/plugins/tpm ]; then \
		echo "  → Installing TPM (tmux plugin manager)"; \
		git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm; \
	else \
		echo "  → TPM already installed"; \
	fi
	@# Install tmux plugins via TPM
	@if [ -d ~/.config/tmux/plugins/tpm ]; then \
		echo "  → Installing tmux plugins"; \
		TMUX_PLUGIN_MANAGER_PATH=~/.config/tmux/plugins/ ~/.config/tmux/plugins/tpm/bin/install_plugins || true; \
	fi
	@# TPM can't clone commit-pinned plugins on fresh installs — handle manually
	@if [ ! -d ~/.config/tmux/plugins/tmux-sessionx ]; then \
		echo "  → Installing tmux-sessionx (pinned commit)"; \
		git clone https://github.com/omerxx/tmux-sessionx ~/.config/tmux/plugins/tmux-sessionx && \
		cd ~/.config/tmux/plugins/tmux-sessionx && git checkout 3a1911e; \
	fi
	@mkdir -p ~/.ssh && chmod 700 ~/.ssh
	@# Only stow CLI packages (skip kindavim)
	@for pkg in claude git pi ssh vim zsh; do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			for file in $$(find "$(DOTFILES)/$$pkg" -type f 2>/dev/null); do \
				relpath=$${file#$(DOTFILES)/$$pkg/}; \
				target=~/"$$relpath"; \
				if [ -L "$$target" ]; then \
					case "$$(readlink "$$target")" in \
						"$(DOTFILES)"*) ;; \
						*) echo "  → Removing stale symlink $$relpath"; rm "$$target" ;; \
					esac; \
				elif [ -e "$$target" ]; then \
					echo "  → Backing up $$relpath"; \
					rm -f "$$target.bak" 2>/dev/null; \
					mv "$$target" "$$target.bak"; \
				fi \
			done \
		fi \
	done
	@for pkg in claude git pi ssh vim zsh; do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			echo "  → Stowing $$pkg"; \
			stow --no-folding --restow -t ~ $$pkg; \
		fi \
	done
	@# Obsidian settings
	@if [ -d "$(DOTFILES)/obsidian" ]; then \
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
		for plugdir in $(DOTFILES)/obsidian/plugins/*/; do \
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
		done \
	fi
	@# Obsidian vimrc (lives in vault root, not .obsidian/)
	@if [ -f "$(DOTFILES)/obsidian/.obsidian.vimrc" ]; then \
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
		fi \
	fi
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
	@# Obsidian settings
	@echo "  → Removing obsidian settings symlinks"
	@for file in app.json appearance.json core-plugins.json community-plugins.json daily-notes.json hotkeys.json; do \
		if [ -L "$(OBSIDIAN_DIR)/$$file" ]; then \
			rm "$(OBSIDIAN_DIR)/$$file"; \
			if [ -f "$(OBSIDIAN_DIR)/$$file.bak" ]; then \
				mv "$(OBSIDIAN_DIR)/$$file.bak" "$(OBSIDIAN_DIR)/$$file"; \
				echo "    restored $$file from backup"; \
			fi \
		fi \
	done
	@for plugdir in $(DOTFILES)/obsidian/plugins/*/; do \
		plug=$$(basename "$$plugdir"); \
		if [ -L "$(OBSIDIAN_DIR)/plugins/$$plug/data.json" ]; then \
			rm "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; \
			if [ -f "$(OBSIDIAN_DIR)/plugins/$$plug/data.json.bak" ]; then \
				mv "$(OBSIDIAN_DIR)/plugins/$$plug/data.json.bak" "$(OBSIDIAN_DIR)/plugins/$$plug/data.json"; \
				echo "    restored plugins/$$plug/data.json from backup"; \
			fi \
		fi \
	done
	@# Obsidian vimrc
	@if [ -L "$(OBSIDIAN_VAULT)/.obsidian.vimrc" ]; then \
		rm "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; \
		if [ -f "$(OBSIDIAN_VAULT)/.obsidian.vimrc.bak" ]; then \
			mv "$(OBSIDIAN_VAULT)/.obsidian.vimrc.bak" "$(OBSIDIAN_VAULT)/.obsidian.vimrc"; \
			echo "    restored .obsidian.vimrc from backup"; \
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

# Remove packages not in Brewfile
brew-cleanup:
	@echo "Removing packages not in Brewfile..."
	@brew bundle cleanup --file="$(DOTFILES)/Brewfile" --force

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
	@echo "  → vim (restart app manually)"
	@echo "  → cursor (restart app manually)"
	@echo "  → obsidian (restart app manually)"
	@echo "  → kindavim (restart app manually)"
	@echo "  → claude (restart app/CLI manually)"
	@echo "  → zsh completions"; rm -f ~/.zcompdump* 2>/dev/null || true
	@echo "✓ Configs reloaded!"

help:
	@echo "Dotfiles Management"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  setup           Full setup (brew + node + python + macos + install + misc)"
	@echo "  setup-headless  Headless setup for servers (no GUI apps/services)"
	@echo "  install         Symlink dotfiles to ~/.config/, ~, and app settings"
	@echo "  uninstall       Remove dotfile symlinks"
	@echo "  brew         Install Homebrew + all packages from Brewfile"
	@echo "  brew-cleanup Remove packages not in Brewfile"
	@echo "  node         Install Node.js (fnm) and global npm packages"
	@echo "  python       Install Python (pyenv)"
	@echo "  macos        Configure macOS system preferences"
	@echo "  misc         Xcode tools, npm config, GitHub CLI auth check"
	@echo "  reload       Reload all configs (aerospace, sketchybar, bat, tmux)"
	@echo "  help         Show this help message"
