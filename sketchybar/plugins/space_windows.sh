#!/bin/bash

source "$CONFIG_DIR/icon_map.sh"
source "$CONFIG_DIR/blocklist.sh"

if [ "$SENDER" = "aerospace_workspace_change" ]; then
  space="$(echo "$INFO" | jq -r '.space')"
  apps="$(echo "$INFO" | jq -r '.apps | keys[]')"

  icon_strip=" "
  if [ "${apps}" != "" ]; then
    while read -r app
    do
      __is_blocked "$app" && continue
      __icon_map "$app"
      icon_strip+=" $icon_result"
    done <<< "${apps}"

    # If we filtered everything out, show empty dash
    if [ "$icon_strip" = " " ]; then
      icon_strip=" —"
    fi
  else
    icon_strip=" —"
  fi

  sketchybar --set space.$space label="$icon_strip"
fi
