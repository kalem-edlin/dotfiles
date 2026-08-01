# Capture the exact submitted command and current ZLE edit buffer for the
# tmux-workspace-resurrect companion plugin.

[[ -o interactive ]] || return

autoload -Uz add-zsh-hook
autoload -Uz add-zle-hook-widget

typeset -g _WORKSPACE_RESURRECT_LAST_BUFFER=""
typeset -g _WORKSPACE_RESURRECT_LAST_CURSOR="-1"

_workspace_resurrect_set_pane_option() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  command tmux set-option -pqt "$TMUX_PANE" "$1" "$2" 2>/dev/null
}

_workspace_resurrect_preexec() {
  _workspace_resurrect_set_pane_option @workspace-last-command "$1"
  _workspace_resurrect_set_pane_option @workspace-pending-buffer ""
  _workspace_resurrect_set_pane_option @workspace-pending-cursor "0"
  _WORKSPACE_RESURRECT_LAST_BUFFER=""
  _WORKSPACE_RESURRECT_LAST_CURSOR="0"
}

_workspace_resurrect_capture_buffer() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  if [[ "$BUFFER" != "$_WORKSPACE_RESURRECT_LAST_BUFFER" ||
        "$CURSOR" != "$_WORKSPACE_RESURRECT_LAST_CURSOR" ]]; then
    _workspace_resurrect_set_pane_option @workspace-pending-buffer "$BUFFER"
    _workspace_resurrect_set_pane_option @workspace-pending-cursor "$CURSOR"
    _WORKSPACE_RESURRECT_LAST_BUFFER="$BUFFER"
    _WORKSPACE_RESURRECT_LAST_CURSOR="$CURSOR"
  fi
}

_workspace_resurrect_line_init() {
  _workspace_resurrect_capture_buffer
  _workspace_resurrect_set_pane_option @workspace-shell-integration "zsh-v1"
}

add-zsh-hook preexec _workspace_resurrect_preexec
add-zle-hook-widget line-init _workspace_resurrect_line_init
add-zle-hook-widget line-pre-redraw _workspace_resurrect_capture_buffer
