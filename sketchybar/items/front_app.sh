#!/bin/bash

sketchybar --add item front_app left \
           --set front_app       background.color=$ACCENT_COLOR \
                                 icon.color=$ACCENT_FOREGROUND_COLOR \
                                 icon.padding_left=2 \
                                 icon.font="sketchybar-app-font:Regular:16.0" \
                                 label.color=$ACCENT_FOREGROUND_COLOR \
                                 script="$PLUGIN_DIR/front_app.sh"            \
           --subscribe front_app front_app_switched
