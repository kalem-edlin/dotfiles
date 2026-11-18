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
tmux() {
  printf '%s\n' "$*" >>"$TMUX_CALLS"
  case "$1" in
    show-option) echo session-uuid-1 ;;
    # Pane of the renamed session bound to endpoint aaaa, moved to 4.2.
    list-panes) printf '%s\n' '- 1 0' 'aaaa 4 2' ;;
  esac
  return 0
}

mkdir -p "$(rw_endpoints_dir)"
jq -nc '{endpoint_id: "aaaa", focus_session_uuid: "session-uuid-1", focus_session_name: "old",
  focus_window_index: 1, focus_pane_index: 0, updated_at: "x"}' >"$(rw_endpoint_file aaaa)"
jq -nc '{endpoint_id: "bbbb", focus_session_uuid: "session-uuid-1", focus_session_name: "old",
  focus_window_index: 2, focus_pane_index: 0, updated_at: "x"}' >"$(rw_endpoint_file bbbb)"
jq -nc '{endpoint_id: "cccc", focus_session_uuid: "other-uuid", focus_session_name: "other",
  focus_window_index: 1, focus_pane_index: 0, updated_at: "x"}' >"$(rw_endpoint_file cccc)"
cccc_before="$(cat "$(rw_endpoint_file cccc)")"

rw_session_renamed_main '$4' 'feat renamed'

eq "bound endpoint: new name and current indices" \
  "$(jq -c '[.focus_session_name, .focus_window_index, .focus_pane_index]' "$(rw_endpoint_file aaaa)")" \
  '["feat renamed",4,2]'
eq "unbound endpoint of the same session uuid: new name, indices kept" \
  "$(jq -c '[.focus_session_name, .focus_window_index, .focus_pane_index]' "$(rw_endpoint_file bbbb)")" \
  '["feat renamed",2,0]'
eq "other session's endpoint untouched" "$(cat "$(rw_endpoint_file cccc)")" "$cccc_before"
eq "sessions.jsonl maps the uuid to the new name" \
  "$(rw_session_name_for_uuid session-uuid-1)" "feat renamed"

# A second identical fire changes nothing and adds no registry line.
lines_before="$(wc -l <"$(rw_sessions_file)")"
aaaa_before="$(cat "$(rw_endpoint_file aaaa)")"
rw_session_renamed_main '$4' 'feat renamed'
eq "repeat fire adds no sessions.jsonl line" "$(wc -l <"$(rw_sessions_file)")" "$lines_before"
eq "repeat fire leaves the endpoint as is" "$(cat "$(rw_endpoint_file aaaa)")" "$aaaa_before"

# An endpoint closed meanwhile is never recreated: no endpoint files, no work.
rm -f "$(rw_endpoints_dir)"/*.json
rw_session_renamed_main '$4' 'again'
check "no endpoint file is created" bash -c '! compgen -G "$1/*.json" >/dev/null' _ "$(rw_endpoints_dir)"
unset -f tmux

finish
