#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

dry_run="false"
if [ "${1:-}" = "--dry-run" ] || [ "${TMUX_WORKSPACE_RESURRECT_DRY_RUN:-}" = "1" ]; then
  dry_run="true"
fi

sidecar="$(workspace_sidecar_file)"
if [ ! -f "$sidecar" ] || ! jq -e '.version == 1' "$sidecar" >/dev/null 2>&1; then
  workspace_log "restore skipped: no valid workspace sidecar"
  exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-workspace-resurrect-restore.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mapping_file="$work_dir/pane-map.tsv"
sidebar_file="$work_dir/sidebar-logical-ids"
: >"$mapping_file"
: >"$sidebar_file"

while IFS= read -r logical_id; do
  pane_id="$(tmux display-message -pt "$logical_id" -F '#{pane_id}' 2>/dev/null || true)"
  if [ -n "$pane_id" ]; then
    printf '%s\t%s\n' "$logical_id" "$pane_id" >>"$mapping_file"
  fi
done < <(jq -r '.panes[].logical_id' "$sidecar")

mapped_pane() {
  local logical_id="$1"
  awk -F '\t' -v logical="$logical_id" '$1 == logical { print $2; exit }' "$mapping_file"
}

if workspace_config_bool '.capture.treemux'; then
  while IFS=$'\t' read -r main_logical sidebar_logical treemux_args; do
    printf '%s\n' "$sidebar_logical" >>"$sidebar_file"
    main_pane="$(mapped_pane "$main_logical")"
    sidebar_pane="$(mapped_pane "$sidebar_logical")"
    if [ -z "$main_pane" ]; then
      workspace_log "Treemux restore skipped for $main_logical: main pane missing"
      continue
    fi

    if [ "$dry_run" = "true" ]; then
      workspace_log "dry-run: Treemux mapping validated for $main_logical"
      continue
    fi

    if [ -n "$sidebar_pane" ] && tmux display-message -pt "$sidebar_pane" -F '#{pane_id}' >/dev/null 2>&1; then
      tmux kill-pane -t "$sidebar_pane"
    fi

    treemux_toggle="$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh"
    if [ -x "$treemux_toggle" ]; then
      "$treemux_toggle" "$treemux_args" "$main_pane" >/dev/null 2>&1 ||
        workspace_log "Treemux reconstruction failed for $main_logical"
    else
      workspace_log "Treemux reconstruction skipped: toggle.sh unavailable"
    fi
  done < <(jq -r '.treemux[] | [.main_logical_id, .sidebar_logical_id, .args] | @tsv' "$sidecar")
fi

queued=0
skipped=0
while IFS= read -r pane_record; do
  logical_id="$(printf '%s' "$pane_record" | jq -r '.logical_id')"
  selected_command="$(printf '%s' "$pane_record" | jq -r '.selected_command')"
  selected_source="$(printf '%s' "$pane_record" | jq -r '.selected_source')"
  pending_cursor="$(printf '%s' "$pane_record" | jq -r '.pending_cursor // 0')"

  if grep -Fqx "$logical_id" "$sidebar_file" 2>/dev/null || [ -z "$selected_command" ]; then
    continue
  fi

  pane_id="$(mapped_pane "$logical_id")"
  if [ -z "$pane_id" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore skipped for $logical_id: pane missing"
    continue
  fi

  # Generic restore opt-out seam: any plugin (e.g. tmux-remote-workspaces)
  # can set @workspace-resurrect-skip on a pane it manages so a recorded
  # command (e.g. a stale `ssh mini`) is never pasted into it. See
  # docs/tasks/tmux-remote-workspaces/initial-plan.md, "Local restore of
  # remote attachments".
  if [ -n "$(tmux show-option -pt "$pane_id" -qv @workspace-resurrect-skip 2>/dev/null)" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore skipped for $logical_id: @workspace-resurrect-skip is set"
    continue
  fi

  if [ "$dry_run" = "true" ]; then
    queued=$((queued + 1))
    workspace_log "dry-run: queue candidate $logical_id from $selected_source"
    continue
  fi

  shell_ready="false"
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    pane_command="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
    if workspace_command_is_shell "$pane_command"; then
      shell_ready="true"
      break
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done

  if [ "$shell_ready" != "true" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore skipped for $logical_id: shell is not ready"
    continue
  fi

  buffer_name="workspace-resurrect-${pane_id#%}"
  # Use terminal bracketed-paste markers so embedded newlines become part of
  # the editable shell buffer instead of acting as Enter.
  printf '\033[200~%s\033[201~' "$selected_command" |
    tmux load-buffer -b "$buffer_name" -
  tmux paste-buffer -b "$buffer_name" -t "$pane_id" -d

  if [ "$selected_source" = "pending-buffer" ] &&
    [[ "$pending_cursor" =~ ^[0-9]+$ ]] &&
    [ "$pending_cursor" -lt "${#selected_command}" ]; then
    cursor_moves=$((${#selected_command} - pending_cursor))
    while [ "$cursor_moves" -gt 0 ]; do
      tmux send-keys -t "$pane_id" Left
      cursor_moves=$((cursor_moves - 1))
    done
  fi

  queued=$((queued + 1))
  workspace_log "queued $selected_source in $logical_id"
done < <(jq -c '.panes[]' "$sidecar")

workspace_log "restore complete: queued=$queued skipped=$skipped dry_run=$dry_run"
