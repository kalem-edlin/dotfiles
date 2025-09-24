#!/bin/bash

# sketchybar --add event aerospace_workspace_change;

# for sid in $(aerospace list-workspaces --all); do
#   echo "sid: $sid"
#   sketchybar --add space space.$sid left                                 \
#   --subscribe "space.$sid" aerospace_workspace_change \
#              --set space.$sid space=$sid                                 \
#                               icon=$sid                                  \
#                               label.font="sketchybar-app-font:Regular:16.0" \
#                               label.padding_right=20                     \
#                               label.y_offset=-1                          \
#                               click_script="aerospace workspace $sid" \
#                               # script="$PLUGIN_DIR/aerospacer.sh"              
# done

# # sketchybar --add item space_separator left                             \
# #            --set space_separator icon="􀆊"                                \
# #                                  icon.color=$ACCENT_COLOR \
# #                                  icon.padding_left=4                   \
# #                                  label.drawing=off                     \
# #                                  background.drawing=off                \
# #                                  script="$PLUGIN_DIR/space_windows.sh" \
# #            --subscribe "space.$sid" aerospace_workspace_change \                  

# Add the aerospace_workspace_change event we specified in aerospace.toml
sketchybar --add event aerospace_workspace_change

# Custom sort function to order workspaces like keyboard numbers (1-9,0)
workspace_order() {
  # Sort numbers so that 0 comes after 9
  sort -n | awk '{if ($1 != "0") print $1} END {system("aerospace list-workspaces --monitor 1 | grep ^0")}'
}

# Process workspaces in keyboard order
for sid in $(aerospace list-workspaces --monitor 1 | workspace_order); do
  sketchybar --add item space.$sid left \
    --subscribe space.$sid aerospace_workspace_change \
    --set space.$sid \
    drawing=off \
    background.color=0x44ffffff \
    background.corner_radius=5 \
    background.drawing=on \
    background.border_color=0xAAFFFFFF \
    background.border_width=0 \
    background.height=24 \
    icon="$sid" \
    icon.padding_left=10 \
    label.font="sketchybar-app-font:Regular:16.0" \
    label.padding_right=20 \
    label.padding_left=0 \
    label.y_offset=-1 \
    click_script="aerospace workspace $sid" \
    script="$CONFIG_DIR/plugins/aerospace.sh $sid"
done

# Load Icons on startup - using same ordering
for sid in $(aerospace list-workspaces --monitor 1 --empty no | workspace_order); do
  apps=$(aerospace list-windows --workspace "$sid" | awk -F'|' '{gsub(/^ *| *$/, "", $2); print $2}')

  sketchybar --set space.$sid drawing=on 

  icon_strip=" "
  if [ "${apps}" != "" ]; then
    while read -r app; do
      icon_strip+=" $($CONFIG_DIR/plugins/icon_map_fn.sh "$app")"
    done <<<"${apps}"
  else
    icon_strip=""
  fi
  sketchybar --set space.$sid label="$icon_strip"
done
