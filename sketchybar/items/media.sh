#!/bin/bash

sketchybar --add item media right \
           --set media label.color=$WHITE \
                       label.max_chars=25 \
                       icon.padding_left=0 \
                       scroll_texts=on \
                       icon=􀑪             \
                       icon.color=$WHITE   \
                       background.drawing=off \
                       script="$PLUGIN_DIR/media.sh" \
                       update_freq=5
