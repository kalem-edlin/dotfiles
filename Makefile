.PHONY: all setup install brew brew-cleanup node python macos misc uninstall reload help

# Dotfiles directory (absolute path)
DOTFILES := $(shell pwd)

# Ensure Homebrew is in PATH (for stow and other tools)
BREW_PREFIX := $(shell if [ -f /opt/homebrew/bin/brew ]; then echo /opt/homebrew; elif [ -f /usr/local/bin/brew ]; then echo /usr/local; fi)
export PATH := $(BREW_PREFIX)/bin:$(PATH)

# Packages that go to ~/.config/
CONFIG_PACKAGES := aerospace ghostty sketchybar tmux

# Packages that use stow (contain dotfiles for ~)
STOW_PACKAGES := claude git kindavim ssh vim zsh

# App settings paths
CURSOR_USER_DIR := $(HOME)/Library/Application Support/Cursor/User

all: help

# Full setup for a new machine
setup:
	@echo "Requesting sudo access..."
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@$(MAKE) brew node python macos install misc
	@echo "✓ Setup complete!"

# Install all dotfile configurations
install:
	@echo "Installing dotfile configurations..."
	@mkdir -p ~/.config
	@for pkg in $(CONFIG_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			if [ -L ~/.config/$$pkg ]; then \
				echo "  → $$pkg already linked"; \
			elif [ -e ~/.config/$$pkg ]; then \
				echo "  ⚠ ~/.config/$$pkg exists (skipping)"; \
			else \
				echo "  → Linking $$pkg → ~/.config/$$pkg"; \
				ln -s "$(DOTFILES)/$$pkg" ~/.config/$$pkg; \
			fi \
		fi \
	done
	@mkdir -p ~/.ssh && chmod 700 ~/.ssh
	@# Back up any existing files that would conflict with stow
	@for pkg in $(STOW_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			for file in $$(find "$(DOTFILES)/$$pkg" -type f 2>/dev/null); do \
				relpath=$${file#$(DOTFILES)/$$pkg/}; \
				target=~/"$$relpath"; \
				if [ -f "$$target" ] && [ ! -L "$$target" ]; then \
					echo "  → Backing up existing $$relpath"; \
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
					echo "    $$file already linked"; \
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
	@chmod 600 "$(DOTFILES)/ssh/.ssh/config" 2>/dev/null || true
	@echo "✓ Dotfiles installed!"

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
	@if [ -n "$$TMUX" ]; then \
		echo "  → tmux"; tmux source-file ~/.config/tmux/tmux.conf 2>/dev/null || true; \
	else \
		echo "  → tmux (skipped, not in session)"; \
	fi
	@echo "  → ghostty (restart app manually)"
	@echo "  → vim (restart app manually)"
	@echo "  → cursor (restart app manually)"
	@echo "✓ Configs reloaded!"
	@echo "  → zsh (restarting shell...)"
	@exec zsh

help:
	@echo "Dotfiles Management"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  setup        Full setup (brew + node + python + macos + install + misc)"
	@echo "  install      Symlink dotfiles to ~/.config/, ~, and app settings"
	@echo "  uninstall    Remove dotfile symlinks"
	@echo "  brew         Install Homebrew + all packages from Brewfile"
	@echo "  brew-cleanup Remove packages not in Brewfile"
	@echo "  node         Install Node.js (fnm) and global npm packages"
	@echo "  python       Install Python (pyenv)"
	@echo "  macos        Configure macOS system preferences"
	@echo "  misc         Xcode tools, npm config, GitHub CLI auth check"
	@echo "  reload       Reload all configs (aerospace, sketchybar, tmux, zsh)"
	@echo "  help         Show this help message"
