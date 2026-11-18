#!/bin/bash

# Add the aerospace_workspace_change event we specified in aerospace.toml
sketchybar --add event aerospace_workspace_change

# Define allowed workspaces in keyboard order (matches your aerospace.toml keybindings)
ALLOWED_WORKSPACES="1 2 3 4 5 6 7 8 9 0"

# Each workspace chip is: a number item, then a fixed set of app icon slots,
# wrapped in a bracket that draws the chip background. Slots overlap via
# negative padding; plugins/aerospace.sh fills them and hides unused ones.
MAX_APP_ICONS=8
APP_ICON_SIZE=20
# Must match plugins/aerospace.sh
APP_ICON_OVERLAP=6
APP_LINK_SIZE=12

for sid in $ALLOWED_WORKSPACES; do
  sketchybar --add item space.$sid left \
    --subscribe space.$sid aerospace_workspace_change \
    --set space.$sid \
    drawing=on \
    padding_left=0 \
    background.drawing=off \
    icon="$sid" \
    icon.color=$WHITE \
    icon.padding_left=9 \
    icon.padding_right=9 \
    label.drawing=off \
    click_script="aerospace workspace $sid" \
    script="$CONFIG_DIR/plugins/aerospace.sh $sid"

  for n in $(seq 0 $((MAX_APP_ICONS - 1))); do
    sketchybar --add item space.$sid.app.$n left \
      --set space.$sid.app.$n \
      drawing=off \
      icon.drawing=off \
      label.font="sketchybar-app-font:Regular:14.0" \
      label.color=$WHITE \
      label.width=$APP_ICON_SIZE \
      label.align=center \
      label.padding_left=0 \
      label.padding_right=0 \
      label.y_offset=-1 \
      background.drawing=off \
      click_script="aerospace workspace $sid"

    # Link dot on the seam between this icon and the next one
    if [ "$n" -lt $((MAX_APP_ICONS - 1)) ]; then
      sketchybar --add item space.$sid.app.$n.link left \
        --set space.$sid.app.$n.link \
        drawing=off \
        icon.drawing=off \
        label.drawing=off \
        width=$APP_LINK_SIZE \
        padding_right=0 \
        background.drawing=on \
        background.color=$APP_LINK_COLOR \
        background.height=$APP_LINK_SIZE \
        background.y_offset=-1 \
        background.corner_radius=$((APP_LINK_SIZE / 2))
    fi
  done

  sketchybar --add bracket space_chip.$sid space.$sid "/space\\.$sid\\.app\\..*/" \
    --set space_chip.$sid \
    background.color=0x44ffffff \
    background.corner_radius=5 \
    background.drawing=on \
    background.border_color=0xAAFFFFFF \
    background.border_width=0 \
    background.height=24

  # Brackets span their members' padding, so the gap between chips is a spacer
  sketchybar --add item space.$sid.gap left \
    --set space.$sid.gap width=8 padding_left=0 padding_right=0 \
    icon.drawing=off label.drawing=off background.drawing=off
done
