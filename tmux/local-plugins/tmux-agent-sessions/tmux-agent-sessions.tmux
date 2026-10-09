#!/usr/bin/env bash
# Entry point for the tmux-agent-sessions local plugin. Loaded manually from
# tmux.conf before TPM. Agents publish their state into pane options
# (scripts/agent-state, pi/.config/pif/extensions/agent-state.ts); this file
# binds the picker and installs the one tmux-side transition. The memory chip
# is wired after TPM by scripts/wire-mem-chip, because catppuccin rewrites
# status-right when TPM loads.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# display-popup does not format-expand its shell command (tmux 3.7b
# cmd-display-menu.c), so run-shell expands #{client_name} first. The picker
# needs the invoking client to target switch-client. -b keeps the key
# binding's command queue free while the popup is open. run-shell shows any
# non-zero exit in view mode, which traps the client until q, so the command
# always succeeds (the picker also exits 0 on esc). setup/lib.sh builds the
# picker from picker/; until it has, prefix o says so instead. -s gives the
# popup sessionx's background (fzf's bg, catppuccin mocha base); cells with
# their own background keep it. -S puts the same background behind the
# border, which keeps its default line colour.
PICKER="$PLUGIN_DIR/bin/agent-picker"
if [ -x "$PICKER" ]; then
  tmux bind-key o run-shell -b \
    "tmux display-popup -c '#{client_name}' -E -w 90% -h 85% -s 'bg=#1e1e2e' -S 'bg=#1e1e2e' \"'$PICKER' '#{client_name}'\" || true"
else
  tmux bind-key o display-message "agent-picker not built: run make install"
fi

# Visiting a Finished agent marks it Idle and restamps @agent_state_at for the
# status age. Runs inside the server, so a focus change spawns no process: the
# epoch comes from strftime via #{T:@agent_clock}. A fixed array index keeps
# reloads idempotent and leaves other pane-focus-in hooks alone. @agent_at is
# deliberately not touched, so a visit does not reorder the picker's rows.
# Every focus, agent or not, also stamps @pane_focus_at with the
# same epoch, which the picker reads as focus recency (tmux keeps no
# per-pane focus time).
tmux set -g @agent_clock '%s'
tmux set-hook -g 'pane-focus-in[41]' \
  "set -pF @pane_focus_at \"#{T:@agent_clock}\" ; if -F '#{==:#{@agent_state},finished}' 'set -p @agent_state idle ; set -pF @agent_state_at \"#{T:@agent_clock}\"'"
