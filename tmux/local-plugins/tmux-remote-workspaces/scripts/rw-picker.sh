#!/usr/bin/env bash
# Backs the `prefix e` binding (tmux.reset.conf): ONE display-popup whose
# direction is decided by the focused (origin) pane's @remote-host
# (docs/tasks/remote-owned-directories.md, D12). The unit is a directory root
# (P1): a worktree's git toplevel, or a plain folder, and every pane working
# inside it moves together.
#
#   1. Remote pane (@remote-host set) -> "hand <root> back to this
#      machine? (y/n)", then `rw bg handback --pane <origin>`.
#   2. Local pane in a root that is already remote (the frozen local copy,
#      D17) -> "open this pane remote in <root>? (y/n)", then
#      `rw open --pane <origin>`. Only from a shell prompt: rw open replaces
#      the pane's process.
#   3. Any other local pane -> the worker chooser, its header naming the
#      resolved root and how many panes move (and warning about unsaved
#      editor buffers), then `rw bg handoff --worker <alias> --pane <origin>`.
#
# Handoff and hand-back run in the BACKGROUND (libexec/rw-bg): once the
# choice is made, rw bg checks the root and returns, and the popup closes at
# once, so the client is free while the transfer runs. Progress shows in the
# status line (@rw-transfer chip) and display-message; a conflict or failure
# opens its dialog from the runner. A refusal rw bg finds synchronously is
# shown here, inline. `rw open` (no sync, quick) still runs in the popup.
#
# rw is always RUN from here, never typed into a pane with send-keys: a
# remote pane's foreground is an ssh PTY into the worker, where anything
# typed runs on the worker's own shell (2026-08-05). TMUX_PANE is unset for
# the run, so rw takes its --pane branch (respawn that pane) instead of
# exec-ing the popup into an attach loop.
#
# Exit codes from rw open (scripts/rw usage): 5 -> the conflict dialog
# (libexec/rw-dialogs.sh, shared with the background runner: the files
# from rw's `conflict<TAB>path<TAB>kind` stdout lines, a screenful at most,
# then abort / keep both / overwrite, abort first so a stray enter moves
# nothing; the last two re-run with --resolve), 6 -> "worker unreachable",
# 2/3/7 and anything else -> the dismissible failure dialog with one cause
# line and one action line. Refusals the picker finds itself are shown the
# same way, inline: display-popup from inside this popup is a no-op (tmux
# draws one overlay per client), so rw_dialog cannot be used.
#
# Modes (self-invocations; the binding only ever calls `pick`):
#   pick    act on the focused pane
#   list    emit worker lines instantly (reachability column pending)
#   probe   emit the same lines with live online/offline status
#
# The worker list renders immediately via `list`; fzf's start event reloads
# it from `probe` (parallel `ssh -o BatchMode=yes` probes bounded by the
# config's status timeout), so reachability fills in without delaying the
# popup. Typed text that matches no listed worker is passed through as an
# alias on enter (--print-query); rw rejects aliases not in config.json.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"
# shellcheck source=../libexec/rw-dialogs.sh
source "$SCRIPT_DIR/../libexec/rw-dialogs.sh"

mode="${1:-pick}"
RW_BIN="$SCRIPT_DIR/rw"

worker_line() { # alias platform status notes
  printf '%s\t[%s]\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

list_workers() {
  jq -r '.workers[] | [.alias, .platform, (.notes // "")] | @tsv' "$RW_CONFIG_FILE" |
    while IFS=$'\t' read -r alias platform notes; do
      worker_line "$alias" "$platform" "…" "$notes"
    done
}

# Each probe prints its own finished line (one printf, atomic well under
# PIPE_BUF) so fzf's reload streams results in completion order: reachable
# workers appear in ~a round trip instead of every row waiting out the
# slowest host's timeout (2026-08-05).
probe_workers() {
  local alias platform notes
  while IFS=$'\t' read -r alias platform notes; do
    (
      if rw_ssh_batch "$alias" "$(rw_ssh_status_timeout)" true >/dev/null 2>&1; then
        worker_line "$alias" "$platform" "online" "$notes"
      else
        worker_line "$alias" "$platform" "offline" "$notes"
      fi
    ) &
  done < <(jq -r '.workers[] | [.alias, .platform, (.notes // "")] | @tsv' "$RW_CONFIG_FILE")
  wait
}

# rw_pick_worker_menu <prompt> <header>
# fzf over the worker list. Prints the chosen (or typed, unmatched) alias;
# prints nothing and returns 1 on abort (esc/ctrl-c) or an empty pick.
rw_pick_worker_menu() {
  local prompt="$1" header="$2" out status sel alias
  out="$(list_workers | fzf \
    --layout=reverse --info=inline \
    --prompt="$prompt" \
    --header="$header" \
    --delimiter=$'\t' \
    --print-query \
    --bind "start:reload:$0 probe")"
  status=$?
  case "$status" in
    0) sel="$(printf '%s\n' "$out" | tail -n1)" ;; # picked a listed worker
    1) sel="$(printf '%s\n' "$out" | head -n1)" ;; # typed alias, no match
    *) return 1 ;;                                 # aborted (esc / ctrl-c)
  esac
  alias="${sel%%$'\t'*}"
  alias="${alias//[[:space:]]/}"
  [ -n "$alias" ] || return 1
  printf '%s\n' "$alias"
}

# rw_pick_yes <question> -- "<question> (y/n)" on the popup tty; 0 on y.
rw_pick_yes() {
  local key=""
  printf '\n  %s (y/n) ' "$1"
  read -r -s -n 1 key 2>/dev/null </dev/tty || true
  printf '%s\n' "$key"
  case "$key" in y | Y) return 0 ;; esac
  return 1
}

# rw_pick_tilde <path> -- ~/... under $HOME, for display only.
# shellcheck disable=SC2088 # a literal ~ is the point
rw_pick_tilde() {
  case "$1" in
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# rw_pick_plural <n> <noun> -- "1 pane", "3 panes".
rw_pick_plural() { rw_dlg_plural "$@"; }

# rw_pick_notice <title> <message> -- an inline dismissible notice in this
# popup. Not rw_dialog: that opens a display-popup, and tmux keeps one
# overlay per client (cmd-display-menu.c returns early while
# c->overlay_draw is set), so from inside this popup it would draw nothing.
rw_pick_notice() {
  printf '\n\033[1m%s\033[0m\n' "$1"
  printf '%s\n' "$2" | fold -s -w "$(rw_pick_cols)" | sed 's/^/  /'
  printf '\n  [press any key to dismiss]\n'
  read -r -s -n 1 2>/dev/null </dev/tty || true
}

# rw_pick_cols -- the popup's width less a margin, for wrapping notices.
rw_pick_cols() {
  local cols
  cols="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  case "$cols" in '' | *[!0-9]*) cols=80 ;; esac
  [ "$cols" -gt 20 ] || cols=80
  printf '%d\n' $((cols - 4))
}

# Run rw with its output live in the popup and captured in $RW_PICK_OUT.
# rw's `conflict<TAB>...` stdout lines (exit 5; possibly thousands) are
# captured but not echoed: the conflict dialog shows a screenful of them.
RW_PICK_OUT=""
rw_pick_run() {
  local status
  RW_PICK_OUT="$(mktemp "${TMPDIR:-/tmp}/rw-picker-run.XXXXXX")"
  env -u TMUX_PANE "$RW_BIN" "$@" </dev/null 2>&1 | tee "$RW_PICK_OUT" | grep -v $'^conflict\t'
  status=${PIPESTATUS[0]}
  return "$status"
}

# rw_pick_transfer <verb> <args...>
# `rw <verb> <args...>`; on exit 5 shows the conflict dialog and re-runs
# with the chosen --resolve; any other failure gets the failure dialog.
rw_pick_transfer() {
  local verb="$1" status choice
  shift
  rw_pick_run "$verb" "$@"
  status=$?
  if [ "$status" -eq 5 ] && ! grep -q $'^conflict\t' "$RW_PICK_OUT"; then
    # rw promised a list on exit 5; with none there is nothing to choose
    # between, so say so and move nothing.
    \rm -f "$RW_PICK_OUT"
    rw_pick_notice "rw $verb stopped" "rw reported files changed on the copy being overwritten but listed none; nothing moved. Run 'rw $verb' from a shell to see its output."
    return 5
  fi
  if [ "$status" -eq 5 ]; then
    choice="$(rw_pick_conflict_dialog "$verb" "$RW_PICK_OUT")"
    \rm -f "$RW_PICK_OUT"
    case "$choice" in
      overwrite | keep-both)
        printf '\n'
        rw_pick_run "$verb" "$@" --resolve "$choice"
        status=$?
        ;;
      *)
        printf '\n  %s aborted; nothing moved.\n' "rw $verb"
        sleep 1
        return 5
        ;;
    esac
  fi
  if [ "$status" -ne 0 ]; then
    rw_pick_failure_dialog "rw $verb" "$status" "$RW_PICK_OUT"
  fi
  \rm -f "$RW_PICK_OUT"
  return "$status"
}

# rw_pick_conflict_dialog <verb> <out_file> -- the shared conflict dialog
# (libexec/rw-dialogs.sh). Prints overwrite, keep-both, or nothing.
rw_pick_conflict_dialog() { rw_conflict_dialog "$@"; }

# Hold the popup open as a dismissible DIALOG explaining the failure in one
# cause line and one action line. Never a status-bar display-message:
# refusals flashed there were unreadable (2026-08-05, 2026-08-06; operator
# 2026-08-08: "a dialog I can dismiss, not useless text in the command bar").
rw_pick_failure_dialog() {
  local label="$1" status="$2" out_file="$3"
  rw_failure_explain "$status" "$out_file"
  printf '\n\033[1m%s failed\033[0m\n  cause:  %s\n  action: %s\n\n  [press any key to dismiss]\n' \
    "$label" "$RW_FAIL_CAUSE" "$RW_FAIL_ACTION"
  read -r -s -n 1 2>/dev/null </dev/tty || true
}

# rw_pick_bg <verb> <args...>
# `rw bg <verb> <args...>`: rw bg checks the root and returns at once, the
# transfer runs detached, and the popup closes. A synchronous refusal (the
# root is invalid, already moving, ...) is shown inline instead.
rw_pick_bg() {
  local verb="$1" out status
  shift
  out="$(env -u TMUX_PANE "$RW_BIN" bg "$verb" "$@" </dev/null 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && exit 0
  rw_pick_notice "rw $verb not started" "$(printf '%s\n' "$out" | grep '^rw' | tail -n 1 | sed 's/^rw: //')"
  exit "$status"
}

# --- 1. Remote pane: hand its root back ------------------------------------
pick_handback() {
  local origin_pane="$1" root_id record="" root="" endpoint n=0
  root_id="$(rw_pane_get "$origin_pane" @rw-root-id)"
  if [ -z "$root_id" ]; then
    endpoint="$(rw_pane_get "$origin_pane" @rw-endpoint)"
    [ -n "$endpoint" ] && root_id="$(rw_read_endpoint "$endpoint" 2>/dev/null | jq -r '.root_id // empty')"
  fi
  [ -n "$root_id" ] && record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
  if [ -n "$record" ]; then
    root="$(printf '%s' "$record" | jq -r '.root_local')"
    # shellcheck disable=SC2046 # endpoint ids are fixed-format hex
    n="$(rw_root_bound_panes "$root_id" $(printf '%s' "$record" | jq -r '.endpoints[]?') | wc -l | tr -d ' ')"
  fi
  if [ -z "$root" ]; then
    root="$(tmux display-message -pt "$origin_pane" -F '#{pane_current_path}' 2>/dev/null || true)"
  fi

  printf '\n  %s is remote.' "$(rw_pick_tilde "$root")"
  [ "$n" -gt 1 ] && printf ' %s come back with it.' "$(rw_pick_plural "$n" pane)"
  printf '\n'
  rw_pick_yes "hand $(rw_pick_tilde "$root") back to this machine?" || exit 0
  rw_pick_bg handback --pane "$origin_pane"
}

# --- 2. Local pane in the frozen copy of a remote root: open it remote ------
pick_open() {
  local origin_pane="$1" origin_cmd="$2" root="$3"
  # Shells only: rw open respawns the pane (-k), which would kill an
  # editor with its unsaved buffers.
  case "$origin_cmd" in
    zsh | bash | sh | fish | dash | ksh | -zsh | -bash) ;;
    *)
      rw_pick_notice "Remote workspace" "$(rw_pick_tilde "$root") is remote, and this pane is running '$origin_cmd'; opening it remote would replace that. Quit it first, or open a new window from the picker (prefix o, then w)."
      exit 0
      ;;
  esac
  printf '\n  %s is remote; this local copy is frozen.\n' "$(rw_pick_tilde "$root")"
  rw_pick_yes "open this pane remote in $(rw_pick_tilde "$root")?" || exit 0
  printf '\n'
  rw_pick_transfer open --root "$root" --pane "$origin_pane"
}

# --- 3. Local pane: choose a worker, hand its root off ----------------------
pick_handoff() {
  local origin_pane="$1" root="$2" panes n editors header note alias
  panes="$(rw_root_panes "$root")"
  n="$(printf '%s\n' "$panes" | grep -c . || true)"
  editors="$(printf '%s\n' "$panes" | awk -F '\t' '$8 == "nvim" || $8 == "vim" || $8 == "vi"' | grep -c . || true)"
  note="$(rw_pick_plural "$n" pane) working in it move to the chosen worker (any session)"
  [ "$n" -le 1 ] && note="this pane moves to the chosen worker; nothing else works in it"
  header="hand off $(rw_pick_tilde "$root")"$'\n'"$note"
  [ "$editors" -gt 0 ] && header="$header"$'\n'"editors move too, but unsaved buffers do not: save first"

  alias="$(rw_pick_worker_menu 'rw handoff ⇒ ' "$header")" || exit 0
  rw_pick_bg handoff --worker "$alias" --pane "$origin_pane"
}

pick() {
  if ! command -v jq >/dev/null 2>&1 || ! command -v fzf >/dev/null 2>&1; then
    rw_pick_notice "Remote workspace" "prefix e needs jq and fzf on the tmux server's PATH; one of them is missing."
    exit 0
  fi
  if ! rw_config_valid; then
    rw_pick_notice "Remote workspace" "config.json ($RW_CONFIG_FILE) is invalid."
    exit 0
  fi

  # Resolve the invoking pane BEFORE fzf: inside a popup, display-message
  # with no target resolves against the client's active pane, which is
  # exactly the pane the popup was opened over.
  local origin_pane origin_cmd origin_cwd root
  origin_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  [ -n "$origin_pane" ] || exit 0

  if [ -n "$(rw_pane_get "$origin_pane" @remote-host)" ]; then
    pick_handback "$origin_pane"
    return
  fi

  origin_cmd="$(tmux display-message -pt "$origin_pane" -F '#{pane_current_command}' 2>/dev/null || true)"
  origin_cwd="$(tmux display-message -pt "$origin_pane" -F '#{pane_current_path}' 2>/dev/null || true)"
  [ -n "$origin_cwd" ] || exit 0

  if rw_owned_root_for_path "$origin_cwd" >/dev/null; then
    root="$(rw_default_root_for_path "$origin_cwd")"
    pick_open "$origin_pane" "$origin_cmd" "$root"
    return
  fi

  root="$(rw_default_root_for_path "$origin_cwd")"
  if ! rw_root_rel "$root" >/dev/null; then
    rw_pick_notice "Remote workspace" "$(rw_pick_tilde "$root") is not inside your home directory (or is the home directory itself); only directories under ~ can be handed off."
    exit 0
  fi
  pick_handoff "$origin_pane" "$root"
}

case "$mode" in
  list) list_workers ;;
  probe) probe_workers ;;
  pick) pick ;;
  *) rw_die "rw-picker: unknown mode: $mode" 64 ;;
esac
