#!/bin/bash

sketchybar --add item calendar right \
           --set calendar icon=􀧞  \
           icon.font="SF Pro:Semibold:15.0" \
                          update_freq=30 \
                          script="$PLUGIN_DIR/calendar.sh"
