#!/bin/bash

# Try Spotify first, then Music
if pgrep -x "Spotify" > /dev/null && [ "$(osascript -e 'tell application "Spotify" to player state' 2>/dev/null)" = "playing" ]; then
  TITLE=$(osascript -e 'tell application "Spotify" to name of current track' 2>/dev/null)
  ARTIST=$(osascript -e 'tell application "Spotify" to artist of current track' 2>/dev/null)
  sketchybar --set "$NAME" label="$TITLE - $ARTIST" drawing=on
elif pgrep -x "Music" > /dev/null && [ "$(osascript -e 'tell application "Music" to player state' 2>/dev/null)" = "playing" ]; then
  TITLE=$(osascript -e 'tell application "Music" to name of current track' 2>/dev/null)
  ARTIST=$(osascript -e 'tell application "Music" to artist of current track' 2>/dev/null)
  sketchybar --set "$NAME" label="$TITLE - $ARTIST" drawing=on
else
  sketchybar --set "$NAME" drawing=off
fi
