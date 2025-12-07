#!/usr/bin/env bash

# make sure it's executable with:
# chmod +x ~/.config/sketchybar/plugins/aerospace.sh

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icon_map.sh"

# The workspace ID passed as argument (e.g., "1", "2", etc.)
SID="$1"

# Highlight the focused workspace (border) - icon always white
if [ "$SID" = "$FOCUSED_WORKSPACE" ]; then
    sketchybar --set space.$SID background.border_width=2
else
    sketchybar --set space.$SID background.border_width=0
fi

# Update the app icons for this workspace
apps=$(aerospace list-windows --workspace "$SID" 2>/dev/null | awk -F'|' '{gsub(/^ *| *$/, "", $2); print $2}')

if [ -n "$apps" ]; then
    # Workspace has windows - show with icons and add right padding
    icon_strip=" "
    while read -r app; do
        [ -n "$app" ] && __icon_map "$app" && icon_strip+=" $icon_result"
    done <<< "$apps"
    sketchybar --set space.$SID label="$icon_strip" label.padding_right=15 icon.padding_right=0
else
    # Workspace is empty - symmetric padding around the number
    sketchybar --set space.$SID label="" label.padding_right=0 icon.padding_right=10
fi