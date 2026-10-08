# Capture the exact submitted command and current ZLE edit buffer for the
# tmux-workspace-resurrect companion plugin.

[[ -o interactive ]] || return

autoload -Uz add-zsh-hook
autoload -Uz add-zle-hook-widget

typeset -g _WORKSPACE_RESURRECT_LAST_BUFFER=""
typeset -g _WORKSPACE_RESURRECT_LAST_CURSOR="-1"

# One naming attempt per shell, never on each redraw or prompt. The tmux-side
# condition also protects names chosen by another pane or by the user.
_workspace_resurrect_name_first_command() {
  [[ -n "${TMUX_PANE:-}" && -z "${_WORKSPACE_WINDOW_NAME_ATTEMPTED:-}" ]] || return 0
  local word name=""
  local -a words
  words=( ${(z)1} )
  for word in "${words[@]}"; do
    word=${(Q)word}
    if [[ "$word" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]]; then
      continue
    fi
    case "$word" in
      command|exec|noglob|env) continue ;;
    esac
    name=${word:t}
    break
  done
  # Only a command basename belongs in the label, never arguments or a shell
  # expression. Restrict characters before embedding it in a tmux command.
  [[ -n "$name" && "$name" != *[^A-Za-z0-9_.+-]* ]] || return 0
  command tmux if-shell -F -t "$TMUX_PANE" \
    '#{&&:#{automatic-rename},#{==:#{@workspace-first-command},}}' \
    "set-option -wqt '$TMUX_PANE' @workspace-first-command '$name'; rename-window -t '$TMUX_PANE' '$name'" 2>/dev/null &&
    typeset -g _WORKSPACE_WINDOW_NAME_ATTEMPTED=1
  return 0
}

_workspace_resurrect_set_pane_option() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  command tmux set-option -pqt "$TMUX_PANE" "$1" "$2" 2>/dev/null
}

_workspace_resurrect_preexec() {
  _workspace_resurrect_name_first_command "$1"
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

_workspace_resurrect_restore_cursor() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  local saved_cursor
  saved_cursor="$(command tmux show-option -pqt "$TMUX_PANE" -v @workspace-restore-cursor-target 2>/dev/null)" || return 0
  [[ "$saved_cursor" == <-> && "$saved_cursor" -le "${#BUFFER}" ]] || return 0
  CURSOR="$saved_cursor"
  _workspace_resurrect_set_pane_option @workspace-restore-cursor-target ""
  _workspace_resurrect_capture_buffer
}

zle -N _workspace_resurrect_restore_cursor
# CSI 99~ is private to this integration. Bind it in both normal insert
# keymaps so cursor restoration does not depend on emacs/vi movement rules.
bindkey -M emacs $'\e[99~' _workspace_resurrect_restore_cursor
bindkey -M viins $'\e[99~' _workspace_resurrect_restore_cursor

_workspace_resurrect_line_init() {
  _workspace_resurrect_capture_buffer
  _workspace_resurrect_set_pane_option @workspace-shell-integration "zsh-v1"
  _workspace_resurrect_set_pane_option @workspace-restore-cursor-widget "1"
}

add-zsh-hook preexec _workspace_resurrect_preexec
add-zle-hook-widget line-init _workspace_resurrect_line_init
add-zle-hook-widget line-pre-redraw _workspace_resurrect_capture_buffer
