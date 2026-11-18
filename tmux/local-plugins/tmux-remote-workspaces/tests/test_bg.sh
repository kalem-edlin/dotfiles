#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# `rw bg handoff|handback` (contract CX3) and `rw request handback` (CX2),
# against the pane-aware tmux stub and a same-host fake worker:
#   - synchronous preflight refusals (exit 64 / 1 / 7), one transfer per root
#   - detachment: the caller returns before the transfer ends; the runner is
#     its own process group, out of the caller's tree, survives the caller's
#     process group being killed (a pane respawn), runs rw without TMUX_PANE
#   - wait-idle: nothing runs while an agent in the root is `working`
#   - @rw-transfer / @rw-transfer-label set while in flight, cleared after,
#     the status chip wired, display-message at start and end
#   - exit 5: the conflict dialog's choice re-runs with --resolve (or aborts)
#   - any other failure: a dialog, the lock and the chip released
#   - the real rw handoff / handback end to end through the runner
#   - rw request handback: refused on the focus machine, sets @rw-request
#     on the worker side
# Never a tmux server: a wrapper over lib.sh's stub keeps global options in
# files and logs display-message / display-popup instead of drawing them.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
export FAKE_GLOBALS="$SANDBOX/globals"
export FAKE_UI_LOG="$SANDBOX/ui.log"
mkdir -p "$FAKE_GLOBALS" "$SANDBOX/bin2"
: >"$FAKE_UI_LOG"

cat >"$SANDBOX/bin2/tmux" <<'EOF'
#!/usr/bin/env bash
# Wraps lib.sh's stub: global options (-g) live in $FAKE_GLOBALS/<name>;
# display-message without -p and display-popup are logged to $FAKE_UI_LOG.
# A display-popup running the conflict dialog answers $FAKE_CONFLICT_CHOICE
# the way the dialog would (shown marker, then the choice file).
cmd="${1:-}"
flags="" args=()
for a in "${@:2}"; do
  case "$a" in -*) flags="$flags${a#-}" ;; *) args+=("$a") ;; esac
done
case "$cmd" in
  set-option | set)
    if [[ "$flags" == *g* && "$flags" != *p* && "$flags" != *t* ]]; then
      if [[ "$flags" == *u* ]]; then rm -f "$FAKE_GLOBALS/${args[0]}"; else printf '%s' "${args[1]:-}" >"$FAKE_GLOBALS/${args[0]}"; fi
      exit 0
    fi
    ;;
  show-option | show-options | show)
    if [[ "$flags" == *g* && "$flags" != *p* && "$flags" != *t* ]]; then
      [ -f "$FAKE_GLOBALS/${args[0]:-}" ] && { cat "$FAKE_GLOBALS/${args[0]}"; echo; }
      exit 0
    fi
    ;;
  display-message)
    if [[ "$flags" != *p* ]]; then
      printf 'msg %s\n' "${args[${#args[@]}-1]}" >>"$FAKE_UI_LOG"
      exit 0
    fi
    ;;
  display-popup)
    popup="${args[${#args[@]}-1]}"
    printf 'popup %s\n' "$popup" >>"$FAKE_UI_LOG"
    case "$popup" in
      *rw-bg-dialog\ conflict*)
        eval "set -- $popup"
        [ -n "${FAKE_CONFLICT_CHOICE:-}" ] && { : >"$5.shown"; printf '%s\n' "$FAKE_CONFLICT_CHOICE" >"$5"; }
        ;;
    esac
    exit 0
    ;;
  list-clients) echo "client0"; exit 0 ;;
esac
exec "$(dirname "$0")/../bin/tmux" "$@"
EOF
chmod +x "$SANDBOX/bin2/tmux"
export PATH="$SANDBOX/bin2:$PATH"

# The fake transfer: logs its call, the TMUX_PANE it got and @rw-transfer
# while it ran; behaves as $FAKE_RW_MODE says.
export FAKE_RW_CALLS="$SANDBOX/rw-calls"
cat >"$SANDBOX/fake-rw" <<'EOF'
#!/usr/bin/env bash
printf '%s pane=%s transfer=%s :: %s\n' "$(date +%s)" "${TMUX_PANE:-unset}" \
  "$(cat "$FAKE_GLOBALS/@rw-transfer" 2>/dev/null)" "$*" >>"$FAKE_RW_CALLS"
sleep "${FAKE_RW_SLEEP:-0}"
case "${FAKE_RW_MODE:-ok}" in
  ok) echo "rw: done"; exit 0 ;;
  conflict)
    case "$*" in *--resolve*) echo "rw: done"; exit 0 ;; esac
    printf 'rw: files changed\nconflict\tREADME\tchanged\n'
    exit 5
    ;;
  fail6) echo "rw: remote unreachable"; exit 6 ;;
esac
EOF
chmod +x "$SANDBOX/fake-rw"
export RW_BG_RW_BIN="$SANDBOX/fake-rw"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }
pane() { # <id> <cwd> [@agent_state] [session]
  printf 'pane_id=%s\tpane_current_path=%s\tsession_name=%s\twindow_index=0\tpane_index=0\tpane_current_command=zsh\tpane_pid=999998\t@agent_state=%s\n' \
    "$1" "$2" "${4:-s1}" "${3:-idle}"
}
opt() { tr '\t' '\n' <"$FAKE_TMUX_PANES" | awk -v p="pane_id=$1" '/^pane_id=/ { cur = $0 } cur == p' | sed -n "s/^$2=//p" | head -n1; }
global() { cat "$FAKE_GLOBALS/$1" 2>/dev/null; }
# wait_done <root_id> [seconds] -- until the root's bg job is gone.
wait_done() {
  local i=0
  while [ -d "$(rw_bg_dir)/$1" ] && [ "$i" -lt "${2:-20}" ]; do sleep 0.5; i=$((i + 1)); done
  sleep 0.3
  [ ! -d "$(rw_bg_dir)/$1" ]
}
reset_ui() { : >"$FAKE_UI_LOG"; : >"$FAKE_RW_CALLS"; }

proj="$HOME/Developer/proj"
make_plain "$proj"
id="$(rw_root_id Developer/proj)"
pane %1 "$proj" >"$FAKE_TMUX_PANES"
pane %2 "$HOME" >>"$FAKE_TMUX_PANES"
mkdir -p "$HOME/Developer/loose"
pane %3 "$HOME/Developer" >>"$FAKE_TMUX_PANES"
pane %4 "$proj" idle rw-1234abcd-5678abcd >>"$FAKE_TMUX_PANES"

# --- preflight refusals --------------------------------------------------------
rw bg handoff --worker fakeworker >/dev/null 2>&1
eq "no --pane: exit 64" "$?" "64"
rw bg handoff --worker fakeworker --pane %1 --wait-idle soon >/dev/null 2>&1
eq "--wait-idle not a number: exit 64" "$?" "64"
rw bg handoff --worker fakeworker --pane %77 >/dev/null 2>"$SANDBOX/err"
eq "unknown pane: exit 1" "$?" "1"
rw bg handoff --worker fakeworker --pane %2 >/dev/null 2>&1
eq "pane in ~ itself: exit 7" "$?" "7"
rw bg handoff --worker fakeworker --pane %3 >/dev/null 2>"$SANDBOX/err"
eq "pane in a top-level folder of ~: exit 7" "$?" "7"
rw bg handoff --worker nosuch --pane %1 >/dev/null 2>&1
eq "undeclared worker: exit 64" "$?" "64"
rw bg handback --pane %1 >/dev/null 2>"$SANDBOX/err"
eq "handback of a local root: exit 7" "$?" "7"
rw bg handoff --pane %4 >/dev/null 2>"$SANDBOX/err"
eq "handoff from the worker side of a pane: exit 7" "$?" "7"
check "  and points at rw request handback" grep -q "rw request handback" "$SANDBOX/err"
sleep 300 &
holder=$!
mkdir -p "$(rw_bg_dir)/$id"
echo "$holder" >"$(rw_bg_dir)/$id/pid"
echo '{"verb":"handoff","log":"/x.log"}' >"$(rw_bg_dir)/$id/job.json"
rw bg handoff --pane %1 >/dev/null 2>"$SANDBOX/err"
eq "a transfer of the root already running: exit 1" "$?" "1"
check "  and says so" grep -q "already running" "$SANDBOX/err"
rm -rf "$(rw_bg_dir)/${id:?}"
mkdir -p "$(rw_root_lock_dir "$id")"
echo "$holder" >"$(rw_root_lock_dir "$id")/pid"
rw bg handoff --pane %1 >/dev/null 2>"$SANDBOX/err"
eq "another rw command holding the root lock: exit 1" "$?" "1"
rm -rf "$(rw_root_lock_dir "$id")"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
eq "refusals ran nothing" "$(cat "$FAKE_RW_CALLS" 2>/dev/null)" ""

# --- detachment, indicator, notifications -----------------------------------
reset_ui
export FAKE_RW_SLEEP=3 FAKE_RW_MODE=ok
t0=$(date +%s)
# The caller is its own process group (like a pane's shell); the whole
# group is killed right after rw bg returns, as a pane respawn would.
perl -MPOSIX -e 'setpgid(0, 0); exec @ARGV' bash -c \
  "TMUX_PANE=%1 '$RW_PLUGIN/scripts/rw' bg handoff --pane %1 >'$SANDBOX/out' 2>&1; echo \$? >'$SANDBOX/rc'; sleep 30" &
caller=$!
i=0
while [ ! -s "$SANDBOX/rc" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
t1=$(date +%s)
eq "rw bg handoff: exit 0" "$(cat "$SANDBOX/rc" 2>/dev/null)" "0"
check "  returned before the transfer finished" test $((t1 - t0)) -lt 3
check "  printed one line naming the worker and the log" grep -q "^rw: handing off ~/Developer/proj to fakeworker in the background (log: .*/logs/bg-$id-.*\.log)" "$SANDBOX/out"
runner="$(cat "$(rw_bg_dir)/$id/pid" 2>/dev/null)"
check "  the runner is running" kill -0 "${runner:-0}"
eq "  the runner leads its own process group" "$(ps -o pgid= -p "${runner:-0}" | tr -d ' ')" "$runner"
check "  and is not in the caller's process tree" test "$(ps -o ppid= -p "${runner:-0}" | tr -d ' ')" != "$caller"
{ kill -TERM -- "-$caller"; wait "$caller"; } 2>/dev/null
sleep 0.3
check "  survives its caller's process group being killed" kill -0 "${runner:-0}"
eq "  @rw-transfer while in flight" "$(global @rw-transfer)" "handoff Developer/proj"
eq "  @rw-transfer-label while in flight" "$(global @rw-transfer-label)" "handing off proj…"
check "  the status chip is wired into status-right" grep -q '#{?@rw-transfer-label,' "$FAKE_GLOBALS/status-right"
check "  display-message at the start" grep -q "^msg handing off ~/Developer/proj to fakeworker in the background" "$FAKE_UI_LOG"
check "the transfer finishes" wait_done "$id"
check "  rw handoff ran with the root, the pane and no TMUX_PANE" grep -q "pane=unset transfer=handoff Developer/proj :: handoff --worker fakeworker --root $proj --pane %1\$" "$FAKE_RW_CALLS"
eq "  @rw-transfer cleared" "$(global @rw-transfer)" ""
eq "  @rw-transfer-label cleared" "$(global @rw-transfer-label)" ""
check "  display-message at the end" grep -q "^msg ~/Developer/proj is now on fakeworker" "$FAKE_UI_LOG"
logs=("$TMUX_REMOTE_WORKSPACES_STATE_DIR"/logs/bg-"$id"-*.log)
log="${logs[${#logs[@]}-1]}"
check "  the log holds the rw call and its output" grep -q "rw: done" "$log"
check "  events.jsonl records start and success" bash -c "grep -q '\"event\":\"bg-handoff\".*\"outcome\":\"success\"' '$(rw_events_file)'"

# --- wait-idle -------------------------------------------------------------------
reset_ui
export FAKE_RW_SLEEP=0
"$SANDBOX/bin/tmux" set-option -pq -t %1 @agent_state working
rw bg handoff --pane %1 --wait-idle 30 >/dev/null 2>&1
eq "wait-idle: started" "$?" "0"
sleep 2
eq "  nothing runs while the agent is working" "$(cat "$FAKE_RW_CALLS")" ""
flip=$(date +%s)
"$SANDBOX/bin/tmux" set-option -pq -t %1 @agent_state idle
check "  the transfer finishes once it is idle" wait_done "$id"
check "  and ran after the agent went idle" test "$(cut -d' ' -f1 "$FAKE_RW_CALLS")" -ge "$flip"
reset_ui
"$SANDBOX/bin/tmux" set-option -pq -t %1 @agent_state working
rw bg handoff --pane %1 --wait-idle 2 >/dev/null 2>&1
check "wait-idle runs out: the job ends" wait_done "$id"
eq "  nothing ran" "$(cat "$FAKE_RW_CALLS")" ""
check "  the end is reported" grep -q "^msg rw handoff of ~/Developer/proj failed: an agent in ~/Developer/proj was still working" "$FAKE_UI_LOG"
check "  in a dialog" grep -q "^popup .*dialog.sh --render" "$FAKE_UI_LOG"
eq "  @rw-transfer cleared" "$(global @rw-transfer)" ""
"$SANDBOX/bin/tmux" set-option -pq -t %1 @agent_state idle

# --- conflict: the dialog's choice re-runs with --resolve ---------------------------
reset_ui
export FAKE_RW_MODE=conflict FAKE_CONFLICT_CHOICE=keep-both
rw bg handoff --pane %1 >/dev/null 2>&1
check "conflict: the job ends" wait_done "$id"
check "  the conflict dialog was shown" grep -q "^popup .*rw-bg-dialog conflict handoff" "$FAKE_UI_LOG"
eq "  rw ran twice" "$(wc -l <"$FAKE_RW_CALLS" | tr -d ' ')" "2"
check "  the second run carries --resolve keep-both" bash -c "tail -n1 '$FAKE_RW_CALLS' | grep -q -- '--resolve keep-both\$'"
check "  success reported" grep -q "^msg ~/Developer/proj is now on fakeworker" "$FAKE_UI_LOG"
reset_ui
export FAKE_CONFLICT_CHOICE=abort
rw bg handoff --pane %1 >/dev/null 2>&1
check "conflict aborted: the job ends" wait_done "$id"
eq "  rw ran once" "$(wc -l <"$FAKE_RW_CALLS" | tr -d ' ')" "1"
check "  says nothing moved" grep -q "^msg handoff of ~/Developer/proj aborted; nothing moved" "$FAKE_UI_LOG"

# --- any other failure: dialog with the error lines and the log path ------------------
reset_ui
export FAKE_RW_MODE=fail6
rw bg handoff --pane %1 >/dev/null 2>&1
check "failure: the job ends" wait_done "$id"
check "  first error line in the status row" grep -q "^msg rw handoff of ~/Developer/proj failed: remote unreachable" "$FAKE_UI_LOG"
payload="$(sed -n 's/^popup .*dialog.sh --render //p' "$FAKE_UI_LOG" | tail -n1)"
dialog="$(eval "printf '%s' $payload" | base64 --decode 2>/dev/null || eval "printf '%s' $payload" | base64 -D)"
check "  the dialog names the cause" grep -q "worker unreachable" <<<"$dialog"
check "  shows the error lines" grep -q "rw: remote unreachable" <<<"$dialog"
check "  and the log path" grep -q "log: .*/logs/bg-$id-.*\.log" <<<"$dialog"
check "  the lock is released" test ! -e "$(rw_bg_dir)/$id"
unset FAKE_RW_MODE FAKE_RW_SLEEP FAKE_CONFLICT_CHOICE

# --- the real transfer, end to end -----------------------------------------------------
unset RW_BG_RW_BIN
reset_ui
rw bg handoff --pane %1 >/dev/null 2>"$SANDBOX/err"
eq "real handoff: started (single configured worker)" "$?" "0"
check "real handoff: finishes" wait_done "$id" 40
eq "  the root is remote" "$(jq -r .owner "$(rw_owned_record_file "$id")" 2>/dev/null)" "worker"
check "  the worker copy matches" trees_equal "$proj" "$FAKE_WORKER_HOME/Developer/proj"
check "  the pane went remote" test -n "$(opt %1 @rw-endpoint)"
rw bg handoff --pane %1 >/dev/null 2>"$SANDBOX/err"
eq "  bg handoff of the now-remote root: exit 7" "$?" "7"

# --- rw request handback ----------------------------------------------------------------
env -u TMUX_PANE "$RW_PLUGIN/scripts/rw" request handback >/dev/null 2>&1
eq "request without TMUX_PANE: exit 64" "$?" "64"
TMUX_PANE=%3 rw request handback >/dev/null 2>"$SANDBOX/err"
eq "request on the focus machine, local root: exit 7" "$?" "7"
check "  points at rw bg handoff" grep -q "rw bg handoff" "$SANDBOX/err"
pane %6 "$proj/data" >>"$FAKE_TMUX_PANES"
TMUX_PANE=%6 rw request handback >/dev/null 2>"$SANDBOX/err"
eq "request in the frozen local copy: exit 7" "$?" "7"
check "  says it is the frozen copy" grep -q "frozen local copy" "$SANDBOX/err"
wproj="$FAKE_WORKER_HOME/Developer/proj"
pane %5 "$wproj/scripts" idle rw-1234abcd-5678abcd >>"$FAKE_TMUX_PANES"
worker_side() { HOME="$FAKE_WORKER_HOME" TMUX_REMOTE_WORKSPACES_STATE_DIR="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR" "$@"; }
worker_side env TMUX_PANE=%5 "$RW_PLUGIN/scripts/rw" request handback >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "request on the worker side: exit 0" "$?" "0"
eq "  sets @rw-request on that pane" "$(opt %5 @rw-request)" "handback"
eq "  prints one line" "$(wc -l <"$SANDBOX/out" | tr -d ' ')" "1"
check "  naming the root" grep -q "hand-back of ~/Developer/proj requested" "$SANDBOX/out"
pane %7 "$wproj" idle work >>"$FAKE_TMUX_PANES"
worker_side "$RW_PLUGIN/scripts/rw" bg handoff --pane %7 >/dev/null 2>"$SANDBOX/err"
eq "bg handoff in a worker-held copy (any session): exit 7" "$?" "7"
check "  points at rw request handback" grep -q "rw request handback" "$SANDBOX/err"

# --- the real hand-back, end to end ---------------------------------------------------
reset_ui
rw bg handback --pane %1 >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "real handback: started" "$?" "0"
check "  printed one line" grep -q "^rw: handing ~/Developer/proj back in the background" "$SANDBOX/out"
check "real handback: finishes" wait_done "$id" 40
check "  the root is local again" test ! -e "$(rw_owned_record_file "$id")"
check "  reported" grep -q "^msg ~/Developer/proj is local again" "$FAKE_UI_LOG"
logs=("$TMUX_REMOTE_WORKSPACES_STATE_DIR"/logs/bg-"$id"-*.log)
check "  rw handback got --wait-idle" grep -q "rw handback --root $proj --pane %1 --wait-idle [0-9]" "${logs[${#logs[@]}-1]}"

finish
