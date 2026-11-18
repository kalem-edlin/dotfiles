#!/usr/bin/env bash

# make sure it's executable with:
# chmod +x ~/.config/sketchybar/plugins/aerospace.sh

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/icon_map.sh"
source "$CONFIG_DIR/blocklist.sh"

# The workspace ID passed as argument (e.g., "1", "2", etc.)
SID="$1"

# Must match items/spaces.sh
MAX_APP_ICONS=8
# How far each app icon slides under the previous one (px)
APP_ICON_OVERLAP=6
APP_LINK_SIZE=12
# Icons back up this far on each side of a link dot, which centers the dot
# on the overlap (keep OVERLAP + LINK_SIZE even)
APP_LINK_SHIFT=$(((APP_ICON_OVERLAP + APP_LINK_SIZE) / 2))

args=()

# Highlight the focused workspace (border on the chip bracket)
if [ "$SID" = "$FOCUSED_WORKSPACE" ]; then
    args+=(--set space_chip.$SID background.border_width=2)
else
    args+=(--set space_chip.$SID background.border_width=0)
fi

# Collect app icons for this workspace
icons=()
apps=$(aerospace list-windows --workspace "$SID" 2>/dev/null | awk -F'|' '{gsub(/^ *| *$/, "", $2); print $2}')
while read -r app; do
    [ -z "$app" ] && continue
    __is_blocked "$app" && continue
    __icon_map "$app" && icons+=("$icon_result")
done <<< "$apps"

count=${#icons[@]}
[ "$count" -gt "$MAX_APP_ICONS" ] && count=$MAX_APP_ICONS

if [ "$count" -gt 0 ]; then
    # Workspace has windows - tighten the number, last icon pads the chip edge
    args+=(--set space.$SID icon.padding_right=4 padding_right=0)
else
    # Workspace is empty - symmetric padding around the number
    args+=(--set space.$SID icon.padding_right=9 padding_right=0)
fi

for ((n = 0; n < MAX_APP_ICONS; n++)); do
    if [ "$n" -lt "$count" ]; then
        left=$([ "$n" -eq 0 ] && echo 0 || echo "-$APP_LINK_SHIFT")
        right=$([ "$n" -eq $((count - 1)) ] && echo 2 || echo "-$APP_LINK_SHIFT")
        args+=(--set space.$SID.app.$n drawing=on label="${icons[$n]}" \
               padding_left="$left" padding_right="$right")
    else
        args+=(--set space.$SID.app.$n drawing=off)
    fi
    # Link dot after icon n: icon n backs up (negative padding_right), the dot
    # takes its width, and icon n+1 backs up again (negative padding_left), so
    # the icons overlap by APP_ICON_OVERLAP with the dot centered on the seam.
    if [ "$n" -lt $((MAX_APP_ICONS - 1)) ]; then
        if [ "$n" -lt $((count - 1)) ]; then
            args+=(--set space.$SID.app.$n.link drawing=on padding_left=0 padding_right=0)
        else
            args+=(--set space.$SID.app.$n.link drawing=off)
        fi
    fi
done

sketchybar "${args[@]}"
