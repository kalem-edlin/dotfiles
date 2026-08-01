#!/usr/bin/env bash
# Backs the `\` and `/` split bindings (tmux.reset.conf). If the source pane
# is remote-backed, the new pane inherits worker+workspace and becomes its
# own remote endpoint via `rw ensure` (new endpoint id, pane-based ownership
# per the plan's pane/window model). Otherwise, if the source pane is local
# but its WINDOW has a default worker/workspace recorded by a prior `rw
# ensure` in this window (@rw-window-worker/@rw-window-workspace,
# initial-plan.md Resolved decision #2), the new split inherits that window
# default instead. Pane-level values always win over the window default.
# If neither applies, this is an ordinary local split -- unchanged behavior.
#
# Usage: rw-split.sh v|h   (v = split-window -v, h = split-window -h)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

direction="${1:?rw-split: direction (v|h) required}"
split_flag="-v"
[ "$direction" = "h" ] && split_flag="-h"

pane_id="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)}"
[ -n "$pane_id" ] || { tmux split-window "$split_flag"; exit 0; }

current_path="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
endpoint="$(rw_pane_get "$pane_id" @rw-endpoint)"

if [ -n "$endpoint" ]; then
  # Source pane is itself remote-backed -- pane-level values win.
  worker="$(rw_pane_get "$pane_id" @rw-worker)"
  workspace="$(rw_pane_get "$pane_id" @rw-workspace)"
else
  # Source pane is local; fall back to this window's default worker/
  # workspace, if a prior `rw ensure` in this window recorded one.
  worker="$(rw_window_get "$pane_id" @rw-window-worker)"
  workspace="$(rw_window_get "$pane_id" @rw-window-workspace)"
fi

if [ -n "$worker" ]; then
  rw_bin="$SCRIPT_DIR/rw"
  # Fall back to an interactive shell if `rw ensure` returns early (e.g. a
  # preflight failure) instead of leaving the pane dead.
  tmux split-window "$split_flag" -c "$current_path" -t "$pane_id" \
    "\"$rw_bin\" ensure --worker \"$worker\" --workspace \"${workspace:-auto}\"; exec \${SHELL:-/bin/sh} -l"
  exit 0
fi

tmux split-window "$split_flag" -c "$current_path" -t "$pane_id"
