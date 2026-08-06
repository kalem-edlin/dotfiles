#!/usr/bin/env bash
# Backs the remote-backed branch of the `prefix [` / `prefix PPage`
# bindings (tmux-remote-workspaces.tmux): enter copy-mode in the
# WORKER-side pane behind a remote-backed local pane.
#
# Endpoint sessions are created with `prefix None` (rw_create_remote_session
# in common.sh): the inner tmux is a headless display layer that deliberately
# intercepts no keys, so forwarding a prefix sequence can never work --
# 2026-08-06 finding: `send-keys C-a [` just typed a literal '[' into the
# remote shell. Instead, enter copy-mode server-side over ssh. Once the
# inner pane is IN copy-mode, the operator's raw keystrokes (vi motions,
# search, y, q) flow through the ssh tty straight into that mode -- entry is
# the only action needing a round trip, and it rides the persistent
# ControlMaster socket. Scrolling then operates on the worker pane's real
# history; the outer pane's local scrollback (rw ensure output, pre-attach
# noise) never appears.
#
# Usage: rw-copy-mode.sh <pane-id> [--page-up]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

pane_id="${1:?pane id required}"
page_up="${2:-}"

endpoint_id="$(rw_pane_get "$pane_id" @rw-endpoint)"
worker="$(rw_pane_get "$pane_id" @rw-worker)"
if [ -z "$endpoint_id" ] || [ -z "$worker" ]; then
  tmux display-message "rw copy-mode: pane $pane_id has no endpoint cache -- falling back to local copy-mode"
  tmux copy-mode -t "$pane_id"
  exit 0
fi

session_name="$(rw_session_name "$endpoint_id")"
flags=""
[ "$page_up" = "--page-up" ] && flags=" -u"

rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
  "tmux copy-mode$flags -t '$session_name'" >/dev/null 2>&1 ||
  tmux display-message "rw copy-mode: could not reach worker '$worker' (endpoint $endpoint_id)"
