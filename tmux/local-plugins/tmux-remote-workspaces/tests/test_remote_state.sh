#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# R1 remote agent state (contracts CX1/CX2): the worker-side poll loop, the
# laptop-side mirror of @agent_* onto the attaching pane, the disconnect
# value, the @rw-request hand-back, and the side channel's lifecycle under
# the attach loop. No tmux server and no network: a tmux stub that keeps
# pane options in files (and understands `;` chains and if-shell -F), and a
# fake ssh that replays scripted worker lines.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

# --- stubs -------------------------------------------------------------------
OPTS="$SANDBOX/opts"
mkdir -p "$OPTS" "$SANDBOX/rbin"
export OPTS SANDBOX
cat >"$SANDBOX/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Laptop tmux stub: pane options are files $OPTS/<pane>/<option>. Commands
# chained with a ";" argument run in order. if-shell -F picks its branch
# from $FAKE_VISIBLE (1: the pane is in view). run-shell is only logged.
printf '%s\n' "$*" >>"${FAKE_TMUX_LOG:-/dev/null}"
run_one() {
  local cmd="$1" target="" unset_opt=0 f
  shift
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -F) [ "$cmd" = if-shell ] && { shift; continue; }; rest+=("$1"); shift ;;
      -*)
        f="$1"
        case "$f" in *u*) unset_opt=1 ;; esac
        if [ "${f: -1}" = t ]; then target="$2"; shift 2; else shift; fi
        ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  case "$cmd" in
    set-option)
      mkdir -p "$OPTS/$target"
      if [ "$unset_opt" = 1 ]; then rm -f "$OPTS/$target/${rest[0]}"; else printf '%s' "${rest[1]:-}" >"$OPTS/$target/${rest[0]}"; fi
      ;;
    show-option)
      [ -f "$OPTS/$target/${rest[0]}" ] && { cat "$OPTS/$target/${rest[0]}"; echo; }
      ;;
    if-shell)
      local chosen="${rest[1]}"
      [ "${FAKE_VISIBLE:-1}" = 1 ] || chosen="${rest[2]:-}"
      # shellcheck disable=SC2086 # the branch is a plain command line
      [ -n "$chosen" ] && run_one $chosen
      ;;
  esac
  return 0
}
args=()
for a in "$@"; do
  if [ "$a" = ";" ]; then run_one "${args[@]}"; args=(); else args+=("$a"); fi
done
[ "${#args[@]}" -gt 0 ] && run_one "${args[@]}"
exit 0
EOF
chmod +x "$SANDBOX/bin/tmux"

# Fake ssh: the watch loop (recognised by its display-message) replays
# $FAKE_STREAM line by line ($FAKE_STREAM_DELAY apart), then stays connected
# while $FAKE_STREAM_HOLD exists. Any other command is logged and succeeds,
# unless $FAKE_SSH_FAIL exists.
cat >"$SANDBOX/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) host="$1"; shift; break ;;
  esac
done
cmd="$*"
case "$cmd" in
  *"display-message -p -t"*)
    printf 'watch\t%s\n' "$host" >>"$FAKE_SSH_LOG"
    while IFS= read -r l; do
      printf '%s\n' "$l"
      sleep "${FAKE_STREAM_DELAY:-0}"
    done <"$FAKE_STREAM"
    while [ -e "${FAKE_STREAM_HOLD:-/nonexistent}" ]; do sleep 0.1; done
    exit 0
    ;;
esac
printf 'cmd\t%s\t%s\n' "$host" "${cmd//$'\n'/ }" >>"$FAKE_SSH_LOG"
[ -e "$SANDBOX/ssh.fail" ] && exit 255
exit 0
EOF
chmod +x "$SANDBOX/bin/ssh"

# shellcheck source=../libexec/remote-state
source "$RW_PLUGIN/libexec/remote-state"

S="$RW_STATE_SEP"
P=%5
EP=ep000001
WROOT="$FAKE_WORKER_HOME/Developer/proj"
rw_write_json_atomic "$(rw_endpoint_file "$EP")" "$(jq -nc --arg wr "$WROOT" --arg rl "$HOME/Developer/proj" \
  '{endpoint_id: "ep000001", worker: "fakeworker", root_rel: "Developer/proj",
    workspace: {remote_path: $wr, focus_path: $rl, root_local: $rl, worker_root: $wr}}')"
opt() { cat "$OPTS/$P/$1" 2>/dev/null; }
has() { [ -f "$OPTS/$P/$1" ]; }
reset_pane() {
  rm -rf "${OPTS:?}/$P"
  mkdir -p "$OPTS/$P"
  printf '%s' "$EP" >"$OPTS/$P/@rw-endpoint"
  : >"$FAKE_SSH_LOG"
  : >"$FAKE_TMUX_LOG"
}
# line <alive> <kind> <state> <state_at> <at> <subs> <empty> <request> <cwd> <name>
line() { printf '%s|%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$1" "$2" "$S" "$3" "$S" "$4" "$S" "$5" "$S" "$6" "$S" "$7" "$S" "$8" "$S" "$9" "$S" "${10}"; }
apply() { rw_state_apply_stream "$EP" "$P" fakeworker rw-x-"$EP" "$WROOT" "$HOME/Developer/proj" Developer/proj; }

# --- worker-side loop ----------------------------------------------------------
# A worker tmux stub answering display-message from $WSTATE ("fail" makes it
# fail like a missing session); run the loop under sh for ~1.2s.
cat >"$SANDBOX/rbin/tmux" <<'EOF'
#!/bin/sh
v=$(cat "$WSTATE" 2>/dev/null)
[ "$v" = fail ] && exit 1
printf '%s\n' "$v"
EOF
chmod +x "$SANDBOX/rbin/tmux"
export WSTATE="$SANDBOX/wstate"
run_worker_loop() { # <shell> [<new value>] -- prints what the loop printed in ~1.2s
  local out="$SANDBOX/wloop.out" pid sh=("$1")
  # zsh -f: no rc files, so no zshenv can put a real tmux back on PATH.
  [ "$1" = zsh ] && sh+=(-f)
  RW_STATE_POLL_SECONDS=0.1 RW_STATE_HEARTBEAT_POLLS=100 \
    PATH="$SANDBOX/rbin:/usr/bin:/bin" "${sh[@]}" -c "$(RW_STATE_POLL_SECONDS=0.1 RW_STATE_HEARTBEAT_POLLS=100 rw_state_watch_cmd rw-x-sess)" >"$out" 2>/dev/null &
  pid=$!
  sleep 0.6
  [ -n "${2:-}" ] && printf '%s' "$2" >"$WSTATE"
  sleep 0.6
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat "$out"
}
sleep 300 &
live=$!
printf '%s|claude%sworking' "$live" "$S" >"$WSTATE"
got="$(run_worker_loop sh)"
eq "worker loop: a live pid reads alive, an unchanged line is printed once" "$got" "1|claude${S}working"
printf '999999|claude%sidle' "$S" >"$WSTATE"
got="$(run_worker_loop sh "fail")"
eq "worker loop: a dead pid reads 0, a failing tmux reads gone" "$got" "0|claude${S}idle
gone"
printf '|%s' "$S" >"$WSTATE"
got="$(run_worker_loop sh)"
eq "worker loop: no pid reads -" "$got" "-|${S}"
if command -v zsh >/dev/null 2>&1; then
  printf '%s|pi%sawaiting' "$live" "$S" >"$WSTATE"
  got="$(run_worker_loop zsh)"
  eq "worker loop runs under zsh too" "$got" "1|pi${S}awaiting"
fi
kill "$live" 2>/dev/null
wait "$live" 2>/dev/null
check "the loop polls one session target, no per-poll ssh" grep -q "t='=rw-x-sess:'" <<<"$(rw_state_watch_cmd rw-x-sess)"

# --- laptop-side mirror -------------------------------------------------------
reset_pane
printf '4242' >"$OPTS/$P/@agent_pid" # left by the local agent stopped at handoff
printf 'idle' >"$OPTS/$P/@agent_state"
line 1 claude working 100 101 2 "" "" "$WROOT/sub" "a${S}b title" | apply
eq "mirror: kind" "$(opt @agent_kind)" claude
eq "mirror: state" "$(opt @agent_state)" working
eq "mirror: state_at" "$(opt @agent_state_at)" 100
eq "mirror: at" "$(opt @agent_at)" 101
eq "mirror: subs" "$(opt @agent_subs)" 2
check "mirror: empty unset" bash -c "! test -f '$OPTS/$P/@agent_empty'"
eq "mirror: name keeps a separator" "$(opt @agent_name)" "a${S}b title"
eq "mirror: worker cwd maps under the laptop root" "$(opt @agent_cwd)" "$HOME/Developer/proj/sub"
check "mirror: stale local @agent_pid dropped" bash -c "! test -f '$OPTS/$P/@agent_pid'"
eq "mirror: one tmux call for the change" "$(wc -l <"$FAKE_TMUX_LOG" | tr -d ' ')" 2 # owns-pane read + write

reset_pane
{ line 1 claude working 100 101 0 "" "" "$FAKE_WORKER_HOME/other" n
  line 1 claude idle 200 201 0 "" "" "/opt/x" n; } | FAKE_VISIBLE=1 apply
eq "working -> idle in view stays idle" "$(opt @agent_state)" idle
check "cwd outside both homes is not mirrored" bash -c "! test -f '$OPTS/$P/@agent_cwd'"
reset_pane
line 1 claude working 100 101 0 "" "" "$FAKE_WORKER_HOME/other" n | apply
eq "cwd under the worker home maps to the laptop home" "$(opt @agent_cwd)" "$HOME/other"
reset_pane
{ line 1 claude working 100 101 0 "" "" "" n
  line 1 claude idle 200 201 0 "" "" "" n; } | FAKE_VISIBLE=0 apply
eq "working -> idle out of view is Done (finished), like a local Stop" "$(opt @agent_state)" finished
eq "its stamp is the worker's" "$(opt @agent_state_at)" 200

reset_pane
{ line 1 claude working 100 101 0 "" "" "" n
  line 1 claude idle 200 201 0 "" "" "" n
  line 1 claude idle 200 205 0 "" "" "" renamed; } | FAKE_VISIBLE=0 apply
eq "a later field change is mirrored" "$(opt @agent_name)" renamed
eq "but does not rewrite the laptop-decided state" "$(opt @agent_state)" finished

reset_pane
{ line 1 claude working 100 101 0 "" "" "" n
  line - "" "" "" "" "" "" "" "" ""; } | apply
check "the agent ended on the worker: every mirrored option unset" bash -c "! ls '$OPTS/$P' | grep -q '^@agent_'"
reset_pane
{ line 1 claude working 100 101 0 "" "" "" n
  line 0 claude working 100 101 0 "" "" "" n; } | apply
check "a dead worker pid: no agent" bash -c "! test -f '$OPTS/$P/@agent_kind'"

reset_pane
{ line 1 pi awaiting 100 101 0 1 "" "" n
  printf 'gone\n'; } | apply
eq "worker session gone: disconnected" "$(opt @agent_state)" "$RW_STATE_DISCONNECTED"
eq "disconnected keeps the agent kind" "$(opt @agent_kind)" pi
reset_pane
printf 'gone\n' | apply
check "disconnected is never set on a pane without an agent" bash -c "! test -f '$OPTS/$P/@agent_state'"

reset_pane
printf 'other' >"$OPTS/$P/@rw-endpoint"
line 1 claude working 100 101 0 "" "" "" n | apply
check "a released pane (other @rw-endpoint) is never written" bash -c "! test -f '$OPTS/$P/@agent_kind'"

# --- @rw-request (CX2) ------------------------------------------------------
reset_pane
{ line 1 claude working 100 101 0 "" handback "" n
  line 1 claude working 100 102 0 "" handback "" n
  line 1 claude idle 200 201 0 "" handback "" n; } | apply
eq "handback request: one clear over ssh" "$(grep -c '@rw-request' "$FAKE_SSH_LOG")" 1
check "the clear targets the endpoint session, pane and session scope" \
  grep -q "set-option -pqu -t '=rw-x-$EP:' @rw-request; tmux set-option -qu -t '=rw-x-$EP:' @rw-request" "$FAKE_SSH_LOG"
eq "handback request: one detached hand-back" "$(grep -c '^run-shell -b' "$FAKE_TMUX_LOG")" 1
if [ -x "$RW_PLUGIN/libexec/rw-bg" ]; then
  check "the hand-back is rw bg handback --pane <laptop pane>" grep -q "/rw bg handback --pane %5" "$FAKE_TMUX_LOG"
else
  check "without rw bg: rw handback --pane <laptop pane> --wait-idle 600" \
    grep -q "rw handback --pane %5 --wait-idle 600" "$FAKE_TMUX_LOG"
fi
check "the request still mirrors state" test "$(opt @agent_state)" = idle
reset_pane
{ line 1 claude idle 100 101 0 "" handback "" n
  line 1 claude idle 100 101 0 "" "" "" n
  line 1 claude idle 100 101 0 "" handback "" n; } | apply
eq "a request set again after its clear runs again" "$(grep -c '^run-shell -b' "$FAKE_TMUX_LOG")" 2
reset_pane
touch "$SANDBOX/ssh.fail"
line 1 claude idle 100 101 0 "" handback "" n | apply
rm -f "$SANDBOX/ssh.fail"
eq "a failed clear starts no hand-back" "$(grep -c '^run-shell -b' "$FAKE_TMUX_LOG")" 0
reset_pane
line 1 claude idle 100 101 0 "" bogus "" n | apply
eq "an unknown request is ignored" "$(grep -c '@rw-request' "$FAKE_SSH_LOG")" 0

# --- the side channel process -------------------------------------------------
export FAKE_STREAM="$SANDBOX/stream"
reset_pane
line 1 claude working 100 101 0 "" "" "" n >"$FAKE_STREAM"
sleep 300 &
parent=$!
RW_STATE_PARENT_PID=$parent "$RW_PLUGIN/libexec/remote-state" watch "$EP" "$P" </dev/null >/dev/null 2>&1 &
w=$!
for _ in $(seq 1 40); do [ "$(opt @agent_state)" = "$RW_STATE_DISCONNECTED" ] && break; sleep 0.1; done
eq "stream mirrored, then its end (ssh lost) reads disconnected" "$(opt @agent_state)" "$RW_STATE_DISCONNECTED"
eq "one ssh for the stream" "$(grep -c '^watch' "$FAKE_SSH_LOG")" 1
kill "$parent"
wait "$parent" 2>/dev/null
for _ in $(seq 1 60); do kill -0 "$w" 2>/dev/null || break; sleep 0.1; done
check "the channel stops retrying once its attach loop is gone" bash -c "! kill -0 $w 2>/dev/null"
wait "$w" 2>/dev/null

reset_pane
export FAKE_STREAM_HOLD="$SANDBOX/hold"
touch "$FAKE_STREAM_HOLD"
sleep 300 &
parent=$!
RW_STATE_PARENT_PID=$parent "$RW_PLUGIN/libexec/remote-state" watch "$EP" "$P" </dev/null >/dev/null 2>&1 &
w=$!
for _ in $(seq 1 40); do [ "$(opt @agent_state)" = working ] && break; sleep 0.1; done
eq "a live stream mirrors" "$(opt @agent_state)" working
kill -TERM "$w"
wait "$w" 2>/dev/null
sleep 0.3
check "SIGTERM stops the channel and its ssh" bash -c "! pgrep -f 'remote-state watch $EP' >/dev/null && ! pgrep -f '$SANDBOX/bin/ssh' >/dev/null"
eq "SIGTERM writes nothing (no disconnected over the pane)" "$(opt @agent_state)" working
kill "$parent" 2>/dev/null
wait "$parent" 2>/dev/null

# --- under the attach loop ----------------------------------------------------
# shellcheck source=../scripts/attach-loop.sh
source "$RW_PLUGIN/scripts/attach-loop.sh"
reset_pane
endpoint_id="$EP" pane_id="$P" role=""
state_channel_start
first=$state_channel_pid
for _ in $(seq 1 40); do [ "$(opt @agent_state)" = working ] && break; sleep 0.1; done
eq "attach loop: the channel mirrors" "$(opt @agent_state)" working
state_channel_start
check "a new attach replaces the channel (the old one is gone)" bash -c "! kill -0 $first 2>/dev/null"
on_exit
check "loop exit: channel stopped" bash -c "! pgrep -f 'remote-state watch $EP' >/dev/null"
check "loop exit: mirrored options cleared" bash -c "! ls '$OPTS/$P' | grep -q '^@agent_'"
reset_pane
role=tree
state_channel_start
eq "tree endpoints get no channel" "$state_channel_pid" ""
role=""
reset_pane
line 1 claude working 100 101 0 "" "" "" n | apply
state_channel_lost
rm -f "$FAKE_STREAM_HOLD"
eq "probe unreachable: disconnected at once" "$(opt @agent_state)" "$RW_STATE_DISCONNECTED"

finish
