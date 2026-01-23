#!/bin/bash

source "$CONFIG_DIR/icon_map.sh"
source "$CONFIG_DIR/blocklist.sh"

# Add the aerospace_workspace_change event we specified in aerospace.toml
sketchybar --add event aerospace_workspace_change

# Define allowed workspaces in keyboard order (matches your aerospace.toml keybindings)
ALLOWED_WORKSPACES="1 2 3 4 5 7 8 9 0"

# Create space items for all allowed workspaces
for sid in $ALLOWED_WORKSPACES; do
  sketchybar --add item space.$sid left \
    --subscribe space.$sid aerospace_workspace_change \
    --set space.$sid \
    drawing=on \
    background.color=0x44ffffff \
    background.corner_radius=5 \
    background.drawing=on \
    background.border_color=0xAAFFFFFF \
    background.border_width=0 \
    background.height=24 \
    icon="$sid" \
    icon.color=$WHITE \
    icon.padding_left=9 \
    icon.padding_right=9 \
    label.font="sketchybar-app-font:Regular:14.0" \
    label.padding_right=0 \
    label.padding_left=0 \
    label.y_offset=-1 \
    click_script="aerospace workspace $sid" \
    script="$CONFIG_DIR/plugins/aerospace.sh $sid"
done

# Load app icons on startup for non-empty workspaces
for sid in $ALLOWED_WORKSPACES; do
  apps=$(aerospace list-windows --workspace "$sid" 2>/dev/null | awk -F'|' '{gsub(/^ *| *$/, "", $2); print $2}')

  if [ -n "$apps" ]; then
    icon_strip=" "
    while read -r app; do
      [ -z "$app" ] && continue
      __is_blocked "$app" && continue
      __icon_map "$app" && icon_strip+=" $icon_result"
    done <<<"${apps}"

    # Only set if we have icons
    if [ "$icon_strip" != " " ]; then
      sketchybar --set space.$sid label="$icon_strip" label.padding_right=14 icon.padding_right=0
    fi
  fi
done
