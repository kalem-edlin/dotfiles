# Dotfiles

My personal dotfiles.

## Quick Start (New Machine Setup)

```bash
make setup
```

This will:
1. Install Homebrew and all CLI packages
2. Install cask GUI applications
3. Symlink all configurations

## Commands

| Command | Description |
|---------|-------------|
| `make setup` | Full setup for a new machine |
| `make install` | Symlink all dotfiles |
| `make uninstall` | Remove all symlinks |
| `make brew` | Install Homebrew CLI packages |
| `make brew-cask` | Install Homebrew cask applications |
| `make brew-all` | Install all Homebrew packages |

## Structure

```
dotfiles/
├── aerospace/      → ~/.config/aerospace     (direct symlink)
├── ghostty/        → ~/.config/ghostty       (direct symlink)
├── sketchybar/     → ~/.config/sketchybar    (direct symlink)
├── tmux/           → ~/.config/tmux          (direct symlink)
├── claude/.claude/ → ~/.claude/              (stow)
├── vim/.vimrc      → ~/.vimrc                (stow)
├── zsh/.zshrc      → ~/.zshrc                (stow)
├── install/
│   ├── brew.sh         # Homebrew CLI packages
│   └── brew-cask.sh    # Homebrew cask apps
└── Makefile
```

## New Machine Additions

Look at the following links for new machine additions:
- https://developer.apple.com/download/all/
- https://github.com/beardedspice/beardedspice
  
