#!/usr/bin/env bash
# `rw forget <root>` -- the root is gone (worktree removed, session deleted):
# close its endpoints and delete every worker copy and mirror record of it,
# then drop the focus record (contract C2, decision D11).
#
# Workers: --worker, else the record's worker plus every worker this focus
# machine handed the root to (held/ index). A worker copy is deleted only
# when that worker's mirror record names the same root AND records that rw
# created the directory at the first handoff; a directory that existed
# before is left in place (only rw's mirror is removed). The copy is
# deleted before the root's endpoints are closed, so a failed delete leaves
# everything as it was.
#
# An unreachable worker gets a pending forget (record `pending.action =
# forget`) that runs on the next contact with it; the exit code is then 6.
#
# Forgetting a root that is currently remote discards the worker copy,
# which is its only up-to-date copy: that needs --force (the picker and
# `wt rm` pass it after asking the user).
#
# Usage: rw-forget.sh <root> [--worker <alias>] [--force]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

root_arg=""
only_worker=""
force="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --worker) only_worker="${2:?}"; shift 2 ;;
    --force) force="true"; shift ;;
    -*) rw_die "rw forget: unknown argument: $1" 64 ;;
    *)
      [ -z "$root_arg" ] || rw_die "rw forget: only one root may be given" 64
      root_arg="$1"
      shift
      ;;
  esac
done
[ -n "$root_arg" ] || rw_die "usage: rw forget <root> [--worker <alias>] [--force]" 64
[ -z "$only_worker" ] || rw_worker_known "$only_worker" || rw_die "rw forget: worker '$only_worker' is not declared in config.json" 64

# The root may already be deleted locally; rw_root_rel then works on the
# path as given.
root_rel="$(rw_root_rel "$root_arg")" || rw_die "rw forget: '$root_arg' is not inside your home directory." 7
root_id="$(rw_root_id "$root_rel")"
rw_root_lock_or_die "$root_id" "rw forget"
trap 'rw_root_unlock_all' EXIT
record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
rec_worker=""
[ -n "$record" ] && rec_worker="$(printf '%s' "$record" | jq -r '.worker')"

workers=()
if [ -n "$only_worker" ]; then
  workers=("$only_worker")
else
  while IFS= read -r w; do
    [ -n "$w" ] && workers+=("$w")
  done < <({ [ -n "$rec_worker" ] && printf '%s\n' "$rec_worker"; rw_held_workers "$root_id"; } | awk '!seen[$0]++')
fi

if [ "${#workers[@]}" -eq 0 ]; then
  printf 'rw: %s has no remote copies; nothing to forget.\n' "$root_rel"
  exit 0
fi

if [ -n "$record" ] && [ "$(printf '%s' "$record" | jq -r '.owner')" = "worker" ]; then
  if [ "$force" != "true" ] && { [ -z "$only_worker" ] || [ "$only_worker" = "$rec_worker" ]; }; then
    rw_die "rw forget: '$root_rel' is remote on '$rec_worker' and that copy is its only up-to-date one. Hand it back first ('rw handback --root $root_arg'), or pass --force to discard it." 7
  fi
  rw_warn "rw forget: '$root_rel' is remote on '$rec_worker'; its remote copy is being discarded without a hand-back (--force)."
fi

start_ts="$(rw_now_epoch)"
unreachable=0
failures=0
for w in "${workers[@]}"; do
  rw_worker_known "$w" || { rw_warn "rw forget: '$w' is no longer in config.json; skipped."; continue; }
  status=0
  pjson="$("$SCRIPT_DIR/preflight.sh" --worker "$w" 2>/dev/null)" || status=$?
  home="$(printf '%s' "$pjson" | jq -r '.home // empty' 2>/dev/null)"
  if [ "$status" -ne 0 ] && [ -z "$home" ]; then
    unreachable=$((unreachable + 1))
    now="$(rw_now_iso)"
    pending="$(jq -nc --arg now "$now" '{action: "forget", reason: "remote was unreachable", at: $now}')"
    if [ -n "$record" ] && [ "$rec_worker" = "$w" ]; then
      rw_owned_record_write "$root_id" "$(rw_owned_record_read "$root_id" | jq -c --argjson p "$pending" '.pending = $p')"
    elif [ -z "$(rw_owned_record_read "$root_id" 2>/dev/null)" ]; then
      worker_root="$(jq -r '.worker_root // empty' "$(rw_held_file "$w" "$root_id")" 2>/dev/null)"
      rw_owned_record_write "$root_id" "$(rw_record_new "$root_id" "$root_rel" "$(rw_physical_path "$root_arg")" \
        "plain" "$w" "$worker_root" | jq -c --argjson p "$pending" '.pending = $p')"
    fi
    held="$(rw_held_file "$w" "$root_id")"
    if [ -f "$held" ]; then
      rw_write_json_atomic "$held" "$(jq -c --argjson p "$pending" '.pending = $p' "$held")"
    else
      rw_write_json_atomic "$held" "$(jq -nc --arg w "$w" --arg id "$root_id" --arg rel "$root_rel" --argjson p "$pending" \
        '{worker: $w, root_id: $id, root_rel: $rel, worker_root: "", pending: $p}')"
    fi
    rw_warn "rw forget: '$w' is unreachable; its copy of '$root_rel' will be deleted on the next contact."
    rw_log_event "forget" "" "$w" "$(rw_elapsed_ms "$start_ts")" "pending" "root=$root_rel"
    continue
  fi

  # Delete first: if that fails nothing else changes.
  result="$(rw_forget_worker_copy "$w" "$home" "$root_id" "$root_rel")" || {
    unreachable=$((unreachable + 1))
    rw_warn "rw forget: lost contact with '$w' while deleting its copy of '$root_rel'; nothing changed, retry later."
    continue
  }
  if [ "$result" = "failed" ]; then
    failures=$((failures + 1))
    rw_warn "rw forget: could not delete the copy of '$root_rel' on '$w'; its panes stay open. Inspect it there and retry."
    continue
  fi
  if [ -n "$record" ] && [ "$rec_worker" = "$w" ]; then
    # shellcheck disable=SC2207 # endpoint ids are fixed-format hex
    eps=($(rw_owned_record_read "$root_id" 2>/dev/null | jq -r '.endpoints[]?'))
    rw_close_root_endpoints "$root_id" "forget" ${eps[@]+"${eps[@]}"}
    rw_owned_record_remove "$root_id"
  fi
  rw_held_unmark "$w" "$root_id"
  rw_forget_local_backups "$root_id"
  case "$result" in
    deleted) printf 'rw: deleted the copy of %s on %s.\n' "$root_rel" "$w" ;;
    kept) printf 'rw: left the copy of %s on %s in place: that directory existed before rw handed the root off.\n' "$root_rel" "$w" ;;
    *) printf 'rw: %s holds no copy of %s that this machine handed off; left untouched.\n' "$w" "$root_rel" ;;
  esac
  rw_log_event "forget" "" "$w" "$(rw_elapsed_ms "$start_ts")" "success" "root=$root_rel worker_copy=$result"
  # Other pending work for this worker, now that it answered.
  rw_reconcile_pending "$w" "$home"
done

[ "$failures" -eq 0 ] || exit 1
[ "$unreachable" -eq 0 ] || exit 6
exit 0
