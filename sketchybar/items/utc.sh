#!/bin/bash

sketchybar --add item utc right \
           --set utc label.color=$WHITE_DIM \
                     icon.drawing=off \
                     padding_left=0 \
                     label.padding_left=0 \
                     update_freq=30 \
                     script="$PLUGIN_DIR/utc.sh"
