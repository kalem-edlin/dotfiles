#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
test_root=$(mktemp -d /tmp/tmux-split-size.XXXXXX)
export socket="$test_root/server.sock"
cleanup() {
  command tmux -S "$socket" kill-server 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

# All test processes run in foreground panes on a dedicated test server.
# Cleanup stops them, and sleep bounds their lifetime if cleanup fails.
command tmux -S "$socket" -f /dev/null new-session -d -s processes -n split-test -x 200 -y 60 'sleep 60'
command tmux -S "$socket" set-option -g status off
command tmux -S "$socket" set-option -g default-command 'sleep 60'
export remote_command_log="$test_root/remote-command"
tmux() {
  # Exercise remote split sizing without starting an actual remote endpoint.
  if [ "$1" = split-window ] && [[ "${!#}" == *' ensure --worker '* ]]; then
    printf '%s\n' "${!#}" > "$remote_command_log"
    command tmux -S "$socket" "${@:1:$#-1}" 'sleep 60'
  else
    command tmux -S "$socket" "$@"
  fi
}
export -f tmux
source_pane=$(tmux display-message -p -t processes:split-test '#{pane_id}')
export TMUX_PANE="$source_pane"

check_split() {
  local direction="$1" width="$2" height="$3" remote="${4:-no}"
  local dimension flag shrink step equal_size new_pane actual expected
  tmux resize-window -t "$source_pane" -x "$width" -y "$height"
  if [ "$direction" = h ]; then
    dimension='#{pane_width}' flag=-h shrink=-R step=20
  else
    dimension='#{pane_height}' flag=-v shrink=-D step=0
  fi

  # Horizontal splits subtract 20 columns. Vertical splits stay equal.
  new_pane=$(tmux split-window "$flag" -t "$source_pane" -P -F '#{pane_id}')
  equal_size=$(tmux display-message -p -t "$new_pane" "$dimension")
  expected=$((equal_size - step))
  [ "$expected" -ge 1 ] || expected=1
  if [ "$step" -gt 0 ] && [ "$expected" -gt 1 ]; then
    tmux resize-pane -t "$new_pane" "$shrink" "$step"
    test "$(tmux display-message -p -t "$new_pane" "$dimension")" = "$expected"
  fi
  tmux kill-pane -t "$new_pane"

  if [ "$remote" = yes ]; then
    tmux set-option -p -t "$source_pane" @rw-endpoint test-endpoint
    tmux set-option -p -t "$source_pane" @remote-host test-host
    tmux set-option -p -t "$source_pane" @rw-worker test-worker
    tmux set-option -p -t "$source_pane" @rw-workspace test-workspace
  fi
  bash "$repo/tmux/local-plugins/tmux-remote-workspaces/scripts/rw-split.sh" "$direction"
  new_pane=$(tmux display-message -p -t processes:split-test '#{pane_id}')
  actual=$(tmux display-message -p -t "$new_pane" "$dimension")
  test "$actual" = "$expected"
  test "$(tmux display-message -p -t "$source_pane" "$dimension")" -ge "$equal_size"
  tmux kill-pane -t "$new_pane"
  if [ "$remote" = yes ]; then
    grep -q 'ensure --worker "test-worker" --workspace "test-workspace"' "$remote_command_log"
    for option in @rw-endpoint @remote-host @rw-worker @rw-workspace; do
      tmux set-option -pu -t "$source_pane" "$option"
    done
  fi
}

check_split h 200 60
check_split h 201 60
check_split v 200 60
check_split v 200 61
check_split h 30 60
check_split v 200 12
check_split h 4 60
check_split v 200 4
check_split h 200 60 yes
check_split v 200 60 yes
printf 'split sizing tests passed (local, remote, odd/even sizes, small panes)\n'
