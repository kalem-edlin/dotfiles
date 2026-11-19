#!/usr/bin/env bash
# Backs the `\` and `/` split bindings (tmux.reset.conf). A split ALWAYS
# follows the host of the pane it was invoked from (D21): if the source pane
# is remote-backed (its attach loop runs: @remote-host), the new pane opens
# on the same remote, in the source pane's live directory (rw_pane_dir), via
# `rw switch` run inside the new pane -- an owned endpoint when that remote
# owns the directory (the `rw open` path), a visit endpoint otherwise, so an
# off-owner pane splits onto its own remote too. If the source pane is local,
# this is an ordinary local split, even when a sibling pane in the same
# window is remote-backed. The original window-default inheritance was
# dropped on 2026-08-03 during manual smoke testing: splitting from a local
# pane must never produce a remote pane.
#
# Usage: rw-split.sh v|h [pane-id]   (v = split-window -v, h = split-window -h)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

direction="${1:?rw-split: direction (v|h) required}"
split_flag="-v"
[ "$direction" = "h" ] && split_flag="-h"

pane_id="${2:-${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)}}"
[ -n "$pane_id" ] || { tmux split-window "$split_flag"; exit 0; }

# Side-by-side splits start 20 columns smaller than half. Set the size at
# creation so the source chat never sees a transient half-width pane.
# Stacked splits retain tmux's default equal split.
split_args=("$split_flag")
if [ "$direction" = "h" ]; then
  pane_size="$(tmux display-message -pt "$pane_id" -F '#{pane_width}')"
  new_size=$(( (pane_size - 1) / 2 - 20 ))
  # Keep small panes splittable when the 20-column offset would not fit.
  [ "$new_size" -ge 1 ] || new_size=1
  split_args+=(-l "$new_size")
fi

current_path="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
endpoint="$(rw_pane_get "$pane_id" @rw-endpoint)"
worker="$(rw_pane_get "$pane_id" @remote-host)"

if [ -n "$endpoint" ] && [ -n "$worker" ]; then
  # Source pane is itself remote-backed: the new pane opens on the same
  # remote in the source pane's live directory. The split is made at once,
  # starting locally in the title-based directory (no ssh here: the key
  # binding never waits on it); `rw switch --dir-of` in the new pane asks
  # the remote (fix wave A, finding 9). Fall back to an interactive shell if
  # `rw switch` returns (e.g. the remote is unreachable) instead of leaving
  # the pane dead.
  dir="$(rw_pane_dir "$pane_id")"
  cmd="$(printf '%q switch --to %q --dir-of %q' "$SCRIPT_DIR/rw" "$worker" "$pane_id")"
  tmux split-window "${split_args[@]}" -c "$(rw_local_existing_dir "$dir")" -t "$pane_id" \
    "$cmd; exec \${SHELL:-/bin/sh} -l"
  exit 0
fi

tmux split-window "${split_args[@]}" -c "$current_path" -t "$pane_id"
