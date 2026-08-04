#!/usr/bin/env bash
# Backs the `prefix e` binding (tmux.reset.conf): a display-popup picker
# that lists the workers declared in config.json, probes their ssh
# reachability in place, and on selection opens a NEW window whose pane
# immediately runs `rw ensure --worker <alias>`. The window inherits the
# invoking pane's cwd (same rule as `bind c`), so workspace resolution
# stays `auto` against the directory the user was looking at.
#
# Modes (self-invocations; the binding only ever calls `pick`):
#   pick    run fzf inside the popup tty, then open the window
#   list    emit worker lines instantly (reachability column pending)
#   probe   emit the same lines with live online/offline status
#
# The list renders immediately via `list`; fzf's start event reloads it
# from `probe` (parallel `ssh -o BatchMode=yes` probes bounded by the
# config's status timeout), so reachability fills in without delaying the
# popup. fzf's stock ctrl-n/ctrl-p (down/up) are left untouched.
#
# Typed text that matches no listed worker is passed through as an alias
# on enter (--print-query): rw ensure itself rejects aliases not declared
# in config.json, and the `; exec $SHELL -l` tail (same idiom as
# rw-split.sh) keeps the new pane alive to read that error instead of
# flashing shut.

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

probe_workers() {
  local tmpdir i alias platform notes status
  local aliases=() platforms=() notes_arr=()
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/rw-picker.XXXXXX")"
  i=0
  while IFS=$'\t' read -r alias platform notes; do
    aliases+=("$alias")
    platforms+=("$platform")
    notes_arr+=("$notes")
    (
      if rw_ssh_batch "$alias" "$(rw_ssh_status_timeout)" true >/dev/null 2>&1; then
        printf 'online' >"$tmpdir/$i"
      else
        printf 'offline' >"$tmpdir/$i"
      fi
    ) &
    i=$((i + 1))
  done < <(jq -r '.workers[] | [.alias, .platform, (.notes // "")] | @tsv' "$RW_CONFIG_FILE")
  wait
  for ((i = 0; i < ${#aliases[@]}; i++)); do
    status="$(cat "$tmpdir/$i" 2>/dev/null || printf '?')"
    worker_line "${aliases[$i]}" "${platforms[$i]}" "$status" "${notes_arr[$i]}"
  done
  \rm -rf "$tmpdir"
}

pick() {
  rw_need_jq
  rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

  # Resolve the invoking pane's cwd BEFORE fzf: inside a popup,
  # display-message with no target resolves against the client's active
  # pane, which is exactly the pane the popup was opened over. (Avoids
  # relying on display-popup's own format expansion of its command.)
  local origin_cwd out status sel alias
  origin_cwd="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)"
  [ -d "$origin_cwd" ] || origin_cwd="$HOME"

  out="$(list_workers | fzf \
    --layout=reverse --info=inline \
    --prompt='rw ensure ⇒ ' \
    --header=$'enter: open a new window on the chosen worker\ntyped text with no match is used as the alias as-is' \
    --delimiter=$'\t' \
    --print-query \
    --bind "start:reload:$0 probe")"
  status=$?

  case "$status" in
    0) sel="$(printf '%s\n' "$out" | tail -n1)" ;; # picked a listed worker
    1) sel="$(printf '%s\n' "$out" | head -n1)" ;; # typed alias, no match
    *) exit 0 ;;                                   # aborted (esc / ctrl-c)
  esac

  alias="${sel%%$'\t'*}"
  alias="${alias//[[:space:]]/}"
  [ -n "$alias" ] || exit 0

  tmux new-window -c "$origin_cwd" \
    "\"$SCRIPT_DIR/rw\" ensure --worker \"$alias\"; exec \${SHELL:-/bin/sh} -l"
}

case "$mode" in
  list) list_workers ;;
  probe) probe_workers ;;
  pick) pick ;;
  *) rw_die "rw-picker: unknown mode: $mode" 64 ;;
esac
