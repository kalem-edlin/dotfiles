#!/usr/bin/env bash
# Backs the `\` and `/` split bindings (tmux.reset.conf). A split ALWAYS
# follows the host of the pane it was invoked from: if the source pane is
# remote-backed, the new pane inherits worker+workspace and becomes its own
# remote endpoint via `rw ensure` (new endpoint id, pane-based ownership per
# the plan's pane/window model); if the source pane is local, this is an
# ordinary local split -- even when a sibling pane in the same window is
# remote-backed. (The original window-default inheritance of Resolved
# decision #2 was dropped 2026-08-03 by operator decision during manual
# smoke: splitting from a local pane must never produce a remote pane.)
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

worker=""
workspace=""
if [ -n "$endpoint" ]; then
  # Source pane is itself remote-backed -- inherit its worker+workspace.
  worker="$(rw_pane_get "$pane_id" @rw-worker)"
  workspace="$(rw_pane_get "$pane_id" @rw-workspace)"
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
