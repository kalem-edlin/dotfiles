#!/bin/bash

# Ensure Homebrew is in PATH (required after fresh install)
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# macOS System Preferences Configuration
# Run this script to configure macOS defaults
# Some changes require a logout/restart to take effect

echo "Configuring macOS system preferences..."

# Close any open System Preferences panes to prevent conflicts
osascript -e 'tell application "System Preferences" to quit' 2>/dev/null

###############################################################################
# Menu Bar & Dock                                                             #
###############################################################################

# Automatically hide menu bar - always (shows when cursor moves to top)
defaults write NSGlobalDomain _HIHideMenuBar -bool true

# Position dock at bottom
defaults write com.apple.dock orientation -string "bottom"

# Automatically hide and show the Dock
defaults write com.apple.dock autohide -bool true

# Don't show suggested and recent applications in Dock
defaults write com.apple.dock show-recents -bool false

###############################################################################
# Spotlight                                                                   #
###############################################################################

# NOTE: Disabling Spotlight shortcut (Cmd+Space) requires MANUAL configuration.
# The plist approach below no longer works reliably on modern macOS.
# Manual steps: System Settings → Keyboard → Keyboard Shortcuts → Spotlight
#   → Uncheck or change "Show Spotlight search"

###############################################################################
# General UI/UX                                                               #
###############################################################################

# Disable the "Are you sure you want to open this application?" dialog
defaults write com.apple.LaunchServices LSQuarantine -bool false

# Set sidebar icon size to Large
defaults write NSGlobalDomain NSTableViewDefaultSizeMode -int 3

# Disable automatic capitalization as it's annoying when typing code
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false

# Disable automatic period substitution as it's annoying when typing code
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

###############################################################################
# Screenshots                                                                 #
###############################################################################

# Save screenshots to the desktop
defaults write com.apple.screencapture location -string "$HOME/Desktop"

# Save screenshots in PNG format (other options: BMP, GIF, JPG, PDF, TIFF)
defaults write com.apple.screencapture type png

# Show the mouse pointer in screenshots
defaults write com.apple.screencapture showsCursor -bool true

# Change the default screenshot name
defaults write com.apple.screencapture name "Shot"

###############################################################################
# Finder                                                                      #
###############################################################################

# Finder: show hidden files by default
defaults write com.apple.finder AppleShowAllFiles -bool true

# Finder: show all filename extensions
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Finder: show sidebar
defaults write com.apple.finder ShowSidebar -bool true

# Finder: allow text selection in Quick Look
defaults write com.apple.finder QLEnableTextSelection -bool true

# Keep folders on top when sorting by name
defaults write com.apple.finder _FXSortFoldersFirst -bool true

# When performing a search, search the current folder by default
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

# Disable the warning when changing a file extension
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Enable spring loading for directories
defaults write NSGlobalDomain com.apple.springing.enabled -bool true

# Avoid creating .DS_Store files on network or USB volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Enable Stacks view on the desktop (group by kind)
defaults write com.apple.finder DesktopViewSettings -dict-add GroupBy -string "Kind"

# Disable the warning before emptying the Trash
defaults write com.apple.finder WarnOnEmptyTrash -bool false

# Empty Trash securely by default
defaults write com.apple.finder EmptyTrashSecurely -bool true

# Show the ~/Library folder
chflags nohidden ~/Library 2>/dev/null
xattr -d com.apple.FinderInfo ~/Library 2>/dev/null

# Expand the following File Info panes:
# "General", "More Info", "Open with", "Preview", and "Sharing & Permissions"
defaults write com.apple.finder FXInfoPanesExpanded -dict \
  General -bool true \
  MetaData -bool true \
  OpenWith -bool true \
  Preview -bool true \
  Privileges -bool true

###############################################################################
# Software Updates                                                            #
###############################################################################

# Enable the automatic update check
defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true

# Check for software updates daily, not just once per week
defaults write com.apple.SoftwareUpdate ScheduleFrequency -int 1

# Download newly available updates in background
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 1

# Install system data files & security updates
defaults write com.apple.SoftwareUpdate CriticalUpdateInstall -int 1

###############################################################################
# Preview & Photos                                                            #
###############################################################################

# Do not open previous previewed files (e.g. PDFs) when opening a new one
defaults write com.apple.Preview ApplePersistenceIgnoreState YES

# Prevent Photos from opening automatically when devices are plugged in
defaults -currentHost write com.apple.ImageCapture disableHotPlug -bool true

###############################################################################
# Developer Directory                                                         #
###############################################################################

# Create ~/Developer directory (macOS gives it a special hammer icon)
mkdir -p ~/Developer

# Add Developer folder to Finder sidebar
# mysides is disabled in Homebrew, so we try it if manually installed,
# otherwise provide manual instructions
if command -v mysides &> /dev/null; then
  # Remove existing entry first to avoid duplicates, then add
  mysides remove Developer 2>/dev/null
  mysides add Developer "file://$HOME/Developer"
  echo "✓ Developer folder added to Finder sidebar"
else
  echo "✓ ~/Developer folder created (with hammer icon)"
  echo "  → To add to Finder sidebar: drag ~/Developer to Favorites, or press Cmd+Ctrl+T with it selected"
fi

###############################################################################
# Kill affected applications                                                  #
###############################################################################

echo "Restarting affected applications..."

for app in "Dock" "Finder" "SystemUIServer"; do
  killall "${app}" &> /dev/null
done

echo "✓ macOS preferences configured!"
echo "Note: Some changes require a logout/restart to take effect."
echo "Note: Spotlight shortcut change requires logout to take effect."

