#!/usr/bin/env bash
# chat-move-test.sh: drives git/.local/bin/chat-move against an isolated tmux
# server. Never touches the live server: every tmux call goes through a shim
# pinned to a test socket, TMUX and TMUX_PANE are cleared, TMUX_TMPDIR points
# into the scratch dir. claudef and pif are fakes on PATH that log their
# argv, publish @agent_pid as the real publishers do, and sleep.
set -u
cd "$(dirname "$0")/../../../.." || exit 1
CM="$PWD/git/.local/bin/chat-move"
[ -x "$CM" ] || { echo "ABORT: $CM not executable" >&2; exit 1; }

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
is() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
has() { case $3 in *"$2"*) ok ;; *) bad "$1: [$2] not in [$3]" ;; esac; }
# wait_for LABEL SECONDS CMD...: polls CMD until it succeeds.
wait_for() {
  local l=$1 n=$2 i=0; shift 2
  while ! "$@" >/dev/null 2>&1; do
    [ "$i" -ge "$n" ] && { bad "$l: not within ${n}s"; return 1; }
    sleep 1; i=$((i + 1))
  done
  ok
}

scratch="$(mktemp -d /tmp/chat-move-test.XXXXXX)" || exit 1
scratch="$(cd "$scratch" && pwd -P)"
sock="$scratch/sock"
real_tmux="$(command -v tmux)"
cleanup() {
  [ -S "$sock" ] && "$real_tmux" -S "$sock" kill-server 2>/dev/null
  rm -rf "$scratch"
}
trap cleanup EXIT

shim="$scratch/shim"
mkdir -p "$shim" "$scratch/tmux-tmpdir" "$scratch/state"
printf 'set -g default-shell /bin/sh\nset -g default-command ""\n' >"$scratch/tmux.conf"
cat >"$shim/tmux" <<SHIM
#!/bin/sh
exec '$real_tmux' -S '$sock' -f '$scratch/tmux.conf' "\$@"
SHIM
# Fakes: log argv one per line between markers, publish like the real
# publishers, then idle. FAKE_EXIT=1 makes one die at once (agent never up).
for f in claudef pif; do
  cat >"$shim/$f" <<FAKE
#!/bin/sh
{ printf 'BEGIN\n'; for a in "\$@"; do printf '%s\n' "\$a"; done; printf 'END\n'; } >>'$scratch/$f.log'
[ -f '$scratch/fake-exit' ] && exit 3
# Claude's trust dialog for a new directory: shown until a line arrives.
if [ -f '$scratch/fake-trust' ]; then
  printf '> No, exit\n  Yes, I trust this folder\n'
  IFS= read -r answer
  printf 'ANSWER %s\n' "\$answer" | od -c | head -1 >>'$scratch/trust.log'
fi
tmux set -p -t "\$TMUX_PANE" @agent_kind ${f%f} \; set -p -t "\$TMUX_PANE" @agent_pid \$\$
sleep 120
FAKE
done
chmod +x "$shim/tmux" "$shim/claudef" "$shim/pif"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID PI_SESSION_FILE
export PATH="$shim:$PATH" TMUX_TMPDIR="$scratch/tmux-tmpdir" XDG_STATE_HOME="$scratch/state"
export CHAT_MOVE_TURN_WAIT=20 CHAT_MOVE_AGENT_WAIT=5
[ "$(command -v tmux)" = "$shim/tmux" ] || { echo "ABORT: tmux is not the shim" >&2; exit 1; }
jobs_dir="$scratch/state/chat-move"
no_jobs() { [ -z "$(ls "$jobs_dir" 2>/dev/null | grep job)" ]; }

# Target worktree dirs and an "old" session whose window has two panes, so
# the session outlives the chat pane.
mkdir -p "$scratch/dev/feat-one" "$scratch/dev/v1.2:x"
tmux new-session -d -s old -c "$scratch" -n chat
old=$(tmux display-message -p -t old:chat '#{pane_id}')
side=$(tmux split-window -d -P -F '#{pane_id}' -t "$old" -c "$scratch")
tmux set -p -t "$old" @agent_state working

# --- usage and refusals ---
out=$(cd "$scratch" && "$CM" 2>&1); is "no args is usage" "$?" 2
out=$(cd "$scratch" && "$CM" "$scratch/dev/feat-one" 2>&1); is "no message is usage" "$?" 2
out=$(cd "$scratch" && "$CM" "$scratch/dev/nope" --message hi 2>&1); is "missing dir rc" "$?" 1
has "missing dir text" "no such directory" "$out"
out=$(cd "$scratch" && "$CM" "$scratch/dev/feat-one" --message hi 2>&1); is "no pane rc" "$?" 1
has "no pane text" "TMUX_PANE unset" "$out"
out=$(cd "$scratch" && TMUX_PANE="$old" "$CM" "$scratch/dev/feat-one" --message hi 2>&1); is "no chat env rc" "$?" 1
has "no chat env text" "no CLAUDE_CODE_SESSION_ID or PI_SESSION_FILE" "$out"
out=$(cd "$scratch" && TMUX_PANE="$old" PI_SESSION_FILE="$scratch/none.jsonl" "$CM" "$scratch/dev/feat-one" --message hi 2>&1); is "pi file missing rc" "$?" 1
is "nothing queued by refusals" "$(ls "$jobs_dir" 2>/dev/null | grep -c job)" 0

# --- claude chat moves: message with quotes and lines, session created,
# the trust dialog of a new directory answered ---
touch "$scratch/fake-trust"
printf 'Continue here.\nSay "hi" to $USER and `ls`.\n' >"$scratch/msg"
out=$(cd "$scratch" && TMUX_PANE="$old" CLAUDE_CODE_SESSION_ID=sid-123 "$CM" "$scratch/dev/feat-one" --message-file "$scratch/msg" 2>&1)
is "claude queued rc" "$?" 0
has "claude queued text" "this claude chat moves to session feat-one ($scratch/dev/feat-one) when this turn ends" "$out"
is "one job queued" "$(ls "$jobs_dir" | grep -c job)" 1
sleep 2
is "nothing happens while working" "$(tmux has-session -t '=feat-one:' 2>/dev/null; echo $?)" 1
is "old pane alive while working" "$(tmux display-message -p -t "$old" '#{pane_id}')" "$old"
tmux set -p -t "$old" @agent_state idle
wait_for "job finished" 15 no_jobs
is "session created" "$(tmux has-session -t '=feat-one:' 2>/dev/null; echo $?)" 0
is "session rooted at the worktree" "$(tmux display-message -p -t '=feat-one:' '#{pane_current_path}')" "$scratch/dev/feat-one"
is "window named claudef" "$(tmux display-message -p -t '=feat-one:' '#{window_name}')" claudef
is "fake claudef argv" "$(cat "$scratch/claudef.log")" "$(printf 'BEGIN\n--resume\nsid-123\nContinue here.\nSay "hi" to $USER and `ls`.\nEND')"
is "agent published on the new pane" "$(tmux display-message -p -t '=feat-one:' '#{@agent_kind}')" claude
is "old pane killed" "$(tmux display-message -p -t "$old" '#{pane_id}' 2>/dev/null)" ""
is "sibling pane kept" "$(tmux display-message -p -t "$side" '#{pane_id}')" "$side"
is "old session kept" "$(tmux has-session -t '=old:' 2>/dev/null; echo $?)" 0
has "log done" "claude chat resumed in" "$(cat "$jobs_dir/log")"
has "log created" "created=1, old pane $old killed" "$(cat "$jobs_dir/log")"
has "trust dialog answered" "answered the trust dialog in" "$(cat "$jobs_dir/log")"
has "trust answer was Down" "033   [   B" "$(cat "$scratch/trust.log")"
command rm -f "$scratch/fake-trust"

# --- pi chat moves into an existing session: a window is added ---
old=$(tmux split-window -d -P -F '#{pane_id}' -t "$side" -c "$scratch")
tmux set -p -t "$old" @agent_state working
tmux new-session -d -s v1_2_x -c "$scratch/dev/v1.2:x" -n shell
printf 'x\n' >"$scratch/pi.jsonl"
out=$(cd "$scratch" && TMUX_PANE="$old" PI_SESSION_FILE="$scratch/pi.jsonl" "$CM" "$scratch/dev/v1.2:x" --message "fork me" 2>&1)
is "pi queued rc" "$?" 0
has "pi queued text" "this pi chat moves to session v1_2_x" "$out"
tmux set -p -t "$old" @agent_state finished
wait_for "pi job finished" 15 no_jobs
is "existing session got a window" "$(tmux list-windows -t '=v1_2_x:' -F '#{window_name}' | tr '\n' ' ')" "shell pif "
is "fake pif argv" "$(cat "$scratch/pif.log")" "$(printf 'BEGIN\n--fork\n%s\nfork me\nEND' "$scratch/pi.jsonl")"
is "pi window rooted at the worktree" "$(tmux display-message -p -t '=v1_2_x:pif' '#{pane_current_path}')" "$scratch/dev/v1.2:x"
is "pi old pane killed" "$(tmux display-message -p -t "$old" '#{pane_id}' 2>/dev/null)" ""

# --- the agent never comes up: the chat stays, the message is kept ---
old=$(tmux split-window -d -P -F '#{pane_id}' -t "$side" -c "$scratch")
tmux set -p -t "$old" @agent_state idle
touch "$scratch/fake-exit"
mkdir -p "$scratch/dev/feat-two"
out=$(cd "$scratch" && TMUX_PANE="$old" CLAUDE_CODE_SESSION_ID=sid-9 "$CM" "$scratch/dev/feat-two" --message "never" 2>&1)
is "fail case queued" "$?" 0
wait_for "fail logged" 15 grep -q "job .* failed:" "$jobs_dir/log"
has "fail reason" "no agent in %7 after 5s; this chat stays, see feat-two" "$(cat "$jobs_dir/log")"
is "old pane kept on failure" "$(tmux display-message -p -t "$old" '#{pane_id}')" "$old"
is "job kept on failure" "$(ls "$jobs_dir" | grep -c job)" 1
is "message kept on failure" "$(cat "$jobs_dir"/job.*/message)" never
rm -f "$scratch/fake-exit"

# --- the turn never ends: nothing moves ---
old=$(tmux split-window -d -P -F '#{pane_id}' -t "$side" -c "$scratch")
tmux set -p -t "$old" @agent_state working
rm -rf "$jobs_dir"/job.*
mkdir -p "$scratch/dev/feat-three"
out=$(cd "$scratch" && TMUX_PANE="$old" CLAUDE_CODE_SESSION_ID=sid-10 CHAT_MOVE_TURN_WAIT=2 "$CM" "$scratch/dev/feat-three" --message "stuck" 2>&1)
wait_for "turn timeout logged" 10 grep -q "turn still running after 2s" "$jobs_dir/log"
is "no session for the stuck turn" "$(tmux has-session -t '=feat-three:' 2>/dev/null; echo $?)" 1
is "stuck old pane kept" "$(tmux display-message -p -t "$old" '#{pane_id}')" "$old"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
