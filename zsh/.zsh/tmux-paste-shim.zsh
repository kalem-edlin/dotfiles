# Start new tmux clients behind rw-paste-shim, so a file dropped (or a path
# pasted) into a remote workspace pane is copied to the worker and its
# worker path is pasted instead (docs/tasks/drop-to-remote-paste.md, C1).
#
# Only `tmux`, `tmux new[-session] ...` and `tmux a[t]/attach[-session] ...`
# typed at an interactive prompt outside tmux, with a terminal on both ends.
# Anything else, and every escape hatch, is plain tmux:
#   command tmux ...     bypass for one command
#   RW_PASTE_SHIM=0      bypass for this shell
# Running clients are untouched until they are reattached.

[[ -o interactive ]] || return

typeset -g _RW_PASTE_SHIM_BIN="$HOME/.config/tmux/local-plugins/tmux-remote-workspaces/libexec/rw-paste-shim"

tmux() {
  if [[ -t 0 && -t 1 && -z ${TMUX:-} && ${RW_PASTE_SHIM:-} != 0 &&
        -x /usr/bin/python3 && -x $_RW_PASTE_SHIM_BIN ]]; then
    case ${1-} in
      ''|new|new-session|attach|attach-session|a|at)
        "$_RW_PASTE_SHIM_BIN" "$@"
        return
        ;;
    esac
  fi
  command tmux "$@"
}
