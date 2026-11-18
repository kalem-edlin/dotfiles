#!/usr/bin/env bash
# Transfer dialogs shared by the `prefix e` popup (scripts/rw-picker.sh) and
# the background transfer runner (libexec/rw-bg, through libexec/rw-bg-dialog
# in a display-popup). Sourced only; never executed directly. Every function
# draws on /dev/tty, so it must run inside a popup (or a terminal).
# shellcheck disable=SC2034 # RW_FAIL_CAUSE / RW_FAIL_ACTION are read by callers

# rw_dlg_plural <n> <noun> -- "1 pane", "3 panes".
rw_dlg_plural() {
  if [ "$1" -eq 1 ]; then printf '1 %s' "$2"; else printf '%d %ss' "$1" "$2"; fi
}

# rw_conflict_dialog <verb> <out_file>
# rw's exit 5 lists one `conflict<TAB>path<TAB>kind` line per file in
# <out_file>. Shows a screenful of them (then "+N more") above a three-way
# choice, abort first so a stray enter moves nothing. Prints overwrite,
# keep-both, or nothing for abort.
rw_conflict_dialog() {
  local verb="$1" out_file="$2" total rows room list title sel
  total="$(grep -c $'^conflict\t' "$out_file" || true)"
  rows="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  case "$rows" in '' | *[!0-9]*) rows=24 ;; esac
  # fzf's prompt, info line and three choices, the title and its blank.
  room=$((rows - 9))
  [ "$room" -ge 3 ] || room=3
  if [ "$total" -gt "$room" ]; then
    list="$(grep $'^conflict\t' "$out_file" | head -n $((room - 1)) | awk -F '\t' '{ printf "  %-8s %s\n", $3, $2 }')"
    list="$list"$'\n'"  +$((total - room + 1)) more"
  else
    list="$(grep $'^conflict\t' "$out_file" | awk -F '\t' '{ printf "  %-8s %s\n", $3, $2 }')"
  fi
  case "$verb" in
    handoff) title="$(rw_dlg_plural "$total" file) changed on the remote copy since it was last synced; the local copy is about to replace it:" ;;
    *) title="$(rw_dlg_plural "$total" file) changed in the frozen local copy since the handoff; the remote copy is about to replace it:" ;;
  esac
  sel="$(printf '%s\n' \
    $'abort\tabort: nothing moves' \
    $'keep-both\tkeep both: each losing file is kept as <file>.local-<date>' \
    $'overwrite\toverwrite: the incoming copy wins, the listed changes are lost' |
    fzf --layout=reverse --info=hidden --no-multi --no-sort \
      --delimiter=$'\t' --with-nth=2 \
      --prompt='conflict ⇒ ' \
      --header="$title"$'\n'"$list")" || return 0
  sel="${sel%%$'\t'*}"
  case "$sel" in overwrite | keep-both) printf '%s\n' "$sel" ;; esac
}

# rw_failure_explain <status> <out_file>
# One cause line and one action line for a failed rw transfer, in
# RW_FAIL_CAUSE and RW_FAIL_ACTION, from rw's exit status and output.
rw_failure_explain() {
  local status="$1" out_file="$2" refusal
  RW_FAIL_CAUSE="" RW_FAIL_ACTION=""
  refusal="$(grep '^rw: ' "$out_file" | tail -n 1 | sed 's/^rw: //')"
  case "$status" in
    6)
      RW_FAIL_CAUSE="worker unreachable over ssh; nothing moved"
      RW_FAIL_ACTION="check the worker is awake and on the network, then retry"
      ;;
    2)
      RW_FAIL_CAUSE="the git history of the copy being overwritten has diverged"
      RW_FAIL_ACTION="inspect it, or re-run from a shell with --force-diverged (a backup is taken)"
      ;;
    3)
      RW_FAIL_CAUSE="agent CLI version differs between here and the worker"
      RW_FAIL_ACTION="update the older side, then retry"
      ;;
    7)
      RW_FAIL_CAUSE="rw refused this root: ${refusal:-it is not in a state this allows}"
      RW_FAIL_ACTION="nothing moved. A root is a git worktree's top or a plain folder under ~ (not ~ itself, not a folder of worktrees); rw status lists remote roots"
      ;;
  esac
  [ -z "$RW_FAIL_CAUSE" ] || return 0
  if grep -q 'SOURCE workspace changed while the handoff was in flight\|source_changed_during_sync' "$out_file"; then
    RW_FAIL_CAUSE="another writer (a running agent or editor) edited this directory mid-transfer"
    RW_FAIL_ACTION="pause or finish that writer, then retry"
  elif grep -q 'destination content does not match' "$out_file"; then
    RW_FAIL_CAUSE="post-sync verification failed; the copy is unverified"
    RW_FAIL_ACTION="inspect the destination path from the log before retrying"
  elif grep -q 'could not confirm a supported AI agent\|neither a shell, an editor, nor a recognized agent' "$out_file"; then
    RW_FAIL_CAUSE="a pane in this root is busy with something that cannot move safely"
    RW_FAIL_ACTION="stop it, or wait for the agent to finish starting, then retry"
  elif grep -q 'attach loop was not started\|could not start the attach loop' "$out_file"; then
    RW_FAIL_CAUSE="the remote side started, but a local pane could not switch into it"
    RW_FAIL_ACTION="retry, or check rw status for the recorded endpoint"
  else
    RW_FAIL_CAUSE="${refusal:-unrecognized failure (exit $status)}"
    RW_FAIL_ACTION="$(tail -n 2 "$out_file" | grep -v $'^conflict\t' | tr '\n' ' ')"
  fi
}
