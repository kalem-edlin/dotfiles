#!/usr/bin/env bash
set -euo pipefail

workspace="${AEROSPACE_FOCUSED_WORKSPACE:-}"

if [[ -z "$workspace" ]]; then
  workspace="$(aerospace list-workspaces --focused)"
fi

if [[ -z "$workspace" ]]; then
  exit 0
fi

aerospace list-windows --monitor all \
  --app-bundle-id com.electron.wispr-flow \
  --format '%{window-id}' |
while IFS= read -r window_id; do
  [[ -z "$window_id" ]] && continue

  aerospace layout floating --window-id "$window_id" >/dev/null 2>&1 || true
  aerospace move-node-to-workspace "$workspace" --window-id "$window_id" >/dev/null 2>&1 || true
done
