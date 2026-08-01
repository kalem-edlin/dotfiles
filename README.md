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

## Headless Linux Setup

For a Linux SSH/headless machine, run the script directly so the first boot does
not depend on `make` already being installed:

```bash
./setup/linux-headless.sh
```

Or, once `make` is available:

```bash
make setup-headless
```

`make setup-headless` is platform-aware: it dispatches to the Linux or macOS
headless lane automatically. See [`docs/headless-workers.md`](docs/headless-workers.md)
for the full operator runbook — preconditions, what success/failure means,
manual steps that stay manual, and how to register a worker with a focus
machine so `rw` can orchestrate it.

The Linux lane uses distro packages instead of Homebrew, then reuses the shared
setup scripts and dotfiles for:

- Stow-managed configs: `claude`, `git`, `pi`, `ssh`, `vim`, `zsh`
- Direct `~/.config` links: `nvim`, `tmux`
- CLI tooling: zsh, tmux, Neovim, Git/Git LFS, Stow, fd/ripgrep/bat/fzf/jq,
  Python/pyenv/pipx, Node/fnm/npm globals, Stripe CLI, Claude Code, Pi tools,
  and `ob`
- Server connectivity/services: Docker and Tailscale by default. Set
  `INSTALL_TAILSCALE=0` only for a deliberately public/LAN-only worker;
  Tailscale authentication (`sudo tailscale up`) remains manual.

GUI/macOS-only packages are intentionally skipped on Linux: AeroSpace,
SketchyBar, Ghostty, KindaVim, macOS defaults, fonts/casks, and login items.

Linux does not mirror the full headless Brewfile. It installs the required
CLI contract shared with macOS (see `docs/tasks/headless-install.md`) plus a
set of guarded conveniences (e.g. eza, bat/batcat, fd/fdfind, Git Delta where
available), rather than every package listed in `Brewfile.headless`. Package
selection lives in `setup/linux-headless.sh`, because package names differ
across apt, dnf, pacman, zypper, and apk.

## Commands

| Command | Description |
|---------|-------------|
| `make setup` | Full setup for a new machine (brew + node + python + macos + misc + install) |
| `make setup-headless` | Platform-aware headless setup for macOS or Linux |
| `make setup-linux-headless` | Linux headless setup without Homebrew or GUI apps |
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
├── ssh/                → ~/.ssh/config           (direct symlink)
├── setup/              # Setup scripts
│   ├── brew.sh         # Homebrew installation and packages
│   ├── linux-headless.sh # Linux headless package/install lane
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
- **Special cases**: SSH config is manually symlinked to a specific location

## New Machine Additions

Look at the following links for new machine additions:
- https://developer.apple.com/download/all/
- https://github.com/beardedspice/beardedspice

  
