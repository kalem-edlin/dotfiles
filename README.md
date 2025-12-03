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
| `make setup` | Full setup for a new machine (brew + node + python + macos + misc + install) |
| `make install` | Symlink all dotfiles to ~/.config/, ~, and app settings |
| `make uninstall` | Remove all dotfile symlinks |
| `make brew` | Install Homebrew and all packages from Brewfile |
| `make brew-cleanup` | Remove packages not in Brewfile |
| `make node` | Install Node.js (fnm) and global npm packages |
| `make python` | Install Python (pyenv) |
| `make macos` | Configure macOS system preferences |
| `make misc` | Xcode tools, npm config, GitHub CLI auth check |
| `make reload` | Reload all configs (aerospace, sketchybar, tmux, zsh) |
| `make help` | Show all available commands |

## Directory Structure

```
dotfiles/
├── aerospace/          → ~/.config/aerospace     (direct symlink)
├── ghostty/            → ~/.config/ghostty       (direct symlink)
├── sketchybar/         → ~/.config/sketchybar    (direct symlink)
├── tmux/               → ~/.config/tmux          (direct symlink)
├── claude/.claude/     → ~/.claude/              (stow)
├── git/                → ~/.gitconfig            (stow)
├── vim/                → ~/.vimrc                (stow)
├── zsh/                → ~/.zshrc                (stow)
├── cursor/             → Cursor User settings     (direct symlink)
│   ├── settings.json   → ~/Library/Application Support/Cursor/User/settings.json
│   └── keybindings.json → ~/Library/Application Support/Cursor/User/keybindings.json
├── ssh/                → ~/.ssh/config           (direct symlink)
├── setup/              # Setup scripts
│   ├── brew.sh         # Homebrew installation and packages
│   ├── node.sh         # Node.js (fnm) and npm packages
│   ├── python.sh       # Python (pyenv)
│   ├── macos.sh        # macOS system preferences
│   └── misc.sh         # Miscellaneous setup (Xcode, npm, GitHub CLI)
├── Brewfile            # Homebrew packages list
├── requirements.txt    # Python packages list
└── Makefile            # Main management script
```

### Symlink Methods

- **Direct symlink**: Packages in `~/.config/` are directly symlinked
- **Stow**: Uses GNU Stow for packages that need files in `~`
- **Special cases**: Cursor and SSH configs are manually symlinked to specific locations

## New Machine Additions

Look at the following links for new machine additions:
- https://developer.apple.com/download/all/
- https://github.com/beardedspice/beardedspice
  
