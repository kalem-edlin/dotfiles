#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016,SC2329 # literal tmux targets; tmux() stubs are called by sourced code
# rw-post-restore.sh endpoint matching (D14, C6), tmux-free: the pure
# rw_restore_match function over a list-panes dump, a sidecar and
# sessions.jsonl. No tmux server, no ssh (lib.sh stubs both).

set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/rw-post-restore.sh
source "$RW_PLUGIN/scripts/rw-post-restore.sh"

W="$SANDBOX/match"
mkdir -p "$W"

# match <endpoints-json> <dump> [sidecar-json] [sessions-jsonl] -- prints
# "id outcome pane via" per endpoint (reason for misses).
match() {
  printf '%s' "$1" >"$W/endpoints.json"
  printf '%s\n' "$2" >"$W/panes.dump"
  printf '%s' "${3:-}" >"$W/sidecar.json"
  printf '%s' "${4:-}" >"$W/sessions.jsonl"
  rw_restore_match "$W/endpoints.json" "$W/panes.dump" "$W/sidecar.json" "$W/sessions.jsonl" |
    jq -r '"\(.endpoint_id) \(.outcome) \(if .outcome == "missing" then .reason else "\(.pane_id) \(.via)" end)"'
}

ep() { # ep <id> <session> <window> <pane> [uuid]
  jq -nc --arg id "$1" --arg s "$2" --argjson w "$3" --argjson p "$4" --arg u "${5:-}" \
    '{endpoint_id: $id, worker: "fakeworker", focus_session_uuid: $u,
      focus_window_index: $w, focus_pane_index: $p}
     + (if $s == "" then {} else {focus_session_name: $s} end)'
}

side() { # side <logical_id> <endpoint>... -> sidecar JSON
  local panes="[]"
  while [ $# -gt 1 ]; do
    panes="$(jq -c --arg l "$1" --arg e "$2" '. + [{logical_id: $l, rw_endpoint: $e}]' <<<"$panes")"
    shift 2
  done
  jq -nc --argjson p "$panes" '{version: 1, panes: $p}'
}

# Dump lines: pane_id session_id window pane endpoint loop kids session:cmd
# (loop L = started as an attach loop; kids K = the shell has children).
dump=$'%1 $1 1 0 - - - harness:zsh\n%2 $1 1 1 - - - harness:zsh\n%3 $2 2 0 - - - sched r1:zsh\n%4 $2 2 1 - - - sched r1:nvim\n%5 $2 3 0 - - - sched r1:-zsh'

# 1. Record position, session names with spaces.
eq "record position matches a fresh shell" \
  "$(match "[$(ep aaaa 'sched r1' 2 0)]" "$dump")" \
  "aaaa reattach %3 record"

# 2. A busy pane is never taken; a missing position is reported.
eq "busy pane and absent position are left alone" \
  "$(match "[$(ep aaaa 'sched r1' 2 1),$(ep bbbb gone 1 0)]" "$dump")" \
  "aaaa missing pane %4 at sched r1:2.1 is busy (nvim)
bbbb missing no pane at gone:1.0"

# 3. Sidecar wins when it places the endpoint elsewhere (pane moved after
#    the handoff; the record's indices are stale).
eq "sidecar position overrides a stale record position" \
  "$(match "[$(ep aaaa 'sched r1' 2 0)]" "$dump" "$(side 'sched r1:3.0' aaaa)")" \
  "aaaa reattach %5 sidecar"

# 4. A record position the sidecar gives to another endpoint is not used.
eq "record position owned by another endpoint in the sidecar" \
  "$(match "[$(ep aaaa harness 1 0)]" "$dump" "$(side 'harness:1.0' zzzz)")" \
  "aaaa missing position harness:1.0 belongs to endpoint zzzz"

# 4b. Review probe C: the sidecar records the record position as a LOCAL
#     pane. Saved after the endpoint existed -> the record is stale: missing
#     (taking the pane would also suppress its own replay). Saved before the
#     endpoint existed (handoff after the last save) -> the pane at that
#     position is the pre-handoff pane: reattach. Unknown times -> missing.
local_side='{"version":1,"saved_at":"2026-11-18T10:00:00Z","panes":[{"logical_id":"harness:1.0","rw_endpoint":""},{"logical_id":"harness:1.1","rw_endpoint":"","selected_command":"claudef --resume X"}]}'
eq "record position the sidecar saved as local, after the handoff" \
  "$(match "[$(ep aaaa harness 1 1 | jq -c '.created_at = "2026-11-18T09:00:00Z"')]" "$dump" "$local_side")" \
  "aaaa missing sidecar records harness:1.1 as a local pane"
eq "record position the sidecar saved as local, before the handoff" \
  "$(match "[$(ep aaaa harness 1 1 | jq -c '.created_at = "2026-11-18T11:00:00Z"')]" "$dump" "$local_side")" \
  "aaaa reattach %2 record"
eq "record position saved as local, no endpoint creation time" \
  "$(match "[$(ep aaaa harness 1 1)]" "$dump" "$local_side")" \
  "aaaa missing sidecar records harness:1.1 as a local pane"

# 5. Older records: no focus_session_name -> sessions.jsonl via uuid (latest
#    line wins); no position at all -> sidecar; neither -> no-position.
sessions=$'{"uuid":"u1","session_name":"old-name"}\n{"uuid":"u1","session_name":"harness"}'
eq "legacy record resolves its session through sessions.jsonl" \
  "$(match "[$(ep aaaa '' 1 1 u1)]" "$dump" "" "$sessions")" \
  "aaaa reattach %2 record"
eq "record without a position falls back to the sidecar" \
  "$(match '[{"endpoint_id":"aaaa","worker":"w"},{"endpoint_id":"bbbb","worker":"w"}]' "$dump" "$(side 'harness:1.0' aaaa)")" \
  "aaaa reattach %1 sidecar
bbbb missing no-position"

# 6. Two endpoints never claim one pane; ids are processed in order.
eq "a pane is claimed once" \
  "$(match "[$(ep bbbb harness 1 0),$(ep aaaa harness 1 0)]" "$dump")" \
  "aaaa reattach %1 record
bbbb missing pane %1 at harness:1.0 already claimed"

# 7. Restore over a live server (review probes A, B): a pane that already
#    carries this endpoint is attached and left alone whatever it runs -- on
#    macOS a live loop's pane_current_command is "bash" -- and wins over a
#    sidecar that places the endpoint elsewhere. A pane stamped for another
#    endpoint is never taken.
live=$'%1 $1 1 0 aaaa L - harness:bash\n%2 $1 1 1 cccc L - harness:zsh'
eq "probe A: live loop showing bash is attached, not respawned" \
  "$(match "[$(ep aaaa harness 1 0),$(ep bbbb harness 1 1)]" "$live")" \
  "aaaa attached %1 live
bbbb missing pane %2 at harness:1.1 carries endpoint cccc"
live=$'%1 $1 1 0 - - - s:zsh\n%2 $1 1 1 aaaa L - s:bash'
eq "probe B: live loop wins over an older sidecar position" \
  "$(match "[$(ep aaaa s 1 1)]" "$live" "$(side 's:1.0' aaaa)")" \
  "aaaa attached %2 live"
live=$'%1 $1 1 0 aaaa - K harness:ssh'
eq "live loop in an rw open pane (no loop start command) is attached" \
  "$(match "[$(ep aaaa harness 1 0)]" "$live")" \
  "aaaa attached %1 live"

# 7b. Review probe D: a shell with children (foreground `bash deploy.sh`,
#     suspended or background jobs) is busy; so is any pane started as an
#     attach loop that carries no endpoint.
busy=$'%1 $1 1 0 - - K s:bash\n%2 $1 1 1 - - K s:zsh\n%3 $1 1 2 - L - s:bash'
eq "probe D: shells with children and orphan loops are busy" \
  "$(match "[$(ep aaaa s 1 0),$(ep bbbb s 1 1),$(ep cccc s 1 2)]" "$busy")" \
  "aaaa missing pane %1 at s:1.0 is busy (bash, has child processes)
bbbb missing pane %2 at s:1.1 is busy (zsh, has child processes)
cccc missing pane %3 at s:1.2 runs another attach loop"
eq "a shell with children is flagged for a settle re-check" \
  "$(printf '%s' "[$(ep aaaa s 1 1)]" >"$W/e.json"; printf '%s\n' "$busy" >"$W/d"
     rw_restore_match "$W/e.json" "$W/d" | jq -r '.retry')" "true"

# 8. Malformed inputs: empty dump, junk sidecar, junk lines, old format.
eq "empty dump reports every endpoint missing" \
  "$(match "[$(ep aaaa harness 1 0)]" "")" \
  "aaaa missing no pane at harness:1.0"
eq "junk sidecar and junk dump lines are ignored" \
  "$(match "[$(ep aaaa harness 1 0)]" $'garbage line\n%1 $1 1 0 - harness:zsh\n%1 $1 1 0 - - - harness:zsh' 'not json')" \
  "aaaa reattach %1 record"

# 9. The dump builder: pane pid -> K/- from the parent-pid set, session names
#    with spaces and commands kept intact; the format keeps the session name
#    between the seventh space and a colon.
eq "rw_restore_mark_children" \
  "$(printf '%s\n' '%1 $1 0 0 - - 4242 my  sess:zsh' '%2 $1 0 1 ab12 L 77 x:-zsh' |
     rw_restore_mark_children '1 4242 99')" \
  '%1 $1 0 0 - - K my  sess:zsh
%2 $1 0 1 ab12 L - x:-zsh'
check "dump format ends with pane pid, session name, colon, command" \
  grep -q ' #{pane_pid} #{session_name}:#{pane_current_command}$' <<<"$RW_RESTORE_PANES_FORMAT"

# 10. rw_post_restore_main end to end against a scripted tmux: respawns the
#     matched pane into the attach loop, stamps the pane options, logs
#     restore-reattach / restore-reattach-missing, leaves every endpoint
#     registered, skips tombstoned ones, and never kills anything.
TMUX_CALLS="$W/tmux-calls"
: >"$TMUX_CALLS"
tmux() {
  printf '%s\n' "$*" >>"$TMUX_CALLS"
  case "$1" in
    list-panes) printf '%s\n' '%7 $3 1 0 - - 4242 wt-feature:zsh' '%8 $3 1 1 - - 4343 wt-feature:zsh' ;;
    show-option) [ "${*: -1}" = "@session-uuid" ] && echo fresh-uuid ;;
  esac
  return 0
}
# Pane %7's shell (pid 4242) has a child: a job the user left running.
ps() { printf '%s\n' 1 4242; }
export RW_POST_RESTORE_SETTLE_TRIES=2
mkdir -p "$(rw_endpoints_dir)" "$(rw_tombstones_dir)"
mkdir -p "$HOME/Developer/proj/feature"
jq -nc '{endpoint_id: "e1e1e1e1", worker: "fakeworker", root_id: "123", root_rel: "Developer/proj/feature",
  focus_session_uuid: "stable-uuid", focus_session_name: "wt-feature", focus_window_index: 1,
  focus_pane_index: 1, workspace: {focus_path: ($h + "/Developer/proj/feature"),
  remote_path: "/Users/worker/Developer/proj/feature"}}' --arg h "$HOME" >"$(rw_endpoint_file e1e1e1e1)"
jq -nc '{endpoint_id: "e2e2e2e2", worker: "fakeworker", focus_session_name: "closed-session",
  focus_window_index: 0, focus_pane_index: 0}' >"$(rw_endpoint_file e2e2e2e2)"
jq -nc '{endpoint_id: "e3e3e3e3", worker: "fakeworker", focus_session_name: "wt-feature",
  focus_window_index: 1, focus_pane_index: 0}' >"$(rw_endpoint_file e3e3e3e3)"
printf '{}' >"$(rw_tombstone_file e3e3e3e3)"
jq -nc '{endpoint_id: "e4e4e4e4", worker: "fakeworker", focus_session_name: "wt-feature",
  focus_window_index: 1, focus_pane_index: 0}' >"$(rw_endpoint_file e4e4e4e4)"
(rw_post_restore_main)
check "matched pane is respawned into the attach loop at the focus path" \
  grep -q "^respawn-pane -k -t %8 -c $HOME/Developer/proj/feature .*attach-loop\.sh e1e1e1e1\$" "$TMUX_CALLS"
check "pane options are stamped" \
  bash -c 'for o in "@rw-endpoint e1e1e1e1" "@rw-worker fakeworker" "@rw-workspace /Users/worker/Developer/proj/feature" "@rw-root-id 123" "@rw-session-uuid stable-uuid" "@remote-host fakeworker" "@workspace-resurrect-skip 1"; do grep -qx "set-option -pqt %8 $o" "$1" || exit 1; done' _ "$TMUX_CALLS"
check "the session gets its stable uuid back" grep -qx 'set-option -t $3 -q @session-uuid stable-uuid' "$TMUX_CALLS"
check "tombstoned endpoint is not reattached" bash -c '! grep -q e3e3e3e3 "$1"' _ "$TMUX_CALLS"
eq "a busy pane is re-listed once before giving up" "$(grep -c '^list-panes' "$TMUX_CALLS")" 2
check "nothing is killed" bash -c '! grep -Eq "^kill-|^respawn-pane .*%7" "$1"' _ "$TMUX_CALLS"
eq "events: one reattach, one missing" \
  "$(jq -r '"\(.event) \(.endpoint) \(.outcome)"' "$(rw_events_file)" | sort | tr '\n' ';')" \
  "restore-reattach e1e1e1e1 success;restore-reattach-missing e2e2e2e2 skipped;restore-reattach-missing e4e4e4e4 skipped;"
check "every endpoint stays registered" \
  bash -c 'for e in e1e1e1e1 e2e2e2e2 e3e3e3e3; do [ -f "$1/$e.json" ] || exit 1; done' _ "$(rw_endpoints_dir)"
unset -f tmux ps
unset RW_POST_RESTORE_SETTLE_TRIES

finish
