#!/usr/bin/env bash
# `rw reclaim [--force] <root>` -- take a remote root back WITHOUT the
# worker (contract C2): the focus machine becomes the owner again from its
# frozen local copy. For a worker that is unreachable and will stay so;
# anything done on the worker since the handoff is not brought back.
#
# Without --force the worker is probed first, and a reachable worker is
# refused (use `rw handback`, which brings that work back). --force skips
# the probe (a worker that answers ssh but is otherwise unusable).
#
# Every local pane bound to the root gets its local shell back (in the same
# pane). The record keeps `stale_worker: true` and a pending reconcile;
# the next contact with that worker closes its endpoints (sessions running a
# handed-off agent are left running and reported) and marks its copy stale,
# but leaves the copy in place for manual inspection.
#
# Usage: rw-reclaim.sh [--force] <root>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq

force="false"
root_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force="true"; shift ;;
    -*) rw_die "rw reclaim: unknown argument: $1" 64 ;;
    *)
      [ -z "$root_arg" ] || rw_die "rw reclaim: only one root may be given" 64
      root_arg="$1"
      shift
      ;;
  esac
done
[ -n "$root_arg" ] || rw_die "usage: rw reclaim [--force] <root>" 64

root_rel="$(rw_root_rel "$root_arg")" || rw_die "rw reclaim: '$root_arg' is not inside your home directory." 7
root_id="$(rw_root_id "$root_rel")"
record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
[ -n "$record" ] && [ "$(printf '%s' "$record" | jq -r '.owner')" = "worker" ] ||
  rw_die "rw reclaim: '$root_rel' is not remote; nothing to reclaim." 7

rw_root_lock_or_die "$root_id" "rw reclaim"
trap 'rw_root_unlock_all' EXIT

worker="$(printf '%s' "$record" | jq -r '.worker')"
root_local="$(printf '%s' "$record" | jq -r '.root_local')"

if [ "$force" != "true" ]; then
  pstatus=0
  pjson="$("$SCRIPT_DIR/preflight.sh" --worker "$worker" 2>/dev/null)" || pstatus=$?
  if [ "$pstatus" -eq 0 ] || [ "$(rw_preflight_exit "$pjson")" != "6" ]; then
    rw_die "rw reclaim: '$worker' is reachable, so reclaiming would abandon the work done there. Use 'rw handback --root $root_local' instead (or 'rw reclaim --force' if '$worker' is reachable but unusable)." 1
  fi
fi
# shellcheck disable=SC2207 # endpoint ids are fixed-format hex
endpoints=($(printf '%s' "$record" | jq -r '.endpoints[]?'))

released=0
# Only the panes of the record's own endpoints: a visit pane of this root on
# another remote is not the owner's and stays where it is (fix wave A).
bound="$(rw_root_bound_panes "$root_id" ${endpoints[@]+"${endpoints[@]}"})"
agents=""
while IFS="$RW_TAB" read -r pid ep; do
  [ -n "$pid" ] || continue
  dir="$(rw_read_endpoint "$ep" 2>/dev/null | jq -r '.workspace.focus_path // empty')"
  [ -d "$dir" ] || dir="$root_local"
  if rw_release_pane "$pid" "$dir"; then
    released=$((released + 1))
  else
    rw_warn "rw reclaim: could not give pane $pid its local shell back."
  fi
  a="$(rw_read_endpoint "$ep" 2>/dev/null | jq -r 'select(.agent.state == "handed-off") | "\(.agent.provider) \(.agent.session_id)"')"
  [ -n "$a" ] && agents="$agents
  pane $pid: $a"
done <<<"$bound"

now="$(rw_now_iso)"
rw_owned_record_write "$root_id" "$(printf '%s' "$record" | jq -c --arg now "$now" '
  .owner = "focus" | .since = $now | .stale_worker = true
  | .pending = {action: "reconcile", reason: "reclaimed while the remote was unreachable", at: $now}')"
# The root's owner changed (CS3). Best effort.
rw_refresh_indicators --root "$root_local"
rw_log_event "reclaim" "" "$worker" "" "success" "root=$root_rel panes=$released"

printf 'rw: %s is local again from its frozen copy (%d pane(s) released). Remote work since the handoff stays on the remote copy, which is now stale.\n' "$root_rel" "$released"
if [ -n "$agents" ]; then
  printf 'rw: agents that were running remotely (resume them by hand if needed; the local transcripts stop at the handoff):%s\n' "$agents"
fi
exit 0
