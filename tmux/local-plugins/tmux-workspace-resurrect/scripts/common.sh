#!/usr/bin/env bash

WORKSPACE_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_CONFIG_FILE="${TMUX_WORKSPACE_RESURRECT_CONFIG:-$WORKSPACE_PLUGIN_DIR/config.json}"

workspace_state_dir() {
  local configured="${TMUX_WORKSPACE_RESURRECT_STATE_DIR:-}"
  if [ -z "$configured" ] && [ -n "${TMUX:-}" ]; then
    configured="$(tmux show-environment -g TMUX_WORKSPACE_RESURRECT_STATE_DIR 2>/dev/null || true)"
    configured="${configured#TMUX_WORKSPACE_RESURRECT_STATE_DIR=}"
    case "$configured" in -TMUX_WORKSPACE_RESURRECT_STATE_DIR | '') configured="" ;; esac
  fi
  printf '%s\n' "${configured:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-workspace-resurrect}"
}

workspace_resurrect_dir() {
  if [ -n "${TMUX_RESURRECT_DIR:-}" ]; then
    printf '%s\n' "$TMUX_RESURRECT_DIR"
    return
  fi

  local configured host
  configured="$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)"
  if [ -z "$configured" ]; then
    if [ -d "$HOME/.tmux/resurrect" ]; then
      configured="$HOME/.tmux/resurrect"
    else
      configured="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
    fi
  fi

  host="$(hostname 2>/dev/null || true)"
  printf '%s\n' "$configured" |
    sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}

workspace_sidecar_file() {
  local resurrect_dir snapshot companion
  resurrect_dir="$(workspace_resurrect_dir)"
  snapshot="$(readlink "$resurrect_dir/last" 2>/dev/null || true)"
  companion="$resurrect_dir/$snapshot.workspace_state.json"
  if [ -n "$snapshot" ] && [ -f "$companion" ]; then
    printf '%s\n' "$companion"
  else
    # Backwards compatibility for older snapshots and for the save hook's
    # private staging directory before its companion has been published.
    printf '%s/workspace_state.json\n' "$resurrect_dir"
  fi
}

workspace_log_file() {
  printf '%s/workspace-resurrect.log\n' "$(workspace_state_dir)"
}

workspace_ensure_private_dir() {
  local dir="$1"
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
}

workspace_log() {
  local message="$1"
  local state_dir
  state_dir="$(workspace_state_dir)"
  workspace_ensure_private_dir "$state_dir"
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" >>"$(workspace_log_file)"
  chmod 0600 "$(workspace_log_file)" 2>/dev/null || true
}

workspace_config_bool() {
  local path="$1"
  jq -er "$path == true" "$WORKSPACE_CONFIG_FILE" >/dev/null 2>&1
}

workspace_shell_quote() {
  local value="$1"
  value="${value//\'/\'\"\'\"\'}"
  printf "'%s'" "$value"
}

workspace_infer_agent() {
  python3 "$WORKSPACE_PLUGIN_DIR/scripts/agent_command.py" infer "$1"
}

workspace_command_is_shell() {
  case "$1" in
    zsh | -zsh | bash | -bash | fish | sh | dash) return 0 ;;
    *) return 1 ;;
  esac
}

workspace_resume_command() {
  python3 "$WORKSPACE_PLUGIN_DIR/scripts/agent_command.py" resume "$1" "$2" "$3"
}

workspace_pane_state_file() {
  local pane_id="${1#%}" access="${2:-read}" server_identity="${3:-}" scoped legacy
  if [ -z "$server_identity" ]; then
    server_identity="$(tmux display-message -p '#{pid}:#{start_time}' 2>/dev/null || true)"
  fi
  [[ "$server_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  scoped="$(workspace_state_dir)/agents/server-${server_identity/:/-}/pane-$pane_id.json"
  legacy="$(workspace_state_dir)/agents/pane-$pane_id.json"

  case "$access" in
    write) printf '%s\n' "$scoped" ;;
    read)
      if [ -f "$scoped" ]; then
        printf '%s\n' "$scoped"
      else
        printf '%s\n' "$legacy"
      fi
      ;;
    *) return 2 ;;
  esac
}
