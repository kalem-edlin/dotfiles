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
# FAST PATH (2026-08-05 latency + close-cycle incident): a warm multiplexed
# ssh exec to a worker still costs ~200ms (~45ms network RTT); paying that on
# every nav keystroke is unacceptable, so forwarding only happens while a
# worker-side sidebar is actually open, tracked by the LOCAL pane option
# @rw-sidebar-open (set/cleared by rw-treemux.sh from the worker's post-
# toggle pane count, self-healed here whenever a verdict shows <=1 worker
# pane). Hint absent: nav/resize run the stock local command with zero ssh,
# and close goes straight to rw-close.sh.
#
# CLOSE SEMANTICS: q closes the ACTIVE worker pane -- kill-pane, never
# treemux's toggle.sh. The first version detected the sidebar via treemux's
# @-treemux-* global options and closed through toggle.sh; upstream NEVER
# unsets those options (kill_sidebar/liveness is checked via list-panes), so
# after one close the still-set option sent q back into toggle.sh, which
# REOPENED the sidebar -- an uncloseable pane cycling open/close (2026-08-05).
# Do not reintroduce option-sniffing; pane count is the only trustworthy
# worker-side signal.
#
# Verdicts from the worker (stdout: "<verdict> <window-panes>"):
#   forwarded -- the command ran remotely; nothing to do locally.
#   edge      -- nav hit the worker window's boundary (or it has one pane):
#                fall through to LOCAL select-pane so the cursor crosses out
#                of the remote rectangle into the local layout seamlessly.
#   local     -- resize/nav is meaningless remotely (single worker pane whose
#                size tracks the client): run the local command.
#   endpoint  -- close: single worker pane -- the operator means "close this
#                remote pane", i.e. the endpoint (rw-close.sh).
#
# ssh failure on close falls back to rw-close.sh -- identical to the pre-
# dispatch `prefix q` semantics, and rw_close_endpoint_core already handles
# an unreachable worker (tombstone + remote=unreachable_or_absent).

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

# Fast path: no sidebar open means the worker window has one pane whose size
# tracks the client -- nav/resize are local concerns and close means "close
# this endpoint". No ssh round-trip on the common case.
if [ -z "$(rw_pane_get "$pane_id" @rw-sidebar-open)" ]; then
  if [ "$action" = "close" ]; then
    exec "$SCRIPT_DIR/rw-close.sh" --pane "$pane_id"
  fi
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

tmux has-session -t "=$session_name" 2>/dev/null || { echo 'local 1'; exit 0; }
active="$(tmux display-message -pt "=$session_name:" -F '#{pane_id}' 2>/dev/null)"
panes="$(tmux display-message -pt "=$session_name:" -F '#{window_panes}' 2>/dev/null)"
case "$panes" in *[!0-9]* | '') echo 'local 1'; exit 0 ;; esac

case "$action" in
  left | down | up | right)
    [ "$panes" -gt 1 ] || { echo 'edge 1'; exit 0; }
    case "$action" in
      left) flag='-L' edge_fmt='#{pane_at_left}' ;;
      down) flag='-D' edge_fmt='#{pane_at_bottom}' ;;
      up) flag='-U' edge_fmt='#{pane_at_top}' ;;
      right) flag='-R' edge_fmt='#{pane_at_right}' ;;
    esac
    if [ "$(tmux display-message -pt "$active" -F "$edge_fmt")" = "1" ]; then
      echo "edge $panes"
      exit 0
    fi
    tmux select-pane -t "$active" "$flag"
    echo "forwarded $panes"
    ;;
  resize-left | resize-right | resize-down | resize-up)
    [ "$panes" -gt 1 ] || { echo 'local 1'; exit 0; }
    case "$action" in
      resize-left) tmux resize-pane -t "$active" -L 20 ;;
      resize-right) tmux resize-pane -t "$active" -R 20 ;;
      resize-down) tmux resize-pane -t "$active" -D 7 ;;
      resize-up) tmux resize-pane -t "$active" -U 7 ;;
    esac
    echo "forwarded $panes"
    ;;
  close)
    # Close the ACTIVE worker pane, whatever it is -- sidebar, editor, or any
    # other split. Never route through treemux's toggle.sh here (see header).
    if [ "$panes" -gt 1 ]; then
      tmux kill-pane -t "$active"
      echo "forwarded $((panes - 1))"
      exit 0
    fi
    echo 'endpoint 1'
    ;;
esac
REMOTE_DISPATCH
ssh_status=$?
read -r verdict panes_left <"$remote_out" || verdict=""
rm -f "$remote_out"
trap - EXIT

# Self-heal the hint: any verdict reporting <=1 worker pane means the sidebar
# is gone, however it died -- clear @rw-sidebar-open so the next keystroke
# takes the zero-ssh fast path.
case "${panes_left:-}" in
  '' | *[!0-9]*) ;;
  *) [ "$panes_left" -le 1 ] && tmux set-option -p -t "$pane_id" -u @rw-sidebar-open 2>/dev/null ;;
esac

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
