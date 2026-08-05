#!/usr/bin/env bash
# Backs the `prefix e` binding (tmux.reset.conf): ONE versatile display-popup
# picker with automatic intent detection off the focused (origin) pane --
# no mode questions. Four outcomes, checked in this order:
#
#   1. Origin pane is remote-backed (@rw-endpoint set) -> CONFIRM (tiny
#      yes/no menu, worker + endpoint id shown), then on yes run
#      rw-return.sh --pane <origin> DIRECTLY. Never send-keys: a
#      remote-backed pane's foreground is a raw ssh PTY into the worker, so
#      anything typed there lands on the WORKER's own shell (that trap cost
#      a round trip 2026-08-05 -- `rw return` typed at the remote prompt ran
#      the WORKER's own rw, which answered "pane %36 has no @rw-endpoint").
#   2. Origin pane sits at a plain shell prompt -> the ORIGINAL flow,
#      unchanged: fzf worker list, then `rw ensure --worker <alias>` typed
#      into the pane via send-keys (with a leading C-u to clear any
#      half-typed input) -- exactly the manual flow, just without the
#      typing. The pane's own cwd drives `auto` workspace resolution.
#   3. Origin pane is busy running a HANDOFF-ELIGIBLE program (an AI coding
#      agent -- claude/codex/pi, the same process patterns rw-handoff.sh's
#      own adapters use -- or nvim/vim/vi) -> fzf worker list whose header
#      says this will be a HANDOFF (move) of the running command, then run
#      rw-handoff.sh --worker <alias> --pane <origin> DIRECTLY (never
#      send-keys, same reasoning as above). For an editor specifically, the
#      header also warns that unsaved buffers do NOT transfer -- workspace
#      sync only ever copies disk state.
#   4. Origin pane is busy with anything else -> today's refusal message.
#
# Modes (self-invocations; the binding only ever calls `pick`):
#   pick    run fzf inside the popup tty, then act on the focused pane
#   list    emit worker lines instantly (reachability column pending)
#   probe   emit the same lines with live online/offline status
#
# The list renders immediately via `list`; fzf's start event reloads it
# from `probe` (parallel `ssh -o BatchMode=yes` probes bounded by the
# config's status timeout), so reachability fills in without delaying the
# popup. fzf's stock ctrl-n/ctrl-p (down/up) are left untouched.
#
# Typed text that matches no listed worker is passed through as an alias
# on enter (--print-query) for the ensure/handoff worker lists: the target
# script rejects aliases not declared in config.json on its own.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

mode="${1:-pick}"

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
# slowest host's timeout (a downed mini held the whole list hostage for
# ~8s, 2026-08-05).
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
# Shared fzf-over-the-worker-list chooser for both the ensure and handoff
# branches. Prints the chosen (or typed, unmatched) alias on stdout; prints
# nothing and returns 1 on abort (esc/ctrl-c) or an empty pick.
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

# rw_pick_handoff_kind <pane_id> <pane_current_command>
# Prints "editor" or "agent" and returns 0 when the pane is busy running
# something handoff-eligible; prints nothing and returns 1 otherwise. Only
# used to decide THIS picker's own eligibility/header wording --
# rw-handoff.sh re-detects for real via each adapter's own `detect`
# subcommand, so a false positive here costs nothing worse than an offered
# handoff that rw-handoff.sh itself then treats as workspace-only.
rw_pick_handoff_kind() {
  local pane_id="$1" cmd="$2"
  case "$cmd" in
    nvim | vim | vi)
      printf 'editor\n'
      return 0
      ;;
  esac

  # AI coding-agent detection: walk the pane's own process tree (not just
  # pane_current_command, which loses the distinguishing name for
  # npm-launched CLIs like codex/pi -- they commonly surface as "node")
  # against the same per-provider patterns rw-handoff.sh's own adapters use
  # (libexec/adapters/common-adapter.sh's ca_patterns_claude/codex/pi,
  # mirrored in this plugin's common.sh as rw_provider_pattern for exactly
  # this kind of process-tree check -- see rw_wait_remote/local_provider_started).
  local pane_pid ps_snapshot provider pattern
  pane_pid="$(tmux display-message -pt "$pane_id" -F '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$pane_pid" ] || return 1
  ps_snapshot="$(ps axo pid=,ppid=,command= 2>/dev/null)"
  for provider in claude codex pi; do
    pattern="$(rw_provider_pattern "$provider")"
    if printf '%s\n' "$ps_snapshot" | rw_ps_tree_matches "$pattern" "$pane_pid"; then
      printf 'agent\n'
      return 0
    fi
  done
  return 1
}

# --- Intent 1: remote-backed origin pane -> confirm, then hand back -------
pick_return() {
  local origin_pane="$1" endpoint_id="$2" worker confirm_out confirm_status

  worker="$(rw_pane_get "$origin_pane" @rw-worker)"
  [ -n "$worker" ] || worker="?"

  # Tiny two-line yes/no menu, not the worker list: this is a confirm, not
  # a pick. esc/ctrl-c (nonzero fzf exit) and the explicit "stay remote"
  # row both abort with no action taken -- returning is a real transfer,
  # never triggered by an accidental keypress.
  confirm_out="$(printf 'return to local\nstay remote\n' | fzf \
    --layout=reverse --info=inline --no-multi \
    --prompt='rw ⇒ ' \
    --header="pane is remote-backed: worker '$worker', endpoint $endpoint_id -- return to local?")"
  confirm_status=$?

  [ "$confirm_status" -eq 0 ] && [ "$confirm_out" = "return to local" ] || exit 0

  # Run rw-return.sh directly (never send-keys -- see the header comment).
  # It targets $origin_pane explicitly via --pane, so running it here in
  # the popup (rather than inside that pane) is fine: the pane itself gets
  # released back to a local shell by attach-loop.sh's own pane_released()
  # check, which fires the moment @rw-endpoint is cleared and this pane's
  # ssh client is killed -- both of which rw-return.sh does directly
  # against $origin_pane regardless of which pane it's actually running in.
  #
  # stdin redirected from /dev/null: rw-return.sh's own normal tail
  # (`exec "$SHELL" -l`) hands the CALLING pane a landing shell in the
  # workspace directory -- the right move when it's run from an ordinary
  # spare local pane, but inside this transient popup that would instead
  # leave an idle login shell sitting in the popup until manually closed.
  # With no tty on stdin, that final exec hits EOF and exits immediately
  # instead, so the popup closes on its own (display-popup -E) right after
  # rw-return.sh finishes its real work.
  "$SCRIPT_DIR/rw-return.sh" --pane "$origin_pane" </dev/null
}

# --- Intent 2: plain shell prompt -> original ensure flow, unchanged ------
pick_ensure() {
  local origin_pane="$1" alias
  alias="$(rw_pick_worker_menu 'rw ensure ⇒ ' \
    $'enter: open a new window on the chosen worker\ntyped text with no match is used as the alias as-is')" || exit 0

  # C-u first: clear anything half-typed at the prompt so the command
  # lands clean. The pane's shell resolves `rw` from PATH (~/.local/bin
  # symlink), same as typing it by hand.
  tmux send-keys -t "$origin_pane" C-u "rw ensure --worker $alias" Enter
}

# --- Intent 3: busy handoff-eligible pane -> fzf list, then handoff -------
pick_handoff() {
  local origin_pane="$1" origin_cmd="$2" kind="$3" header alias

  case "$kind" in
    editor)
      header=$'enter: HANDOFF (move) the running '"$origin_cmd"$' to the chosen worker\nWARNING: unsaved buffers do NOT transfer -- workspace sync copies disk state only'
      ;;
    *)
      header="enter: HANDOFF (move) the running $origin_cmd to the chosen worker"
      ;;
  esac

  alias="$(rw_pick_worker_menu 'rw handoff ⇒ ' "$header")" || exit 0

  # Run rw-handoff.sh directly (never send-keys, same reasoning as
  # pick_return). Its own 5-step transactional design detects/stops the
  # local agent when one is running (or, for nvim/vim/vi, leaves it a
  # workspace-only handoff since no adapter covers editors) and, on
  # success, respawns $origin_pane into the attach loop itself -- see
  # rw-handoff.sh's own foreign-pane handling (its `--pane` != $TMUX_PANE
  # branch, which now also matches nvim/vim/vi) for exactly how the pane
  # ends up attached; this picker does not attach it.
  "$SCRIPT_DIR/rw-handoff.sh" --worker "$alias" --pane "$origin_pane"
}

pick() {
  rw_need_jq
  rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

  # Resolve the invoking pane BEFORE fzf: inside a popup, display-message
  # with no target resolves against the client's active pane, which is
  # exactly the pane the popup was opened over. (Avoids relying on
  # display-popup's own format expansion of its command.)
  local origin_pane origin_cmd origin_endpoint handoff_kind
  origin_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  [ -n "$origin_pane" ] || exit 0
  origin_cmd="$(tmux display-message -p '#{pane_current_command}' 2>/dev/null || true)"

  origin_endpoint="$(rw_pane_get "$origin_pane" @rw-endpoint)"
  if [ -n "$origin_endpoint" ]; then
    pick_return "$origin_pane" "$origin_endpoint"
    return
  fi

  case "$origin_cmd" in
    zsh | bash | sh | fish | dash | ksh)
      pick_ensure "$origin_pane"
      return
      ;;
  esac

  handoff_kind="$(rw_pick_handoff_kind "$origin_pane" "$origin_cmd")"
  if [ -n "$handoff_kind" ]; then
    pick_handoff "$origin_pane" "$origin_cmd" "$handoff_kind"
  else
    tmux display-message "rw-picker: focused pane is running '$origin_cmd', not a shell prompt"
    exit 0
  fi
}

case "$mode" in
  list) list_workers ;;
  probe) probe_workers ;;
  pick) pick ;;
  *) rw_die "rw-picker: unknown mode: $mode" 64 ;;
esac
