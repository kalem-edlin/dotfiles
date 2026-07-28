#!/bin/bash

# Add the Apple logo item to the left side
sketchybar \
  --add item apple.logo left \
  --set apple.logo icon= \
  icon.font="SF Pro:Semibold:18.0" \
  icon.padding_left=5 \
  icon.padding_right=5 \
  label.drawing=off \
  icon.y_offset=1

# Set default padding for items
sketchybar \
  --default background.padding_left=5 \
  background.padding_right=5 \
  icon.padding_right=5
