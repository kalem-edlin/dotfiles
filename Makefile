.PHONY: all setup install brew brew-cask brew-all uninstall reload help

# Dotfiles directory (absolute path)
DOTFILES := $(shell pwd)

# Packages that go to ~/.config/
CONFIG_PACKAGES := aerospace ghostty sketchybar tmux

# Packages that use stow (contain dotfiles for ~)
STOW_PACKAGES := claude vim zsh

all: help

# Full setup for a new machine
setup:
	@echo "Requesting sudo access..."
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@$(MAKE) brew brew-cask install
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
	@for pkg in $(STOW_PACKAGES); do \
		if [ -d "$(DOTFILES)/$$pkg" ]; then \
			echo "  → Stowing $$pkg"; \
			stow -t ~ $$pkg 2>/dev/null || echo "    (already stowed or conflict)"; \
		fi \
	done
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
	@echo "✓ Dotfiles removed!"

# Install Homebrew CLI packages
brew:
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@echo "Installing Homebrew packages..."
	@chmod +x install/brew.sh
	@./install/brew.sh
	@echo "✓ Homebrew packages installed!"

# Install Homebrew cask applications
brew-cask:
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@echo "Installing Homebrew cask applications..."
	@chmod +x install/brew-cask.sh
	@./install/brew-cask.sh
	@echo "✓ Cask applications installed!"

# Install all Homebrew packages
brew-all:
	@sudo -v
	@while true; do sudo -n true; sleep 60; kill -0 $$$$ || exit; done 2>/dev/null &
	@$(MAKE) brew brew-cask

# Reload all configs
reload:
	@echo "Reloading configurations..."
	@echo "  → zsh"; source ~/.zshrc 2>/dev/null || true
	@echo "  → aerospace"; aerospace reload-config 2>/dev/null || true
	@echo "  → sketchybar"; sketchybar --reload 2>/dev/null || true
	@if [ -n "$$TMUX" ]; then \
		echo "  → tmux"; tmux source-file ~/.config/tmux/tmux.conf 2>/dev/null || true; \
	else \
		echo "  → tmux (skipped, not in session)"; \
	fi
	@echo "  → ghostty (restart app manually)"
	@echo "  → vim (restart app manually)"
	@echo "✓ Configs reloaded!"

help:
	@echo "Dotfiles Management"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  setup      Full setup (brew + brew-cask + install)"
	@echo "  install    Symlink dotfiles to ~/.config/ and ~ (via stow)"
	@echo "  uninstall  Remove dotfile symlinks"
	@echo "  brew       Install Homebrew CLI packages"
	@echo "  brew-cask  Install Homebrew cask applications"
	@echo "  brew-all   Install all Homebrew packages"
	@echo "  reload     Reload all configs (aerospace, sketchybar, tmux, zsh)"
	@echo "  help       Show this help message"
