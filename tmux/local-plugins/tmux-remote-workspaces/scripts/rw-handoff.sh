#!/usr/bin/env bash
# `rw handoff` -- hand a directory root, and every pane working inside it,
# to a worker (docs/tasks/mini-remote-sessions.md, P1 and contract C2).
#
# The unit is a directory: the git toplevel of a worktree, or a plain
# folder. Every pane on this tmux server whose cwd is the root or inside it
# (any depth, any session) moves; the rest of a mixed session stays local.
# While the root is remote the worker copy is the single source of truth;
# the local copy stays on disk, frozen.
#
# Order (nothing is replaced until everything that can refuse has run):
#   1. Resolve the root (exit 7 when outside ~, inside a git worktree, or
#      already remote). Preflight the worker (exit 6 unreachable).
#   2. Per pane: detect a supported agent; refuse a busy pane no adapter
#      recognizes; check the provider version policy. One exit-3 version
#      block aborts the whole handoff before any pane is touched.
#   3. ONE sync of the root (libexec/sync/handoff): git channel + rsync
#      channel, divergence gate (exit 2), manifest gate (exit 5 unless
#      --resolve). Record owner = worker, write the worker mirror.
#   4. Per pane: a hidden worker session rw-<focus>-<endpoint> in the
#      pane's mapped directory; agent export/install/resume there; stop the
#      local agent only after the remote one verifiably started; endpoint
#      record (contract C3); the pane is replaced by the attach loop.
#
# A pane whose agent resume cannot be verified keeps its local agent
# running (never two writers, never zero) and is reported; the root still
# moved.
#
# Usage: rw-handoff.sh --worker <alias> [--root <path>] [--pane <pane-id>]
#                      [--check-lfs] [--force-diverged]
#                      [--resolve overwrite|keep-both|abort]
#
# Exit: 0 ok, 1 failure, 2 git divergence, 3 agent CLI version gate,
#       5 manifest conflict (stdout: conflict<TAB>path<TAB>kind),
#       6 worker unreachable, 7 root invalid or already remote, 64 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/../libexec/sync"
ADAPTERS_DIR="$SCRIPT_DIR/../libexec/adapters"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

worker=""
root_arg=""
pane_id="${TMUX_PANE:-}"
check_lfs="false"
force_diverged="false"
resolve=""

while [ $# -gt 0 ]; do
  case "$1" in
    --worker) worker="${2:?}"; shift 2 ;;
    --root) root_arg="${2:?}"; shift 2 ;;
    --pane) pane_id="${2:?}"; shift 2 ;;
    --check-lfs) check_lfs="true"; shift ;;
    --force-diverged) force_diverged="true"; shift ;;
    --resolve) resolve="${2:?}"; shift 2 ;;
    *) rw_die "rw handoff: unknown argument: $1" 64 ;;
  esac
done

[ -n "$worker" ] || rw_die "rw handoff: --worker is required" 64
rw_worker_known "$worker" || rw_die "rw handoff: worker '$worker' is not declared in config.json" 64
case "$resolve" in '' | overwrite | keep-both | abort) : ;; *) rw_die "rw handoff: --resolve must be overwrite, keep-both or abort" 64 ;; esac

start_ts="$(rw_now_epoch)"
fail_event() { rw_log_event "handoff" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "$1"; }

# ---------------------------------------------------------------------------
# 1. Root
# ---------------------------------------------------------------------------

if [ -n "$root_arg" ]; then
  [ -d "$root_arg" ] || rw_die "rw handoff: --root '$root_arg' is not a directory" 7
  root_local="$(rw_physical_path "$root_arg")"
else
  if [ -n "$pane_id" ]; then
    cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
  fi
  [ -n "${cwd:-}" ] || cwd="$(pwd -P)"
  if existing="$(rw_owned_root_for_path "$cwd")"; then
    rw_die "rw handoff: '$cwd' is inside '$(jq -r '.root_local' "$(rw_owned_record_file "$existing")")', which is already remote. Use 'rw open' for a new remote pane there, or 'rw handback' to bring it back." 7
  fi
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  root_local="$(rw_physical_path "${top:-$cwd}")"
fi

root_rel="$(rw_root_rel "$root_local")" ||
  rw_die "rw handoff: '$root_local' is not inside your home directory (or is the home directory itself); only directories under ~ can be handed off." 7
kind="$(rw_root_kind "$root_local")"
[ "$kind" != "inside-git" ] ||
  rw_die "rw handoff: '$root_local' is inside the git worktree '$(git -C "$root_local" rev-parse --show-toplevel)'; hand off the worktree root instead." 7
root_id="$(rw_root_id "$root_rel")"

if record="$(rw_owned_record_read "$root_id")"; then
  rec_owner="$(printf '%s' "$record" | jq -r '.owner')"
  rec_worker="$(printf '%s' "$record" | jq -r '.worker')"
  if [ "$rec_owner" = "worker" ]; then
    rw_die "rw handoff: '$root_rel' is already remote on '$rec_worker'." 7
  fi
  if [ "$rec_worker" != "$worker" ]; then
    rw_die "rw handoff: '$root_rel' still has a pending $(printf '%s' "$record" | jq -r '.pending.action // "cleanup"') on '$rec_worker' (it was unreachable). Run 'rw forget $root_local --worker $rec_worker' once it is reachable, then retry." 7
  fi
fi
if overlap="$(rw_owned_overlap "$root_local")"; then
  rw_die "rw handoff: '$root_local' overlaps the remote root '$overlap'; roots never nest across an ownership boundary." 7
fi

# ---------------------------------------------------------------------------
# 1b. Preflight
# ---------------------------------------------------------------------------

preflight_args=(--worker "$worker")
repo_remote=""
if [ "$kind" = "git" ]; then
  repo_remote="$(git -C "$root_local" remote get-url origin 2>/dev/null || true)"
  # LFS preflight when asked, or when the worktree actually tracks LFS
  # content (fail loud here, not at destination checkout).
  if [ "$check_lfs" != "true" ] &&
    [ -n "$(git -C "$root_local" lfs ls-files --name-only 2>/dev/null | head -1)" ]; then
    check_lfs="true"
  fi
fi
[ "$check_lfs" = "true" ] && preflight_args+=(--check-lfs)
[ -n "$repo_remote" ] && preflight_args+=(--repo-remote "$repo_remote")

preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  fail_event "preflight_failed"
  exit "$(rw_preflight_exit "$preflight_json")"
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"
worker_identity="$(printf '%s' "$preflight_json" | jq -r '.hostname')"
[ -n "$worker_home" ] && [ "$worker_home" != "null" ] || rw_die "rw handoff: preflight did not report the remote home directory" 1
worker_root="${worker_home%/}/$root_rel"

# Anything left pending for this worker (an earlier forget or reclaim while
# it was unreachable) runs now that it answered.
rw_reconcile_pending "$worker" "$worker_home"

# ---------------------------------------------------------------------------
# 2. Panes and agents
# ---------------------------------------------------------------------------

pane_lines=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  p_endpoint="$(printf '%s' "$line" | cut -f6)"
  if [ -n "$p_endpoint" ]; then
    rw_warn "rw handoff: pane $(printf '%s' "$line" | cut -f1) already has remote endpoint $p_endpoint; left as is."
    continue
  fi
  pane_lines+=("$line")
done < <(rw_root_panes "$root_local")

# Per-pane agent detection results, index-aligned with pane_lines.
p_provider=()
p_session=()
p_project=()
p_mode=()
version_checked=" "

for i in "${!pane_lines[@]}"; do
  line="${pane_lines[$i]}"
  pid="$(printf '%s' "$line" | cut -f1)"
  pcmd="$(printf '%s' "$line" | cut -f8)"
  provider="" session="" project="" mode=""
  for candidate in pi claude codex; do
    adapter="$ADAPTERS_DIR/$candidate"
    [ -x "$adapter" ] || continue
    detect_out="$("$adapter" detect --pane "$pid" 2>/dev/null)" || continue
    provider="$(printf '%s' "$detect_out" | jq -r '.provider // empty' 2>/dev/null)"
    session="$(printf '%s' "$detect_out" | jq -r '.session_id // empty' 2>/dev/null)"
    project="$(printf '%s' "$detect_out" | jq -r '.project_path // empty' 2>/dev/null)"
    mode="$(printf '%s' "$detect_out" | jq -r '.mode_flags // empty' 2>/dev/null)"
    if [ -n "$provider" ] && [ -n "$session" ]; then
      break
    fi
    provider="" session="" project="" mode=""
  done

  # A busy pane no adapter recognizes must not be replaced: detection may
  # have raced the agent's own session recording, and respawning would kill
  # the only copy. Shells and editors are deliberate workspace-only panes;
  # the calling pane runs this very command.
  if [ -z "$provider" ] && [ "$pid" != "${TMUX_PANE:-}" ] && ! rw_is_idle_command "$pcmd"; then
    fail_event "agent_detection_unconfirmed:pane=$pid cmd=${pcmd:-unknown}"
    rw_die "rw handoff: pane $pid runs '${pcmd:-unknown}', which is neither a shell, an editor, nor a recognized agent session; nothing was moved. Stop it or wait for the agent to finish starting, then retry." 1
  fi

  if [ -n "$provider" ]; then
    case "$version_checked" in
      *" $provider "*) : ;;
      *)
        versions_err="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-versions.XXXXXX")"
        versions_status=0
        versions_json="$("$ADAPTERS_DIR/$provider" versions --worker "$worker" 2>"$versions_err")" || versions_status=$?
        if [ "$versions_status" -eq 3 ]; then
          rw_warn "rw handoff: the remote $provider CLI is older than the local one, so its session cannot be resumed there. Nothing was moved:"
          rw_warn "$(cat "$versions_err")"
          rm -f "$versions_err"
          fail_event "agent_version_blocked:$provider"
          exit 3
        elif [ "$versions_status" -ne 0 ]; then
          rw_warn "rw handoff: $provider version check failed (exit $versions_status): $(cat "$versions_err")"
          rm -f "$versions_err"
          fail_event "agent_version_check_failed:$provider"
          exit 1
        fi
        if [ "$(printf '%s' "$versions_json" | jq -r '.policy // empty' 2>/dev/null)" = "newer_worker" ]; then
          rw_warn "rw handoff: notice -- the remote $provider CLI is newer than the local one; proceeding."
        fi
        rm -f "$versions_err"
        version_checked="$version_checked$provider "
        ;;
    esac
  fi
  p_provider[i]="$provider"
  p_session[i]="$session"
  p_project[i]="$project"
  p_mode[i]="$mode"
done

# Duplicate managed-writer guard: never launch a second managed writer for
# an agent session that is already handed off on another endpoint.
for i in "${!pane_lines[@]}"; do
  [ -n "${p_provider[$i]}" ] || continue
  if [ -d "$(rw_endpoints_dir)" ] && dupe="$(jq -r --arg p "${p_provider[$i]}" --arg s "${p_session[$i]}" \
    'select(.agent.provider == $p and .agent.session_id == $s and .agent.state == "handed-off") | .endpoint_id' \
    "$(rw_endpoints_dir)"/*.json 2>/dev/null | head -n1)" && [ -n "$dupe" ]; then
    fail_event "duplicate_managed_writer:${p_provider[$i]}"
    rw_die "rw handoff: ${p_provider[$i]} session ${p_session[$i]} is already running remotely on endpoint $dupe; hand that root back or close the endpoint first." 1
  fi
done

# ---------------------------------------------------------------------------
# 3. One sync of the root
# ---------------------------------------------------------------------------

work="$(mktemp -d "${TMPDIR:-/tmp}/rw-handoff.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fetch_status=0
rw_worker_mirror_fetch "$worker" "$worker_home" "$root_id" manifest.worker.tsv "$work/stored.worker.tsv" || fetch_status=$?
if [ "$fetch_status" -ne 0 ]; then
  fail_event "mirror_fetch_unreachable"
  rw_die "rw handoff: lost contact with '$worker' while reading its copy's manifest; nothing was moved." 6
fi

worker_state="$(rw_state_dir_at "$worker_home")"
sync_args=(sync --direction handoff --kind "$kind"
  --source-path "$root_local" --dest-path "$worker_root"
  --dest-mode ssh --dest-worker "$worker"
  --dest-manifest "$work/stored.worker.tsv" --manifest-out "$work/manifests"
  --token "root-$root_id"
  --backup-root "$worker_state/handoff-backups" --staging-root "$worker_state/handoff-staging")
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
    rw_warn "rw handoff: transfer of '$root_rel' failed (exit $sync_status); no pane was moved:"
    cat "$work/sync.err" >&2
    fail_event "sync_failed:$sync_status"
    exit 1
    ;;
esac

# Courtesy: give a git destination an `origin` so push/pull work there.
if [ -n "$repo_remote" ]; then
  rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "git -C $(rw_shquote "$worker_root") remote get-url origin >/dev/null 2>&1 || git -C $(rw_shquote "$worker_root") remote add origin $(rw_shquote "$repo_remote")" \
    </dev/null >/dev/null 2>&1 || true
fi

record="$(rw_record_new "$root_id" "$root_rel" "$root_local" "$kind" "$worker" "$worker_root" | jq -c '.owner = "worker"')"
rw_owned_record_write "$root_id" "$record"
record_dir="$(rw_owned_record_dir "$root_id")"
cp "$work/manifests/source.tsv" "$record_dir/manifest.focus.tsv"
cp "$work/manifests/dest.tsv" "$record_dir/manifest.worker.tsv"
rw_held_mark "$worker" "$root_id" "$root_rel" "$worker_root"
rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null ||
  rw_warn "rw handoff: could not write the ownership mirror on '$worker' (it will be rewritten on the next ownership change)."

# ---------------------------------------------------------------------------
# 4. Panes
# ---------------------------------------------------------------------------

moved=0
failed=0
self_index=""

# handoff_pane <index> -- sets $last_endpoint; returns 0 when the pane may be
# replaced by its attach loop.
handoff_pane() {
  local i="$1" line pid pcwd psession pwindex ppindex
  line="${pane_lines[$i]}"
  IFS="$RW_TAB" read -r pid pcwd psession pwindex ppindex _ _ _ <<<"$line"
  local provider="${p_provider[$i]}" session="${p_session[$i]}" project="${p_project[$i]}" mode="${p_mode[$i]}"
  local endpoint_id session_name remote_path
  endpoint_id="$(rw_new_short_id)"
  session_name="$(rw_session_name "$endpoint_id")"
  remote_path="$(rw_path_under_root "$pcwd" "$root_local" "$worker_root")"
  last_endpoint="$endpoint_id"

  if ! rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)" </dev/null >/dev/null 2>&1; then
    rw_warn "rw handoff: could not create the remote session for pane $pid; it stays local."
    return 1
  fi

  local agent_outcome="not_attempted" agent_resume_cmd="" agent_state="" agent_dest=""
  if [ -n "$provider" ]; then
    local adapter="$ADAPTERS_DIR/$provider" export_dir err
    export_dir="$(mktemp -d "$work/agent.XXXXXX")"
    err="$work/agent-$i.err"
    # The worker's PHYSICAL path: Claude slugs its project dir from it.
    agent_dest="$(rw_path_under_root "$(rw_physical_path "${project:-$pcwd}")" "$root_local" "$worker_root")"
    if ! "$adapter" export --session-id "$session" --project-path "${project:-$pcwd}" --out "$export_dir" </dev/null >/dev/null 2>"$err"; then
      agent_outcome="export_failed"
    elif ! "$adapter" install --snapshot "$export_dir" --dest-path "$agent_dest" --worker "$worker" </dev/null >/dev/null 2>"$err"; then
      agent_outcome="install_failed"
    else
      local rc_args=(resume-cmd --dest-path "$agent_dest" --session-id "$session")
      [ -n "$mode" ] && rc_args+=(--mode-flags "$mode")
      if ! agent_resume_cmd="$("$adapter" "${rc_args[@]}" 2>"$err")"; then
        agent_outcome="resume_gated"
        agent_resume_cmd=""
      elif ! rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
        "tmux send-keys -t $(rw_shquote "$session_name") $(rw_shquote "$agent_resume_cmd") Enter" </dev/null >/dev/null 2>"$err"; then
        agent_outcome="resume_dispatch_failed"
      elif ! rw_wait_remote_provider_started "$worker" "$session_name" "$provider" </dev/null; then
        agent_outcome="resume_unverified"
      else
        agent_outcome="resumed"
        agent_state="handed-off"
      fi
    fi
    if [ "$agent_outcome" != "resumed" ]; then
      rw_warn "rw handoff: pane $pid: $provider $agent_outcome -- its local agent keeps running and the pane stays local; the remote session '$session_name' is left for inspection. $(cat "$err" 2>/dev/null)"
    else
      # Stop the detected provider's own processes under the pane (never a
      # blind child walk: claude keeps helper children).
      local pane_pid agent_pids agent_pid
      pane_pid="$(tmux display-message -pt "$pid" -F '#{pane_pid}' 2>/dev/null || true)"
      if [ -n "$pane_pid" ]; then
        agent_pids="$(ps axo pid=,ppid=,command= 2>/dev/null |
          rw_ps_tree_match_pids "$(rw_provider_pattern "$provider")" "$pane_pid")"
        if [ -n "$agent_pids" ]; then
          # shellcheck disable=SC2086 # pid list is intentionally word-split
          kill -TERM $agent_pids 2>/dev/null || true
          sleep 0.5
          for agent_pid in $agent_pids; do
            kill -0 "$agent_pid" 2>/dev/null && kill -KILL "$agent_pid" 2>/dev/null
          done
        fi
      fi
    fi
  fi

  local now session_uuid
  now="$(rw_now_iso)"
  session_uuid="$(tmux show-option -t "$pid" -qv @session-uuid 2>/dev/null || true)"
  [ -n "$session_uuid" ] || session_uuid="$(rw_pane_get "$pid" @rw-session-uuid)"

  rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$(jq -nc \
    --arg endpoint_id "$endpoint_id" \
    --arg worker "$worker" \
    --arg worker_identity "$worker_identity" \
    --arg focus_machine_id "$(rw_machine_id)" \
    --arg root_id "$root_id" \
    --arg root_rel "$root_rel" \
    --arg focus_session_uuid "$session_uuid" \
    --arg focus_session_name "$psession" \
    --argjson focus_window_index "${pwindex:-0}" \
    --argjson focus_pane_index "${ppindex:-0}" \
    --arg focus_pane_id "$pid" \
    --arg kind "$kind" \
    --arg focus_path "$pcwd" \
    --arg remote_path "$remote_path" \
    --arg root_local "$root_local" \
    --arg worker_root "$worker_root" \
    --arg provider "$provider" \
    --arg session "$session" \
    --arg project_focus "${project:-$pcwd}" \
    --arg project_worker "$agent_dest" \
    --arg mode "$mode" \
    --arg resume "$agent_resume_cmd" \
    --arg outcome "$agent_outcome" \
    --arg state "$agent_state" \
    --arg now "$now" \
    '{endpoint_id: $endpoint_id, worker: $worker, worker_identity: $worker_identity,
      focus_machine_id: $focus_machine_id, root_id: $root_id, root_rel: $root_rel,
      focus_session_uuid: $focus_session_uuid, focus_session_name: $focus_session_name,
      focus_window_index: $focus_window_index, focus_pane_index: $focus_pane_index,
      focus_pane_id: $focus_pane_id,
      workspace: {mode: $kind, identity: "", focus_path: $focus_path, remote_path: $remote_path,
        root_local: $root_local, worker_root: $worker_root},
      launch_intent: {worker: $worker, workspace_arg: "handoff"},
      agent: (if $provider == "" then {provider: null, session_id: null, resume_intent: null, state: null}
        else {provider: $provider, session_id: $session, resume_intent: $resume,
          project_path_focus: $project_focus, project_path_worker: $project_worker,
          mode_flags: (if $mode == "" then null else $mode end), outcome: $outcome,
          divergence_risk: false, state: (if $state == "" then null else $state end)} end),
      created_at: $now, updated_at: $now, generation: 1}')"
  rw_record_add_endpoint "$root_id" "$endpoint_id"

  if [ -n "$provider" ] && [ "$agent_outcome" != "resumed" ]; then
    return 1
  fi

  rw_pane_set "$pid" @rw-endpoint "$endpoint_id"
  rw_pane_set "$pid" @rw-worker "$worker"
  rw_pane_set "$pid" @rw-workspace "$remote_path"
  rw_pane_set "$pid" @rw-root-id "$root_id"
  [ -n "$session_uuid" ] && rw_pane_set "$pid" @rw-session-uuid "$session_uuid"
  # The laptop pane no longer runs what it last ran; a stale command here
  # would be replayed by a restore and poison the verified save (C3).
  rw_pane_unset "$pid" @workspace-last-command
  return 0
}

# replace_pane <index> -- respawn a pane (not the caller's) into its loop.
replace_pane() {
  local i="$1" pid pcwd cmd attempt=0 loop_cmd
  IFS="$RW_TAB" read -r pid pcwd _ <<<"${pane_lines[$i]}"
  # A stopped agent takes a moment to unwind back to its shell.
  while [ "$attempt" -lt 15 ]; do
    cmd="$(tmux display-message -pt "$pid" -F '#{pane_current_command}' 2>/dev/null || true)"
    rw_is_idle_command "$cmd" && break
    attempt=$((attempt + 1))
    sleep 0.2
  done
  if ! rw_is_idle_command "$cmd"; then
    rw_warn "rw handoff: pane $pid still runs '${cmd:-unknown}'; endpoint $last_endpoint is registered but the pane was not replaced. Run 'rw open --pane $pid' once it is idle."
    return 1
  fi
  printf -v loop_cmd '%q %q --fresh' "$SCRIPT_DIR/attach-loop.sh" "$last_endpoint"
  if ! tmux respawn-pane -k -t "$pid" -c "$pcwd" "$loop_cmd" 2>/dev/null; then
    rw_warn "rw handoff: could not start the attach loop in pane $pid (endpoint $last_endpoint stays registered)."
    return 1
  fi
  return 0
}

for i in "${!pane_lines[@]}"; do
  pid="$(printf '%s' "${pane_lines[$i]}" | cut -f1)"
  if [ "$pid" = "${TMUX_PANE:-}" ]; then
    self_index="$i"
    continue
  fi
  last_endpoint=""
  if handoff_pane "$i" && replace_pane "$i"; then
    moved=$((moved + 1))
  else
    failed=$((failed + 1))
  fi
done

self_endpoint=""
if [ -n "$self_index" ]; then
  last_endpoint=""
  if handoff_pane "$self_index"; then
    self_endpoint="$last_endpoint"
    moved=$((moved + 1))
  else
    failed=$((failed + 1))
  fi
fi

rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null || true

rw_log_event "handoff" "$self_endpoint" "$worker" "$(rw_elapsed_ms "$start_ts")" \
  "$([ "$failed" -eq 0 ] && echo success || echo partial)" \
  "root=$root_rel kind=$kind panes=$moved failed=$failed $(printf '%s' "$sync_out" | jq -r '"renamed=\(.renamed | length) overwritten=\(.overwritten)"' 2>/dev/null)"
printf 'rw: %s is now remote on %s (%d pane(s) moved%s).\n' "$root_rel" "$worker" "$moved" \
  "$([ "$failed" -gt 0 ] && printf ', %d left local -- see above' "$failed")"

if [ -n "$self_endpoint" ]; then
  exec "$SCRIPT_DIR/attach-loop.sh" "$self_endpoint" --fresh
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
