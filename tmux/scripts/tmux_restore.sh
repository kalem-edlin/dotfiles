#!/usr/bin/env bash
# tmux-restore: run from OUTSIDE tmux after a server loss. Starts the
# server (which fires continuum's restore-on-start -> tmux-resurrect ->
# workspace-resurrect replay), waits for the restored sessions to appear,
# removes its own bootstrap session, and attaches -- so no junk session is
# left to kill by hand. Refuses (with a message) when there is no snapshot
# to restore or when a server with sessions already exists.
set -uo pipefail

resurrect_dir="${HOME}/.local/share/tmux/resurrect"
last="$resurrect_dir/last"

if [ -n "${TMUX:-}" ]; then
  echo "tmux-restore: already inside tmux -- nothing to do" >&2
  exit 1
fi
if [ ! -e "$last" ]; then
  echo "tmux-restore: no restoration history ($last missing) -- nothing to restore" >&2
  exit 1
fi
if tmux has-session 2>/dev/null; then
  echo "tmux-restore: server already has sessions -- use 'tmux attach'" >&2
  exit 1
fi

echo "tmux-restore: restoring $(readlink "$last" 2>/dev/null || echo "$last") ..."
boot="_tmux_restore_boot"
tmux new-session -d -s "$boot"

# Continuum restores on server start; poll for non-bootstrap sessions.
restored=0
elapsed=0
while [ "$elapsed" -lt 90 ]; do
  restored="$(tmux list-sessions -F '#{session_name}' 2>/dev/null |
    grep -cv "^${boot}\$" || true)"
  [ "${restored:-0}" -gt 0 ] && break
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ "${restored:-0}" -eq 0 ]; then
  echo "tmux-restore: no sessions appeared after ${elapsed}s -- check" \
    "~/.local/state/tmux-workspace-resurrect/workspace-resurrect.log;" \
    "leaving bootstrap session '$boot' so the server stays up" >&2
  exit 1
fi

# Give the replay/queue phase a moment to finish typing into panes before
# the bootstrap session (and with it, any restore run-shell) goes away.
sleep 3
tmux kill-session -t "=${boot}" 2>/dev/null || true
echo "tmux-restore: $restored session(s) restored -- attaching"
exec tmux attach
