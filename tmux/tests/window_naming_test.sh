#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
test_root=$(mktemp -d /tmp/tmux-window-naming.XXXXXX)
socket="$test_root/server.sock"
cleanup() { tmux -S "$socket" kill-server 2>/dev/null || true; }
trap cleanup EXIT

# This is a dedicated test server. Never send keys to a user's shell.
tmux -S "$socket" -f /dev/null new-session -d -s test 'sleep 120'
format=$(sed -n "s/^setw -g automatic-rename-format '\(.*\)'$/\1/p" "$repo/tmux/tmux.conf")
test -n "$format"
tmux -S "$socket" set-option -gw automatic-rename-format "$format"
pane=$(tmux -S "$socket" new-window -P -F '#{pane_id}' '/bin/zsh -dfi')
server_pid=$(tmux -S "$socket" display-message -p '#{pid}')
export TMUX="$socket,$server_pid,0" TMUX_PANE="$pane"

label() { tmux -S "$socket" display-message -p -t "$pane" "#{E:automatic-rename-format}"; }
test "$(label)" = '[empty]'
for attempt in {1..30}; do
  actual=$(tmux -S "$socket" display-message -p -t "$pane" '#{window_name}')
  [ "$actual" = '[empty]' ] && break
  sleep 0.1
done
test "$actual" = '[empty]'

# Exercise the actual hook in a clean interactive zsh without reading user rc.
name_first() {
  zsh -dfi -c 'source "$1"; _workspace_resurrect_name_first_command "$2"' \
    _ "$repo/zsh/.zsh/tmux-workspace-resurrect.zsh" "$1"
}
name_first 'CODEX_HOME=/tmp/example codex resume abc'
test "$(label)" = codex
test "$(tmux -S "$socket" display-message -p -t "$pane" '#{window_name}')" = codex
name_first 'pif --resume example'
test "$(label)" = codex

for submitted in 'pif --resume example' 'claudef --resume example' 'env FOO=bar command /usr/local/bin/codex'; do
  tmux -S "$socket" set-option -wut "$pane" @workspace-first-command
  tmux -S "$socket" set-option -wt "$pane" automatic-rename on
  name_first "$submitted"
  case "$submitted" in
    pif*) test "$(label)" = pif ;;
    claudef*) test "$(label)" = claudef ;;
    *) test "$(label)" = codex ;;
  esac
done

tmux -S "$socket" set-option -wut "$pane" @workspace-first-command
tmux -S "$socket" set-option -wt "$pane" automatic-rename on
name_first '"bad;name" argument'
test "$(label)" = '[empty]'
tmux -S "$socket" rename-window -t "$pane" 'my manual name'
name_first 'claudef'
test "$(tmux -S "$socket" display-message -p -t "$pane" '#{window_name}')" = 'my manual name'
test -z "$(tmux -S "$socket" show-option -wqv -t "$pane" @workspace-first-command)"
printf 'window naming tests passed\n'
