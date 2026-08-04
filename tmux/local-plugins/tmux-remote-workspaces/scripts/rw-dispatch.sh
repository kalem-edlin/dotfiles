#!/usr/bin/env bash
# Remote-aware pane commands for @rw-endpoint panes (smoke-journey Bucket 4
# finding, 2026-08-04): the remote Treemux sidebar is a WORKER-side tmux
# split, so the whole remote rectangle is one pane to the local server --
# local nav (prefix h/j/k/l), resize (prefix , . - =), and close (prefix q)
# either do nothing useful or, for q, tear down the entire endpoint when the
# operator only meant to close the sidebar.
#
# Usage: rw-dispatch.sh <left|down|up|right|resize-left|resize-right|
#                        resize-down|resize-up|close> <pane-id>
#
# For a pane bound to an endpoint, forward the equivalent tmux command to the
# worker session over the (ControlMaster-multiplexed) ssh channel; plain
# panes and every fallback path run the stock local command, so bindings can
# call this unconditionally without changing non-remote behavior.
#
# Verdicts from the worker (single word on stdout):
#   forwarded -- the command ran remotely; nothing to do locally.
#   edge      -- nav hit the worker window's boundary (or it has one pane):
#                fall through to LOCAL select-pane so the cursor crosses out
#                of the remote rectangle into the local layout seamlessly.
#   local     -- resize/nav is meaningless remotely (single worker pane whose
#                size tracks the client): run the local command.
#   endpoint  -- close: no sidebar, single worker pane -- the operator means
#                "close this remote pane", i.e. the endpoint (rw-close.sh).
#
# ssh failure on close falls back to rw-close.sh -- identical to the pre-
# dispatch `prefix q` semantics, and rw_close_endpoint_core already handles
# an unreachable worker (tombstone + remote=unreachable_or_absent). The only
# cost: a transient blip while a sidebar is open closes the endpoint instead
# of the sidebar, which is exactly what q did before this script existed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

action="${1:?rw-dispatch: action required}"
pane_id="${2:-${TMUX_PANE:-}}"
[ -n "$pane_id" ] || rw_die "rw-dispatch: no pane specified and TMUX_PANE is unset"

local_fallback() {
  case "$action" in
    left) tmux select-pane -t "$pane_id" -L ;;
    down) tmux select-pane -t "$pane_id" -D ;;
    up) tmux select-pane -t "$pane_id" -U ;;
    right) tmux select-pane -t "$pane_id" -R ;;
    resize-left) tmux resize-pane -t "$pane_id" -L 20 ;;
    resize-right) tmux resize-pane -t "$pane_id" -R 20 ;;
    resize-down) tmux resize-pane -t "$pane_id" -D 7 ;;
    resize-up) tmux resize-pane -t "$pane_id" -U 7 ;;
    close) tmux kill-pane -t "$pane_id" ;;
  esac
}

case "$action" in
  left | down | up | right | resize-left | resize-right | resize-down | resize-up | close) ;;
  *) rw_die "rw-dispatch: unknown action: $action" 64 ;;
esac

endpoint_id="$(rw_pane_get "$pane_id" @rw-endpoint)"
if [ -z "$endpoint_id" ]; then
  local_fallback
  exit $?
fi

endpoint_json="$(rw_read_endpoint "$endpoint_id" 2>/dev/null || true)"
worker="$(printf '%s' "$endpoint_json" | jq -r '.worker // empty' 2>/dev/null)"
if [ -z "$worker" ]; then
  # Stale binding with no registry entry: q should still close the pane via
  # the lifecycle path (which warns and no-ops on the endpoint side); nav and
  # resize just act locally.
  if [ "$action" = "close" ]; then
    exec "$SCRIPT_DIR/rw-close.sh" --pane "$pane_id"
  fi
  local_fallback
  exit $?
fi
session_name="$(rw_session_name "$endpoint_id")"

# Temp-file capture instead of command substitution (mirrors rw-treemux.sh):
# macOS bash 3.2's $() parser chokes on the unbalanced `)` of case patterns
# when a heredoc is attached inside the substitution -- it ends the
# substitution early and executes the rest of the REMOTE script LOCALLY
# (2026-08-05 lockout incident: every dispatched key died on `set -u` before
# reaching local_fallback). bash -n does not catch it; keep heredoc-bearing
# ssh calls out of $() in this plugin.
remote_out="$(mktemp "${TMPDIR:-/tmp}/rw-dispatch.XXXXXX")"
trap 'rm -f "$remote_out"' EXIT
rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
  bash -s -- "$session_name" "$action" >"$remote_out" 2>/dev/null <<'REMOTE_DISPATCH'
set -uo pipefail
session_name="${1:?}"
action="${2:?}"

tmux has-session -t "=$session_name" 2>/dev/null || { echo local; exit 0; }
active="$(tmux display-message -pt "=$session_name:" -F '#{pane_id}' 2>/dev/null)"
panes="$(tmux display-message -pt "=$session_name:" -F '#{window_panes}' 2>/dev/null)"
case "$panes" in *[!0-9]* | '') echo local; exit 0 ;; esac

case "$action" in
  left | down | up | right)
    [ "$panes" -gt 1 ] || { echo edge; exit 0; }
    case "$action" in
      left) flag='-L' edge_fmt='#{pane_at_left}' ;;
      down) flag='-D' edge_fmt='#{pane_at_bottom}' ;;
      up) flag='-U' edge_fmt='#{pane_at_top}' ;;
      right) flag='-R' edge_fmt='#{pane_at_right}' ;;
    esac
    if [ "$(tmux display-message -pt "$active" -F "$edge_fmt")" = "1" ]; then
      echo edge
      exit 0
    fi
    tmux select-pane -t "$active" "$flag"
    echo forwarded
    ;;
  resize-left | resize-right | resize-down | resize-up)
    [ "$panes" -gt 1 ] || { echo local; exit 0; }
    case "$action" in
      resize-left) tmux resize-pane -t "$active" -L 20 ;;
      resize-right) tmux resize-pane -t "$active" -R 20 ;;
      resize-down) tmux resize-pane -t "$active" -D 7 ;;
      resize-up) tmux resize-pane -t "$active" -U 7 ;;
    esac
    echo forwarded
    ;;
  close)
    # Treemux registers panes in GLOBAL options keyed by pane id (upstream
    # scripts/variables.sh): close the sidebar through its own toggle so the
    # registration is torn down, whichever side of the pair holds focus.
    if [ -n "$(tmux show-option -gqv "@-treemux-is-treemux-$active" 2>/dev/null)" ] ||
      [ -n "$(tmux show-option -gqv "@-treemux-registered-pane-$active" 2>/dev/null)" ]; then
      toggle="$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh"
      args="$(tmux show-option -gqv @treemux-key-Tab 2>/dev/null)"
      if [ -x "$toggle" ] && [ -n "$args" ]; then
        "$toggle" "$args" "$active" >/dev/null 2>&1
        echo forwarded
        exit 0
      fi
    fi
    if [ "$panes" -gt 1 ]; then
      # Non-Treemux worker-side split: close just that pane.
      tmux kill-pane -t "$active"
      echo forwarded
      exit 0
    fi
    echo endpoint
    ;;
esac
REMOTE_DISPATCH
ssh_status=$?
verdict="$(cat "$remote_out")"
rm -f "$remote_out"
trap - EXIT

if [ "$action" = "close" ]; then
  case "$verdict" in
    forwarded) exit 0 ;;
    *) exec "$SCRIPT_DIR/rw-close.sh" --pane "$pane_id" ;;
  esac
fi

# Nav/resize: anything other than a clean "forwarded" (edge, single pane,
# unreachable worker, garbled output) degrades to the local command -- worst
# case the cursor moves locally, never a lost keystroke.
if [ "$ssh_status" -eq 0 ] && [ "$verdict" = "forwarded" ]; then
  exit 0
fi
local_fallback
