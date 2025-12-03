#!/bin/bash

# Install cask packages

apps=(
    aerospace
    android-platform-tools
    arc
    chromium
    cursor
    docker
    docker-desktop
    figma
    font-hack-nerd-font
    font-sf-pro
    ghostty
    kindavim
    ngrok
    raycast
    sf-symbols
    spotify
    superwhisper
)

brew install "${apps[@]}" --cask --adopt
