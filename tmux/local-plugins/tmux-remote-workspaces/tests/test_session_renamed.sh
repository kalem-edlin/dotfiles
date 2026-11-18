#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016,SC2329 # literal tmux targets; tmux() stubs are called by sourced code
# rw-session-renamed.sh: a renamed session's endpoints keep their restore
# keys (focus_session_name, indices) and sessions.jsonl follows the rename.
# tmux-free: tmux is a shell function scripted per case.

set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/rw-session-renamed.sh
source "$RW_PLUGIN/scripts/rw-session-renamed.sh"

TMUX_CALLS="$SANDBOX/tmux-calls"
: >"$TMUX_CALLS"
CURRENT_NAME="feat renamed"
SESSION_ALIVE=1
tmux() {
  printf '%s\n' "$*" >>"$TMUX_CALLS"
  case "$1" in
    display-message) [ "$SESSION_ALIVE" = 1 ] && printf '%s\n' "$CURRENT_NAME" ;;
    has-session) [ "$SESSION_ALIVE" = 1 ] || return 1 ;;
    show-option) echo session-uuid-1 ;;
    # Pane of the renamed session bound to endpoint aaaa, moved to 4.2.
    list-panes) printf '%s\n' '- 1 0' 'aaaa 4 2' ;;
  esac
  return 0
}

mkdir -p "$(rw_endpoints_dir)"
jq -nc '{endpoint_id: "aaaa", root_id: "111", focus_session_uuid: "session-uuid-1", focus_session_name: "old",
  focus_window_index: 1, focus_pane_index: 0, updated_at: "x"}' >"$(rw_endpoint_file aaaa)"
jq -nc '{endpoint_id: "bbbb", root_id: "111", focus_session_uuid: "session-uuid-1", focus_session_name: "old",
  focus_window_index: 2, focus_pane_index: 0, updated_at: "x"}' >"$(rw_endpoint_file bbbb)"
jq -nc '{endpoint_id: "cccc", root_id: "222", focus_session_uuid: "other-uuid", focus_session_name: "other",
  focus_window_index: 1, focus_pane_index: 0, updated_at: "x"}' >"$(rw_endpoint_file cccc)"
cccc_before="$(cat "$(rw_endpoint_file cccc)")"

# Review item 3: two quick renames run as two background hooks that may
# finish out of order. The late hook for the FIRST rename must still record
# the session's current name, which it reads back from tmux.
rw_session_renamed_main '$4' 'stale first-rename name'

eq "bound endpoint: current name and current indices" \
  "$(jq -c '[.focus_session_name, .focus_window_index, .focus_pane_index]' "$(rw_endpoint_file aaaa)")" \
  '["feat renamed",4,2]'
eq "unbound endpoint of the same session uuid: new name, indices kept" \
  "$(jq -c '[.focus_session_name, .focus_window_index, .focus_pane_index]' "$(rw_endpoint_file bbbb)")" \
  '["feat renamed",2,0]'
eq "other session's endpoint untouched" "$(cat "$(rw_endpoint_file cccc)")" "$cccc_before"
eq "sessions.jsonl maps the uuid to the current name" \
  "$(rw_session_name_for_uuid session-uuid-1)" "feat renamed"
check "root locks are released" bash -c '! compgen -G "$1/locks/root-*" >/dev/null' _ "$(rw_state_dir)"

# A second identical fire changes nothing and adds no registry line.
lines_before="$(wc -l <"$(rw_sessions_file)")"
aaaa_before="$(cat "$(rw_endpoint_file aaaa)")"
rw_session_renamed_main '$4'
eq "repeat fire adds no sessions.jsonl line" "$(wc -l <"$(rw_sessions_file)")" "$lines_before"
eq "repeat fire leaves the endpoint as is" "$(cat "$(rw_endpoint_file aaaa)")" "$aaaa_before"

# A session killed before the hook ran: nothing is recorded.
SESSION_ALIVE=0
rw_session_renamed_main '$4' 'gone'
eq "gone session: endpoint untouched" "$(cat "$(rw_endpoint_file aaaa)")" "$aaaa_before"
SESSION_ALIVE=1

# Compare-and-swap: a file rewritten or removed by another writer between
# read and write is left alone and never recreated.
f="$(rw_endpoint_file cccc)"
expected="$(jq -c . "$f")"
jq -c '.generation = 2' "$f" >"$f.new" && mv "$f.new" "$f"
if rw_endpoint_replace_if_unchanged "$f" "$expected" '{"clobbered":true}'; then
  bad "changed file is not overwritten"
else
  ok "changed file is not overwritten"
fi
eq "changed file keeps the other writer's content" "$(jq -r .generation "$f")" 2
check "unchanged file is replaced" rw_endpoint_replace_if_unchanged "$f" "$(jq -c . "$f")" '{"endpoint_id":"cccc","replaced":true}'
eq "replacement landed" "$(jq -r .replaced "$f")" true
expected="$(jq -c . "$f")"
rm -f "$f"
if rw_endpoint_replace_if_unchanged "$f" "$expected" '{}' || [ -e "$f" ]; then
  bad "vanished file is not recreated"
else
  ok "vanished file is not recreated"
fi

# The per-root lock held by another live writer: wait a little, never steal
# it, then still apply the compare-guarded update.
if declare -F rw_root_lock >/dev/null; then
  sleep 30 &
  holder=$!
  lockdir="$(rw_root_lock_dir 111)"
  mkdir -p "$lockdir" && printf '%s\n' "$holder" >"$lockdir/pid"
  CURRENT_NAME="feat again"
  RW_SESSION_RENAMED_LOCK_TRIES=2 rw_session_renamed_main '$4'
  eq "lock held elsewhere: update still applied" \
    "$(jq -r .focus_session_name "$(rw_endpoint_file aaaa)")" "feat again"
  eq "lock held elsewhere: not stolen" "$(cat "$lockdir/pid")" "$holder"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  rm -rf "$lockdir"
else
  ok "per-root lock API absent in common.sh; compare-only path covered above"
fi

# An endpoint closed meanwhile is never recreated: no endpoint files, no work.
rm -f "$(rw_endpoints_dir)"/*.json
rw_session_renamed_main '$4'
check "no endpoint file is created" bash -c '! compgen -G "$1/*.json" >/dev/null' _ "$(rw_endpoints_dir)"
unset -f tmux

finish
