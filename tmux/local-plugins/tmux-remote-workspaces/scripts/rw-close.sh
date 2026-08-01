#!/usr/bin/env bash
# `rw close` -- lifecycle-aware intentional close of a remote-backed pane.
#
# Order matters (initial-plan.md, "Endpoint lifetime follows user intent"):
#   1. Write the tombstone FIRST, so a crash mid-cleanup can never let an
#      older resurrect snapshot revive a deliberately closed endpoint.
#   2. Release/remove the registry entry.
#   3. Kill the remote endpoint session, best-effort (unreachable worker is
#      fine -- the tombstone makes this reconcilable later).
#   4. Close the local pane (unless --no-kill-pane, used by window-close so
#      the caller's own kill-window can finish the job).
#
# Never deletes a workspace/checkout. Reflected slots are never touched; ad
# hoc checkout removal is explicitly out of scope this wave (Resolved
# decision #3) -- the checkout is retained and left for `rw status`/`doctor`
# to surface.
#
# Usage: rw-close.sh [--pane <pane-id>] [--no-kill-pane] [--reason <text>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

pane_id="${TMUX_PANE:-}"
kill_pane="true"
reason="prefix+q"

while [ $# -gt 0 ]; do
  case "$1" in
    --pane) pane_id="${2:?}"; shift 2 ;;
    --no-kill-pane) kill_pane="false"; shift ;;
    --reason) reason="${2:?}"; shift 2 ;;
    *) rw_die "rw close: unknown argument: $1" 64 ;;
  esac
done

[ -n "$pane_id" ] || rw_die "rw close: no pane specified and TMUX_PANE is unset"

endpoint_id="$(rw_pane_get "$pane_id" @rw-endpoint)"
if [ -z "$endpoint_id" ]; then
  rw_warn "rw close: pane $pane_id has no @rw-endpoint; nothing to close."
  exit 0
fi

# 1-3. Tombstone, release the registry entry, best-effort remote teardown --
# shared with libexec/reconcile's orphan disposal and attach-loop.sh's
# remote-intentional-close discrimination so this ordering exists in one
# place (common.sh).
rw_close_endpoint_core "$endpoint_id" "$reason"

rw_pane_unset "$pane_id" @rw-endpoint
rw_pane_unset "$pane_id" @rw-worker
rw_pane_unset "$pane_id" @rw-workspace
rw_pane_unset "$pane_id" @remote-host
rw_pane_unset "$pane_id" @workspace-resurrect-skip

# 4. Close the local pane.
if [ "$kill_pane" = "true" ]; then
  tmux kill-pane -t "$pane_id" 2>/dev/null || true
fi
