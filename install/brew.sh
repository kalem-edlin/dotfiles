#!/bin/bash

# Install Homebrew (skip if already installed)
if ! command -v brew &> /dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

brew update
brew upgrade

# Add taps for third-party packages
brew tap felixkratz/formulae
brew tap supabase/tap
brew tap tursodatabase/tap

# Install packages
apps=(
    atac
    bat
    btop
    cmake
    cmatrix
    cocoapods
    docker
    fastlane
    fzf
    gh
    git
    git-filter-repo
    git-gui
    git-lfs
    glow
    httpd
    jq
    ninja
    pyenv
    rbenv
    sketchybar
    sl
    sshs
    starship
    stow
    supabase/tap/supabase
    telnet
    tmux
    tree
    turso
    watchman
    yarn
    zoxide
    nvm
    zsh-autocomplete
    zsh-autosuggestions
    zsh-vi-mode
)

brew install "${apps[@]}"

# Setup nvm
mkdir -p ~/.nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$(brew --prefix)/opt/nvm/nvm.sh" ] && \. "$(brew --prefix)/opt/nvm/nvm.sh"

# Install latest LTS Node
echo "Installing Node LTS..."
nvm install --lts
nvm alias default 'lts/*'

# Install latest Python
echo "Installing Python latest..."
eval "$(pyenv init -)"
LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d ' ')
pyenv install -s "$LATEST_PYTHON"
pyenv global "$LATEST_PYTHON"

echo "✓ Node LTS and Python $LATEST_PYTHON installed!"
