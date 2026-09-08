#!/usr/bin/env bash
# Show a tmux-native, dismissible dialog without using the status/message row.
#
# Usage: dialog.sh [--pane <pane-id>] [--title <title>] -- <message>
# Any key dismisses the popup. When no attached tmux client can host a popup,
# the message is printed to stderr so headless callers still get diagnostics.

set -uo pipefail

decode_payload() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

if [ "${1:-}" = "--render" ]; then
  payload="${2:-}"
  message="$(printf '%s' "$payload" | decode_payload 2>/dev/null || true)"
  printf '\n'
  while IFS= read -r line || [ -n "$line" ]; do
    printf '  %s\n' "$line"
  done <<<"$message"
  printf '\n  Press any key to dismiss.\n'
  read -r -s -n 1 2>/dev/null </dev/tty || true
  exit 0
fi

pane_id=""
title="Notice"
while [ $# -gt 0 ]; do
  case "$1" in
    --pane) pane_id="${2:?}"; shift 2 ;;
    --title) title="${2:?}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
message="$*"

if [ -z "$pane_id" ]; then
  pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

if [ -z "$pane_id" ] || ! tmux list-clients >/dev/null 2>&1; then
  printf '%s: %s\n' "$title" "$message" >&2
  exit 1
fi

payload="$(printf '%s' "$message" | base64 | tr -d '\n')"
script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
printf -v popup_command '%q --render %q' "$script_path" "$payload"

tmux display-popup -E -t "$pane_id" -w 70% -h 30% -T " $title " "$popup_command" 2>/dev/null || {
  printf '%s: %s\n' "$title" "$message" >&2
  exit 1
}
