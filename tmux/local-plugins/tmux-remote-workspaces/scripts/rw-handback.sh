#!/usr/bin/env bash
# `rw handback` -- bring a remote root, and every pane working in it, back
# to this machine (docs/tasks/mini-remote-sessions.md, P1 and contract C2).
# Replaces `rw return`.
#
# Order:
#   1. Find the root's ownership record (--root, the pane's @rw-root-id or
#      @rw-endpoint, or the cwd's enclosing remote root). Exit 7 when the
#      root is not remote. Preflight the worker: unreachable is exit 6 and
#      nothing changes (see `rw reclaim --force` for that case).
#   2. Agent version policy, inverted (the LOCAL CLI resumes now): a local
#      CLI older than the remote one aborts with exit 3 before anything
#      moves.
#   3. ONE pull of the root: git channel + rsync channel with delete. The
#      frozen local copy is first checked against the manifest written when
#      it was handed off -- an edit made to it exits 5 unless --resolve.
#   4. Per pane: replace the attach loop with a local shell (same pane id,
#      layout, window), then export/install/resume the pane's agent locally.
#      The remote agent is stopped only after the local one verifiably
#      started.
#   5. Only after every pane is back: close the worker sessions, record the
#      focus machine as owner (the record is deleted when nothing is
#      pending), and rewrite the worker's mirror with fresh manifests.
#
# Must run on the focus machine from a local pane or popup, never from the
# worker side of a remote pane (that shell is on the worker).
#
# Usage: rw-handback.sh [--root <path>] [--pane <pane-id>] [--check-lfs]
#                       [--force-diverged] [--resolve overwrite|keep-both|abort]
#
# Exit: 0 ok, 1 failure or agents left running remotely, 2 git divergence,
#       3 agent CLI version gate, 5 manifest conflict, 6 worker unreachable,
#       7 not a remote root, 64 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/../libexec/sync"
ADAPTERS_DIR="$SCRIPT_DIR/../libexec/adapters"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

# Worker-side guard: an rw endpoint session is named rw-<8hex>-<8hex>; a
# shell inside one is on the worker, where no ownership record exists.
if [ -n "${TMUX:-}" ]; then
  case "$(tmux display-message -p '#{session_name}' 2>/dev/null || true)" in
    rw-????????-????????)
      rw_die "rw handback: this shell is the remote side of a handed-off pane; run 'rw handback --root <path>' from a local pane or the picker instead." 64
      ;;
  esac
fi

root_arg=""
pane_id="${TMUX_PANE:-}"
check_lfs="false"
force_diverged="false"
resolve=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root) root_arg="${2:?}"; shift 2 ;;
    --pane) pane_id="${2:?}"; shift 2 ;;
    --check-lfs) check_lfs="true"; shift ;;
    --force-diverged) force_diverged="true"; shift ;;
    --resolve) resolve="${2:?}"; shift 2 ;;
    *) rw_die "rw handback: unknown argument: $1" 64 ;;
  esac
done
case "$resolve" in '' | overwrite | keep-both | abort) : ;; *) rw_die "rw handback: --resolve must be overwrite, keep-both or abort" 64 ;; esac

start_ts="$(rw_now_epoch)"

# ---------------------------------------------------------------------------
# 1. Record
# ---------------------------------------------------------------------------

root_id=""
if [ -n "$root_arg" ]; then
  rel="$(rw_root_rel "$root_arg")" || rw_die "rw handback: '$root_arg' is not inside your home directory." 7
  root_id="$(rw_root_id "$rel")"
elif [ -n "$pane_id" ]; then
  root_id="$(rw_pane_get "$pane_id" @rw-root-id)"
  if [ -z "$root_id" ]; then
    ep="$(rw_pane_get "$pane_id" @rw-endpoint)"
    [ -n "$ep" ] && root_id="$(rw_read_endpoint "$ep" 2>/dev/null | jq -r '.root_id // empty')"
  fi
  if [ -z "$root_id" ]; then
    cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
    [ -n "$cwd" ] && root_id="$(rw_owned_root_for_path "$cwd" || true)"
  fi
else
  root_id="$(rw_owned_root_for_path "$(pwd -P)" || true)"
fi

record=""
[ -n "$root_id" ] && record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
if [ -z "$record" ] || [ "$(printf '%s' "$record" | jq -r '.owner')" != "worker" ]; then
  rw_die "rw handback: ${root_arg:-this pane} is not in a remote root; nothing to hand back." 7
fi

worker="$(printf '%s' "$record" | jq -r '.worker')"
root_rel="$(printf '%s' "$record" | jq -r '.root_rel')"
root_local="$(printf '%s' "$record" | jq -r '.root_local')"
kind="$(printf '%s' "$record" | jq -r '.kind')"
# shellcheck disable=SC2207 # endpoint ids are fixed-format hex
endpoints=($(printf '%s' "$record" | jq -r '.endpoints[]?'))
fail_event() { rw_log_event "handback" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "root=$root_rel $1"; }

rw_worker_known "$worker" || rw_die "rw handback: worker '$worker' (from the ownership record) is not declared in config.json" 1

preflight_args=(--worker "$worker")
[ "$check_lfs" = "true" ] && preflight_args+=(--check-lfs)
preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  code="$(rw_preflight_exit "$preflight_json")"
  fail_event "preflight_failed"
  if [ "$code" = "6" ]; then
    rw_warn "rw handback: '$worker' cannot be reached, so '$root_rel' was not handed back and nothing changed. If it will stay unreachable, 'rw reclaim --force $root_local' takes ownership back from the local (frozen) copy."
  fi
  exit "$code"
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"
worker_root="$(printf '%s' "$record" | jq -r '.worker_root // empty')"
[ -n "$worker_root" ] || worker_root="${worker_home%/}/$root_rel"

rw_reconcile_pending "$worker" "$worker_home"

# ---------------------------------------------------------------------------
# 2. Agent version policy, inverted: the local CLI resumes now.
# ---------------------------------------------------------------------------

checked=" "
for e in ${endpoints[@]+"${endpoints[@]}"}; do
  ej="$(rw_read_endpoint "$e" 2>/dev/null)" || continue
  provider="$(printf '%s' "$ej" | jq -r 'select(.agent.state == "handed-off") | .agent.provider // empty')"
  [ -n "$provider" ] && [ -x "$ADAPTERS_DIR/$provider" ] || continue
  case "$checked" in *" $provider "*) continue ;; esac
  checked="$checked$provider "
  verr="$(mktemp "${TMPDIR:-/tmp}/rw-handback-versions.XXXXXX")"
  vstatus=0
  vjson="$("$ADAPTERS_DIR/$provider" versions --worker "$worker" 2>"$verr" </dev/null)" || vstatus=$?
  if [ "$vstatus" -eq 0 ] && [ "$(printf '%s' "$vjson" | jq -r '.policy // empty')" = "newer_worker" ]; then
    # Only CLI oldness blocks; a Node-only difference with equal CLIs does not.
    lcli="$(printf '%s' "$vjson" | jq -r 'if (.local | type) == "object" then .local.cli // empty else .local // empty end')"
    wcli="$(printf '%s' "$vjson" | jq -r 'if (.worker | type) == "object" then .worker.cli // empty else .worker // empty end')"
    if [ -z "$lcli" ] || [ "$lcli" != "$wcli" ]; then
      rw_warn "rw handback: the local $provider CLI ($lcli) is older than the remote one ($wcli) that wrote this session; update the local $provider and retry. Nothing was moved."
      rm -f "$verr"
      fail_event "agent_version_blocked:$provider"
      exit 3
    fi
  elif [ "$vstatus" -ne 0 ] && [ "$vstatus" -ne 3 ]; then
    rw_warn "rw handback: $provider version check failed (exit $vstatus); continuing. $(cat "$verr")"
  fi
  rm -f "$verr"
done

# ---------------------------------------------------------------------------
# 3. One pull of the root
# ---------------------------------------------------------------------------

work="$(mktemp -d "${TMPDIR:-/tmp}/rw-handback.XXXXXX")"
trap 'rm -rf "$work"' EXIT
record_dir="$(rw_owned_record_dir "$root_id")"

sync_args=(sync --direction handback --pull --kind "$kind"
  --source-path "$worker_root" --dest-path "$root_local"
  --dest-mode ssh --dest-worker "$worker"
  --dest-manifest "$record_dir/manifest.focus.tsv" --manifest-out "$work/manifests"
  --token "root-$root_id")
[ "$check_lfs" = "true" ] && sync_args+=(--check-lfs)
[ "$force_diverged" = "true" ] && sync_args+=(--force-diverged)
[ -n "$resolve" ] && sync_args+=(--resolve "$resolve")

sync_status=0
sync_out="$("$SYNC_DIR/handoff" "${sync_args[@]}" 2>"$work/sync.err" </dev/null)" || sync_status=$?
case "$sync_status" in
  0) : ;;
  5)
    cat "$work/sync.err" >&2
    printf '%s\n' "$sync_out"
    fail_event "manifest_conflict"
    exit 5
    ;;
  2)
    cat "$work/sync.err" >&2
    fail_event "diverged"
    exit 2
    ;;
  *)
    rw_warn "rw handback: transfer of '$root_rel' failed (exit $sync_status); every pane is still remote:"
    cat "$work/sync.err" >&2
    fail_event "sync_failed:$sync_status"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# 4. Panes
# ---------------------------------------------------------------------------

closable=()
leftover=()
returned=0

# restore_agent <endpoint-json> <pane_id> -- 0 when there was no agent or it
# resumed locally (and the remote copy was told to stop).
restore_agent() {
  local ej="$1" pid="$2" provider session mode pfocus pworker adapter dir err rc_args cmd session_name
  provider="$(printf '%s' "$ej" | jq -r 'select(.agent.state == "handed-off") | .agent.provider // empty')"
  [ -n "$provider" ] || return 0
  session="$(printf '%s' "$ej" | jq -r '.agent.session_id // empty')"
  mode="$(printf '%s' "$ej" | jq -r '.agent.mode_flags // empty')"
  pfocus="$(printf '%s' "$ej" | jq -r '.agent.project_path_focus // .workspace.focus_path // empty')"
  pworker="$(printf '%s' "$ej" | jq -r '.agent.project_path_worker // .workspace.remote_path // empty')"
  adapter="$ADAPTERS_DIR/$provider"
  if [ ! -x "$adapter" ]; then
    rw_warn "rw handback: no local $provider adapter; its remote session keeps running."
    return 1
  fi
  dir="$(mktemp -d "$work/agent.XXXXXX")"
  err="$dir.err"
  if ! "$adapter" export --session-id "$session" --project-path "$pworker" --out "$dir" --worker "$worker" </dev/null >/dev/null 2>"$err"; then
    rw_warn "rw handback: $provider export from the remote failed; its remote session keeps running. $(cat "$err")"
    return 1
  fi
  if ! "$adapter" install --snapshot "$dir" --dest-path "$pfocus" </dev/null >/dev/null 2>"$err"; then
    rw_warn "rw handback: local $provider install failed; its remote session keeps running. $(cat "$err")"
    return 1
  fi
  rc_args=(resume-cmd --dest-path "$pfocus" --session-id "$session")
  [ -n "$mode" ] && rc_args+=(--mode-flags "$mode")
  if ! cmd="$("$adapter" "${rc_args[@]}" 2>"$err")"; then
    rw_warn "rw handback: $provider resume-cmd failed; its remote session keeps running. $(cat "$err")"
    return 1
  fi
  if ! tmux send-keys -t "$pid" "$cmd" Enter 2>"$err"; then
    rw_warn "rw handback: could not type the $provider resume into pane $pid; its remote session keeps running."
    return 1
  fi
  if ! rw_wait_local_provider_started "$pid" "$provider"; then
    rw_warn "rw handback: could not confirm $provider started in pane $pid; its remote session keeps running (never zero copies)."
    return 1
  fi
  session_name="$(rw_session_name "$(printf '%s' "$ej" | jq -r '.endpoint_id')")"
  rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "tmux send-keys -t $(rw_shquote "$session_name") C-c" </dev/null >/dev/null 2>&1 || true
  return 0
}

bound="$(rw_root_bound_panes "$root_id" ${endpoints[@]+"${endpoints[@]}"})"
for e in ${endpoints[@]+"${endpoints[@]}"}; do
  ej="$(rw_read_endpoint "$e" 2>/dev/null || true)"
  pid="$(printf '%s\n' "$bound" | awk -F '\t' -v e="$e" '$2 == e { print $1; exit }')"
  has_agent="$(printf '%s' "$ej" | jq -r 'if .agent.state == "handed-off" then "yes" else "no" end' 2>/dev/null)"
  case "$(printf '%s' "$ej" | jq -r '.role // empty' 2>/dev/null)" in
    tree | tree-editor)
      # Remote tree/editor panes have no local equivalent: close them (their
      # loop sees the tombstone and closes the pane).
      closable+=("$e")
      continue
      ;;
  esac
  if [ -z "$pid" ]; then
    if [ "$has_agent" = "yes" ]; then
      rw_warn "rw handback: endpoint $e has a remote agent but no local pane; its remote session keeps running (attach it with 'rw open', or close it with 'rw close')."
      leftover+=("$e")
    else
      closable+=("$e")
    fi
    continue
  fi
  focus_path="$(printf '%s' "$ej" | jq -r '.workspace.focus_path // empty' 2>/dev/null)"
  [ -d "$focus_path" ] || focus_path="$root_local"
  if ! rw_release_pane "$pid" "$focus_path"; then
    rw_warn "rw handback: could not replace pane $pid with a local shell; endpoint $e stays open."
    leftover+=("$e")
    continue
  fi
  rw_wait_local_shell "$pid" || rw_warn "rw handback: pane $pid did not show a local shell yet."
  returned=$((returned + 1))
  if [ -n "$ej" ] && ! restore_agent "$ej" "$pid"; then
    leftover+=("$e")
  else
    closable+=("$e")
  fi
done

# ---------------------------------------------------------------------------
# 5. Close worker sessions, ownership back to focus, mirror
# ---------------------------------------------------------------------------

rw_close_root_endpoints "$root_id" "handback" ${closable[@]+"${closable[@]}"}

cp "$work/manifests/dest.tsv" "$record_dir/manifest.focus.tsv"
cp "$work/manifests/source.tsv" "$record_dir/manifest.worker.tsv"
now="$(rw_now_iso)"
final="$(rw_owned_record_read "$root_id" | jq -c --arg now "$now" '.owner = "focus" | .since = $now')"
if [ "${#leftover[@]}" -gt 0 ]; then
  final="$(printf '%s' "$final" | jq -c --arg now "$now" --arg ids "${leftover[*]}" \
    '.pending = {action: "reconcile", reason: ("remote agent left running on endpoint(s) " + $ids), at: $now}')"
fi
rw_owned_record_write "$root_id" "$final"
rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null ||
  rw_warn "rw handback: could not refresh the ownership mirror on '$worker'; the next handoff will compare against the older manifest."
if [ "${#leftover[@]}" -eq 0 ]; then
  rw_owned_record_remove "$root_id"
fi

rw_log_event "handback" "" "$worker" "$(rw_elapsed_ms "$start_ts")" \
  "$([ "${#leftover[@]}" -eq 0 ] && echo success || echo partial)" \
  "root=$root_rel kind=$kind panes=$returned closed=${#closable[@]} left=${#leftover[@]} $(printf '%s' "$sync_out" | jq -r '"renamed=\(.renamed | length) overwritten=\(.overwritten)"' 2>/dev/null)"
printf 'rw: %s is local again (%d pane(s) back).\n' "$root_rel" "$returned"
if [ "${#leftover[@]}" -gt 0 ]; then
  rw_warn "rw handback: ${#leftover[@]} remote session(s) were left running: ${leftover[*]}. 'rw status' lists them; they close on the next handoff or forget of this root."
  exit 1
fi
exit 0
