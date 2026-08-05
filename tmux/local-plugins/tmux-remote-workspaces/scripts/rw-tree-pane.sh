#!/usr/bin/env bash
# Pane bootstrap for tree/editor endpoints created by rw-treemux.sh and
# rw-tree-listener.sh. tmux split-window runs this as the new pane's command;
# it stamps the pane's @rw-* cache options (which MUST exist before
# attach-loop starts -- attach-loop's pane_released() check reads
# @rw-endpoint and treats a mismatch as "this pane was returned") and then
# execs into the ordinary attach loop. The endpoint registry entry is written
# by the caller BEFORE the split, so attach-loop finds it immediately.
#
# Usage: rw-tree-pane.sh <endpoint-id>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

endpoint_id="${1:?rw-tree-pane: endpoint id required}"
pane_id="${TMUX_PANE:-}"
[ -n "$pane_id" ] || rw_die "rw-tree-pane: must run inside a tmux pane"

endpoint_json="$(rw_read_endpoint "$endpoint_id")" ||
  rw_die "rw-tree-pane: endpoint $endpoint_id has no registry entry"
worker="$(printf '%s' "$endpoint_json" | jq -r '.worker // empty')"
remote_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.remote_path // empty')"

rw_pane_set "$pane_id" @rw-endpoint "$endpoint_id"
rw_pane_set "$pane_id" @rw-worker "$worker"
rw_pane_set "$pane_id" @rw-workspace "$remote_path"
rw_pane_set "$pane_id" @remote-host "$worker"
rw_pane_set "$pane_id" @workspace-resurrect-skip "1"

exec "$SCRIPT_DIR/attach-loop.sh" "$endpoint_id" --fresh
