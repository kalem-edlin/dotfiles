#!/usr/bin/env bash
# `prefix C-s` dispatcher. Always saves the outer tmux server; when the
# focused pane belongs to tmux-remote-workspaces, also saves that worker.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RW_COMMON="$SCRIPT_DIR/../local-plugins/tmux-remote-workspaces/scripts/common.sh"
# shellcheck source=../local-plugins/tmux-remote-workspaces/scripts/common.sh
# shellcheck disable=SC1091 # Resolved from SCRIPT_DIR at runtime.
source "$RW_COMMON"

worker="${1:-}"
case "$worker" in
  *[!A-Za-z0-9._-]*)
    tmux display-message "Tmux save failed: invalid remote worker alias"
    exit 1
    ;;
esac

# Keep the verifier's stderr: it names WHICH gate refused (a truncated
# generic message hid the real refusal from the rw picker once already,
# 2026-08-06 -- same lesson here).
err_file="$(mktemp "${TMPDIR:-/tmp}/tmux-manual-save.XXXXXX")"
trap 'rm -f "$err_file"' EXIT

local_ts="$(bash "$SCRIPT_DIR/resurrect_save.sh" --print-timestamp 2>"$err_file")"
case "$local_ts" in
  '' | *[!0-9]*)
    tmux display-message -d 10000 \
      "Tmux save failed: …$(tail -c 220 "$err_file" | tr '\n' ' ')"
    exit 1
    ;;
esac

if [ -z "$worker" ]; then
  tmux display-message "Tmux environment saved and verified"
  exit 0
fi

# Stream the focus machine's verifier into the worker. This makes a manual
# remote save use exactly the same validation logic immediately, even if the
# worker's separate dotfiles clone has not pulled this revision yet. The code
# still runs on the worker and therefore talks only to that worker's tmux
# server, Resurrect installation, and workspace-resurrect hook/state.
remote_ts="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
  'bash -s -- --print-timestamp' <"$SCRIPT_DIR/resurrect_save.sh" 2>"$err_file")"
case "$remote_ts" in
  '' | *[!0-9]*)
    tmux display-message -d 10000 \
      "Local tmux saved; remote save FAILED on $worker: …$(tail -c 200 "$err_file" | tr '\n' ' ')"
    exit 1
    ;;
esac

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-rw-autosave"
mkdir -p "$cache_dir" 2>/dev/null || true
cache_tmp="$cache_dir/.$worker.manual.$$"
cached_ts=""
[ -f "$cache_dir/$worker" ] && cached_ts="$(sed -n '1p' "$cache_dir/$worker" 2>/dev/null)"
case "$cached_ts" in
  '' | *[!0-9]*) cached_ts=0 ;;
esac
if [ "$remote_ts" -ge "$cached_ts" ] && printf '%s\n' "$remote_ts" >"$cache_tmp" 2>/dev/null; then
  mv -f "$cache_tmp" "$cache_dir/$worker" 2>/dev/null || true
else
  rm -f "$cache_tmp" 2>/dev/null || true
fi
tmux refresh-client -S 2>/dev/null || true
tmux display-message "Local and $worker tmux environments saved and verified"
