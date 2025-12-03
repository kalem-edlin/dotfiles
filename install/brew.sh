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
    tursodatabase/tap/turso
    watchman
    yarn
    zoxide
    nvm
    zsh-autocomplete
    zsh-autosuggestions
    zsh-vi-mode
)

brew install "${apps[@]}"

echo "✓ Homebrew packages installed!"
