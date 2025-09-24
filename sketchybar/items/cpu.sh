#!/bin/bash

sketchybar --add item cpu right \
           --set cpu  update_freq=2 \
           icon.font="SF Pro:Semibold:15.0" \
                      icon=􀧓  \
                      script="$PLUGIN_DIR/cpu.sh"
