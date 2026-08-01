#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if ! command -v jq >/dev/null 2>&1; then
  workspace_log "save skipped: jq is unavailable"
  exit 0
fi

state_dir="$(workspace_state_dir)"
resurrect_dir="$(workspace_resurrect_dir)"
sidecar="$(workspace_sidecar_file)"
workspace_ensure_private_dir "$state_dir"
workspace_ensure_private_dir "$resurrect_dir"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-workspace-resurrect-save.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
panes_jsonl="$work_dir/panes.jsonl"
treemux_jsonl="$work_dir/treemux.jsonl"
: >"$panes_jsonl"
: >"$treemux_jsonl"

force_neovim_session_save() {
  local pane_id="$1"
  local server
  server="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-server 2>/dev/null || true)"
  if [ -n "$server" ] && [ -S "$server" ] && command -v nvim >/dev/null 2>&1; then
    nvim --server "$server" --remote-expr \
      'luaeval("require(\"tmux_workspace_resurrect\").save()")' \
      >/dev/null 2>&1 || true
  fi
}

# NOTE: pane fields are fetched one-at-a-time via `display-message -F` with
# a single #{...} substitution per call, never via a multi-field
# tab/control-char-delimited `list-panes -F` format string. tmux (observed:
# Homebrew 3.7b) sanitizes control characters -- including the TAB this
# script used to join fields with -- to `_` in command output, which
# silently collapses a whole delimited record into one field and corrupts
# downstream parsing (see workspace-resurrect.log history / task write-up
# for the incident this fixes). A single #{...} format has nothing to
# delimit, so it survives unaffected regardless of tmux version. This costs
# extra `tmux` round trips per pane, but save.sh runs on a periodic timer,
# not in a hot path.
tmux_pane_field() {
  tmux display-message -pt "$1" -F "$2" 2>/dev/null || true
}

while IFS= read -r pane_id; do
  [ -n "$pane_id" ] || continue

  session_name="$(tmux_pane_field "$pane_id" '#{session_name}')"
  window_index="$(tmux_pane_field "$pane_id" '#{window_index}')"
  pane_index="$(tmux_pane_field "$pane_id" '#{pane_index}')"
  pane_pid="$(tmux_pane_field "$pane_id" '#{pane_pid}')"
  pane_command="$(tmux_pane_field "$pane_id" '#{pane_current_command}')"
  pane_path="$(tmux_pane_field "$pane_id" '#{pane_current_path}')"
  pane_title="$(tmux_pane_field "$pane_id" '#{pane_title}')"

  # Defense in depth: the fields below feed jq --argjson and MUST be
  # numeric. A malformed/vanished pane (or any future sanitization
  # surprise) must skip just this one pane, not abort the whole save via
  # set -euo pipefail killing jq underneath us.
  case "$window_index" in
    '' | *[!0-9]*)
      workspace_log "save: skipping pane $pane_id - non-numeric window_index '$window_index'"
      continue
      ;;
  esac
  case "$pane_index" in
    '' | *[!0-9]*)
      workspace_log "save: skipping pane $pane_id - non-numeric pane_index '$pane_index'"
      continue
      ;;
  esac
  case "$pane_pid" in
    '' | *[!0-9]*)
      workspace_log "save: skipping pane $pane_id - non-numeric pane_pid '$pane_pid'"
      continue
      ;;
  esac

  logical_id="${session_name}:${window_index}.${pane_index}"
  last_command="$(tmux show-option -pt "$pane_id" -qv @workspace-last-command 2>/dev/null || true)"
  pending_buffer="$(tmux show-option -pt "$pane_id" -qv @workspace-pending-buffer 2>/dev/null || true)"
  pending_cursor="$(tmux show-option -pt "$pane_id" -qv @workspace-pending-cursor 2>/dev/null || true)"
  selected_command="$last_command"
  selected_source="last-command"

  if [ -n "$pending_buffer" ]; then
    selected_command="$pending_buffer"
    selected_source="pending-buffer"
  fi

  force_neovim_session_save "$pane_id"
  nvim_server="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-server 2>/dev/null || true)"
  nvim_session="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-session 2>/dev/null || true)"
  nvim_active_file="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-active-file 2>/dev/null || true)"
  nvim_json="null"
  if workspace_config_bool '.capture.neovim_sessions' &&
    [ -n "$nvim_session" ] &&
    { [ "$pane_command" = "nvim" ] || [ "$pane_command" = "vim" ]; }; then
    selected_command="nvim -S $(workspace_shell_quote "$nvim_session")"
    selected_source="neovim-session"
    nvim_json="$(
      jq -n \
        --arg server "$nvim_server" \
        --arg session_file "$nvim_session" \
        --arg active_file "$nvim_active_file" \
        '{server: $server, session_file: $session_file, active_file: $active_file}'
    )"
  fi

  agent_json="null"
  agent_file="$(workspace_pane_state_file "$pane_id")"
  inferred_agent="$(workspace_infer_agent "$last_command")"
  if workspace_config_bool '.capture.agent_sessions' &&
    [ -n "$inferred_agent" ] &&
    ! workspace_command_is_shell "$pane_command" &&
    [ -f "$agent_file" ]; then
    recorded_tool="$(jq -r '.tool // empty' "$agent_file" 2>/dev/null || true)"
    session_id="$(jq -r '.session_id // empty' "$agent_file" 2>/dev/null || true)"
    if [ "$recorded_tool" = "$inferred_agent" ] && [ -n "$session_id" ]; then
      selected_command="$(workspace_resume_command "$recorded_tool" "$session_id" "$last_command")"
      selected_source="${recorded_tool}-session"
      agent_json="$(
        jq -c \
          '{tool, session_id, cwd: (.cwd // ""), model: (.model // ""), recorded_at}' \
          "$agent_file"
      )"
    fi
  fi

  jq -nc \
    --arg logical_id "$logical_id" \
    --arg session_name "$session_name" \
    --argjson window_index "$window_index" \
    --argjson pane_index "$pane_index" \
    --arg pane_id "$pane_id" \
    --argjson pane_pid "$pane_pid" \
    --arg cwd "$pane_path" \
    --arg title "$pane_title" \
    --arg current_command "$pane_command" \
    --arg last_command "$last_command" \
    --arg pending_buffer "$pending_buffer" \
    --argjson pending_cursor "${pending_cursor:-0}" \
    --arg selected_command "$selected_command" \
    --arg selected_source "$selected_source" \
    --argjson agent "$agent_json" \
    --argjson neovim "$nvim_json" \
    '{
      logical_id: $logical_id,
      session_name: $session_name,
      window_index: $window_index,
      pane_index: $pane_index,
      pane_id: $pane_id,
      pane_pid: $pane_pid,
      cwd: $cwd,
      title: $title,
      current_command: $current_command,
      last_command: $last_command,
      pending_buffer: $pending_buffer,
      pending_cursor: $pending_cursor,
      selected_command: $selected_command,
      selected_source: $selected_source,
      agent: $agent,
      neovim: $neovim
    }' >>"$panes_jsonl"

  if workspace_config_bool '.capture.treemux'; then
    registration="$(tmux show-option -gqv "@-treemux-registered-pane-${pane_id}" 2>/dev/null || true)"
    if [ -n "$registration" ]; then
      sidebar_id="${registration%%,*}"
      treemux_args="${registration#*,}"
      sidebar_logical_id="$(tmux display-message -pt "$sidebar_id" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
      if [ -n "$sidebar_logical_id" ]; then
        jq -nc \
          --arg main_logical_id "$logical_id" \
          --arg sidebar_logical_id "$sidebar_logical_id" \
          --arg args "$treemux_args" \
          '{main_logical_id: $main_logical_id, sidebar_logical_id: $sidebar_logical_id, args: $args}' \
          >>"$treemux_jsonl"
      fi
    fi
  fi
done < <(tmux list-panes -a -F '#{pane_id}')

snapshot=""
if [ -L "$resurrect_dir/last" ]; then
  snapshot="$(readlink "$resurrect_dir/last")"
elif [ -f "$resurrect_dir/last" ]; then
  snapshot="last"
fi

temp_sidecar="$(mktemp "$resurrect_dir/.workspace-state.XXXXXX")"
jq -n \
  --argjson version 1 \
  --arg saved_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg resurrect_snapshot "$snapshot" \
  --slurpfile panes "$panes_jsonl" \
  --slurpfile treemux "$treemux_jsonl" \
  '{
    version: $version,
    saved_at: $saved_at,
    resurrect_snapshot: $resurrect_snapshot,
    panes: $panes,
    treemux: $treemux
  }' >"$temp_sidecar"
chmod 0600 "$temp_sidecar"
mv "$temp_sidecar" "$sidecar"

workspace_log "saved $(jq '.panes | length' "$sidecar") pane records alongside ${snapshot:-unknown snapshot}"
