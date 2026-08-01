#!/usr/bin/env bash

WORKSPACE_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_CONFIG_FILE="${TMUX_WORKSPACE_RESURRECT_CONFIG:-$WORKSPACE_PLUGIN_DIR/config.json}"

workspace_state_dir() {
  printf '%s\n' "${TMUX_WORKSPACE_RESURRECT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-workspace-resurrect}"
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
  printf '%s/workspace_state.json\n' "$(workspace_resurrect_dir)"
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
  local command="$1"
  case " $command " in
    *" claude "* | *"/claude "*) printf 'claude\n' ;;
    *" codex "* | *"/codex "*) printf 'codex\n' ;;
    *" pi "* | *"/pi "*) printf 'pi\n' ;;
  esac
}

workspace_command_is_shell() {
  case "$1" in
    zsh | -zsh | bash | -bash | fish | sh | dash) return 0 ;;
    *) return 1 ;;
  esac
}

workspace_resume_command() {
  local tool="$1"
  local session_id="$2"
  local launch_command="$3"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$tool" "$session_id" "$launch_command" <<'PY'
import shlex
import sys

tool, session_id, command = sys.argv[1:4]
try:
    argv = shlex.split(command)
except ValueError:
    argv = []

if not argv:
    argv = [tool]

result = []
i = 0
while i < len(argv):
    arg = argv[i]
    if tool == "claude" and arg in {"--resume", "-r", "--session-id"}:
        i += 2
        continue
    if tool == "claude" and arg in {"--continue", "-c"}:
        i += 1
        continue
    if tool == "pi" and arg in {"--session", "--resume", "-r"}:
        i += 2
        continue
    if tool == "pi" and arg in {"--continue", "-c"}:
        i += 1
        continue
    if tool == "codex" and arg == "resume":
        i += 2
        continue
    result.append(arg)
    i += 1

if tool == "claude":
    result.extend(["--resume", session_id])
elif tool == "codex":
    result.extend(["resume", session_id])
elif tool == "pi":
    result.extend(["--session", session_id])

print(shlex.join(result))
PY
    return
  fi

  case "$tool" in
    claude) printf 'claude --resume %s\n' "$(workspace_shell_quote "$session_id")" ;;
    codex) printf 'codex resume %s\n' "$(workspace_shell_quote "$session_id")" ;;
    pi) printf 'pi --session %s\n' "$(workspace_shell_quote "$session_id")" ;;
  esac
}

workspace_pane_state_file() {
  local pane_id="${1#%}"
  printf '%s/agents/pane-%s.json\n' "$(workspace_state_dir)" "$pane_id"
}
