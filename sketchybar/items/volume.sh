#!/bin/bash

sketchybar --add item volume right \
           --set volume script="$PLUGIN_DIR/volume.sh"  \
                       icon.font="SF Pro:Semibold:15.0" \
           --subscribe volume volume_change 
