# Start new tmux clients behind rw-paste-shim, so a file dropped (or a path
# pasted) into a remote workspace pane is copied to the worker and its
# worker path is pasted instead (docs/tasks/drop-to-remote-paste.md, C1, C5).
#
# Only `tmux`, `tmux new[-session] ...` (not -d: nothing to attach) and
# `tmux a[t]/attach[-session] ...` typed at an interactive prompt outside
# tmux, with a terminal on both ends. Anything else, and every escape hatch,
# is plain tmux:
#   command tmux ...     bypass for one command
#   RW_PASTE_SHIM=0      bypass for this shell
# Running clients are untouched until they are reattached.
#
# The shim runs on the real Python of the developer tools, never the
# /usr/bin/python3 xcrun stub, which after an Xcode or macOS update exits 69
# (license) or opens the install dialog (W2-5). It is loaded through a tiny
# bootstrap, so even a syntax error in it exits 213; on 213 (the shim failed
# before tmux started) this runs plain tmux.

[[ -o interactive ]] || return

typeset -g _RW_PASTE_SHIM_BIN="$HOME/.config/tmux/local-plugins/tmux-remote-workspaces/libexec/rw-paste-shim"
unset _RW_PASTE_SHIM_PY

# The real interpreter, kept in the global _RW_PASTE_SHIM_PY ("" when there
# is none). Resolved on first use (one xcode-select call) and again whenever
# the cached path is no longer executable (Xcode moved or updated under a
# long-lived shell, W2R-5).
_rw_paste_shim_python() {
  if [[ -z ${_RW_PASTE_SHIM_PY+set} || ( -n $_RW_PASTE_SHIM_PY && ! -x $_RW_PASTE_SHIM_PY ) ]]; then
    local dev c
    dev=$(command xcode-select -p 2>/dev/null)
    _RW_PASTE_SHIM_PY=""
    for c in ${dev:+"$dev/usr/bin/python3"} /Library/Developer/CommandLineTools/usr/bin/python3; do
      if [[ -x $c ]]; then
        _RW_PASTE_SHIM_PY=$c
        break
      fi
    done
  fi
  [[ -n $_RW_PASTE_SHIM_PY ]]
}

_rw_paste_shim_wanted() {
  case ${1-} in
    ''|attach|attach-session|a|at) return 0 ;;
    new|new-session)
      # A standalone -d among new-session's own flags (before the shell
      # command): detached, nothing to relay. Values of the flags that take
      # one are skipped, so `-s dev -d` counts and `-sdev`, `vim -d f` do
      # not (W2R-10b).
      local -i i=2
      while (( i <= $# )); do
        case ${@[i]} in
          -d) return 1 ;;
          -c|-e|-f|-F|-n|-s|-t|-x|-y) (( i += 2 )); continue ;;
          --) break ;;
          -?*) ;;
          *) break ;;
        esac
        (( i++ ))
      done
      return 0
      ;;
  esac
  return 1
}

tmux() {
  if [[ -t 0 && -t 1 && -z ${TMUX:-} && ${RW_PASTE_SHIM:-} != 0 && -r $_RW_PASTE_SHIM_BIN ]] &&
     _rw_paste_shim_wanted "$@" && _rw_paste_shim_python; then
    # -I: isolated mode, so neither the current directory nor PYTHONPATH
    # can shadow the standard library (a project's tty.py, W2R-1).
    "$_RW_PASTE_SHIM_PY" -I -c '
import sys
try:
    import runpy
    shim = runpy.run_path(sys.argv[1], run_name="rw_paste_shim")
except KeyboardInterrupt:
    sys.exit(130)
except Exception:
    sys.exit(213)
shim["main"](sys.argv[2:])
' "$_RW_PASTE_SHIM_BIN" "$@"
    local rc=$?
    # 213: the shim failed before tmux started; 126/127: the interpreter
    # could not be run at all (tmux itself only exits 0 or 1).
    (( rc == 213 || rc == 126 || rc == 127 )) || return $rc
  fi
  command tmux "$@"
}
