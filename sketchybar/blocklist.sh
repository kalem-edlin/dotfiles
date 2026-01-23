#!/bin/bash

# Apps to exclude from workspace icons
BLOCKED_APPS=(
  "finder"
  "wispr flow"
)

# Check if app is blocked (case-insensitive)
__is_blocked() {
  local app_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  for blocked in "${BLOCKED_APPS[@]}"; do
    [[ "$app_lower" == "$blocked" ]] && return 0
  done
  return 1
}
