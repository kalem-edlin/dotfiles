#!/usr/bin/env bash
# `rw handoff` -- elevate the CURRENT pane's local workspace (and, if an AI
# coding agent is running in it, the agent's conversation) to a durable
# remote endpoint on a worker.
#
# Implements initial-plan.md's 5-step transactional ordering ("Local-first
# AI coding-agent handoff"):
#   1. Preflight (worker reachability/binaries, provider version policy).
#      A failure here aborts with the local agent untouched.
#   2. Snapshot, transfer, and verify worker-side resume eligibility
#      (workspace git state via libexec/sync/handoff; agent transcript via
#      the provider adapter's export/install, if an agent was detected).
#   3. Start the provider resume command in the remote endpoint.
#   4. Stop the local agent (default) only after that resume has started.
#      `--keep-local` skips this and records divergence risk instead.
#   5. Any failure before step 3 leaves the local agent running and any
#      partially copied remote state inert (workspace transfer already
#      guarantees this on its own; see libexec/sync/README.md).
#
# No agent detected (or its adapter file is missing) => workspace-only
# handoff, with a clear notice -- this command never requires an agent.
#
# Usage: rw-handoff.sh --worker <alias> [--workspace <path>|auto]
#                       [--pane <pane-id>] [--keep-local] [--check-lfs]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/../libexec/sync"
ADAPTERS_DIR="$SCRIPT_DIR/../libexec/adapters"
# shellcheck source-path=SCRIPTDIR/../libexec/sync
# shellcheck source=../libexec/sync/common.sh
source "$SYNC_DIR/common.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

worker=""
workspace_arg="auto"
pane_id="${TMUX_PANE:-}"
keep_local="false"
check_lfs="false"
force_diverged="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --worker) worker="${2:?}"; shift 2 ;;
    --workspace) workspace_arg="${2:?}"; shift 2 ;;
    --pane) pane_id="${2:?}"; shift 2 ;;
    --keep-local) keep_local="true"; shift ;;
    --check-lfs) check_lfs="true"; shift ;;
    --force-diverged) force_diverged="true"; shift ;;
    *) rw_die "rw handoff: unknown argument: $1" 64 ;;
  esac
done

[ -n "$worker" ] || rw_die "rw handoff: --worker is required" 64
[ -n "$pane_id" ] || rw_die "rw handoff: must be run inside a tmux pane, or pass --pane explicitly (TMUX_PANE is unset)"
rw_worker_known "$worker" || rw_die "rw handoff: worker '$worker' is not declared in config.json"

handoff_start_ts="$(rw_now_epoch)"

# ---------------------------------------------------------------------------
# Step 1: preflight -- worker reachability/binaries first. A failure here
# aborts with the local pane/agent completely untouched.
# ---------------------------------------------------------------------------

cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || pwd)"

# Git-host auth preflight: this operation clearly involves a repository
# workspace whenever cwd has an origin remote -- pass it along so
# preflight.sh adds its worker-side git-host authentication check.
cwd_repo_remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
# LFS preflight only when the caller asked for it or the workspace actually
# tracks LFS content. Auto-detect matters in both directions: a non-LFS
# handoff must not be blocked by a worker that lacks git-lfs it never
# needs, and an LFS checkout sent without the check fails later at
# destination checkout (required smudge filter) instead of failing loud
# here.
if [ "$check_lfs" != "true" ] &&
  [ -n "$(git -C "$cwd" lfs ls-files --name-only 2>/dev/null | head -1)" ]; then
  check_lfs="true"
fi
preflight_args=(--worker "$worker")
[ "$check_lfs" = "true" ] && preflight_args+=(--check-lfs)
[ -n "$cwd_repo_remote" ] && preflight_args+=(--repo-remote "$cwd_repo_remote")

preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  rw_log_event "handoff" "" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "preflight_failed"
  exit 1
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"

# ---------------------------------------------------------------------------
# Agent detection (blind against the adapter contract -- libexec/adapters/
# is owned by a parallel workstream; a missing/non-executable adapter file
# degrades cleanly to workspace-only, per the contract in initial-plan.md).
# ---------------------------------------------------------------------------

agent_provider=""
agent_session_id=""
agent_project_path=""
agent_mode="none" # none | full

for candidate in pi claude codex; do
  adapter="$ADAPTERS_DIR/$candidate"
  [ -x "$adapter" ] || continue
  detect_out="$("$adapter" detect --pane "$pane_id" 2>/dev/null)" || continue
  agent_provider="$(printf '%s' "$detect_out" | jq -r '.provider // empty' 2>/dev/null)"
  agent_session_id="$(printf '%s' "$detect_out" | jq -r '.session_id // empty' 2>/dev/null)"
  agent_project_path="$(printf '%s' "$detect_out" | jq -r '.project_path // empty' 2>/dev/null)"
  if [ -n "$agent_provider" ] && [ -n "$agent_session_id" ]; then
    agent_mode="full"
    break
  fi
  agent_provider=""
done

if [ "$agent_mode" = "none" ]; then
  if [ ! -d "$ADAPTERS_DIR" ] || [ -z "$(find "$ADAPTERS_DIR" -maxdepth 1 -type f -perm -u+x 2>/dev/null)" ]; then
    rw_warn "rw handoff: no provider adapters are installed yet -- workspace-only handoff."
  else
    rw_warn "rw handoff: no supported AI agent detected in pane $pane_id -- workspace-only handoff."
  fi
fi

# ---------------------------------------------------------------------------
# Step 1 (continued): provider version policy, before anything is touched.
# ---------------------------------------------------------------------------

if [ "$agent_mode" = "full" ]; then
  adapter="$ADAPTERS_DIR/$agent_provider"
  versions_err="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-versions.XXXXXX")"
  versions_status=0
  versions_json="$("$adapter" versions --worker "$worker" 2>"$versions_err")" || versions_status=$?
  if [ "$versions_status" -ne 0 ]; then
    if [ "$versions_status" -eq 3 ]; then
      rw_warn "rw handoff: $agent_provider version policy blocks this handoff (worker CLI is older than local):"
      rw_warn "$(cat "$versions_err")"
      rw_log_event "handoff" "" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "agent_version_blocked:$agent_provider"
      rm -f "$versions_err"
      exit 1
    fi
    rw_warn "rw handoff: $agent_provider versions check failed unexpectedly (exit $versions_status); continuing as workspace-only. $(cat "$versions_err")"
    agent_mode="none"
  else
    versions_policy="$(printf '%s' "$versions_json" | jq -r '.policy // empty' 2>/dev/null)"
    if [ "$versions_policy" = "newer_worker" ]; then
      rw_warn "rw handoff: notice -- worker's $agent_provider CLI is newer than local's; proceeding (this is the ordinary provider upgrade path, per version policy)."
    fi
  fi
  rm -f "$versions_err"
fi

# ---------------------------------------------------------------------------
# Resolve the local worktree and the destination workspace placement.
# ---------------------------------------------------------------------------

local_is_git="false"
local_worktree_root="$cwd"
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  local_is_git="true"
  local_worktree_root="$(git -C "$cwd" rev-parse --show-toplevel)"
fi

existing_endpoint="$(rw_pane_get "$pane_id" @rw-endpoint)"
existing_worker="$(rw_pane_get "$pane_id" @rw-worker)"
reattach="false"
if [ -n "$existing_endpoint" ] && rw_endpoint_exists "$existing_endpoint" && [ "$existing_worker" = "$worker" ]; then
  reattach="true"
fi

if [ "$reattach" = "true" ]; then
  endpoint_id="$existing_endpoint"
  endpoint_json="$(rw_read_endpoint "$endpoint_id")"
  remote_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.remote_path')"
  workspace_mode="$(printf '%s' "$endpoint_json" | jq -r '.workspace.mode')"
  workspace_identity="$(printf '%s' "$endpoint_json" | jq -r '.workspace.identity')"
else
  resolution="$("$SCRIPT_DIR/resolve-workspace.sh" \
    --cwd "$cwd" --worker "$worker" --worker-home "$worker_home" --workspace "$workspace_arg")" ||
    rw_die "rw handoff: workspace resolution failed"
  workspace_mode="$(printf '%s' "$resolution" | jq -r '.mode')"
  workspace_identity="$(printf '%s' "$resolution" | jq -r '.identity')"
  remote_path="$(printf '%s' "$resolution" | jq -r '.remote_path')"
  endpoint_id="$(rw_new_short_id)"
fi

# ---------------------------------------------------------------------------
# Duplicate managed-writer guard (initial-plan.md, "Concurrent resumes and
# transcript divergence": "The system should prevent its own remote handoff
# command from launching two managed writers for the same logical agent
# session."). Scans the endpoint registry for another endpoint (not this
# one -- a reattach re-runs against itself) that already records this same
# provider+session_id with state "handed-off" (an active managed writer
# elsewhere). Wrapped in rw_with_lock so the check-then-act sequence is
# race-safe against a concurrent `rw handoff` invocation for the same
# session. `--keep-local` does not bypass this: a second handoff of the same
# already-diverged session must still hit this guard.
# ---------------------------------------------------------------------------

if [ "$agent_mode" = "full" ]; then
  dupe_lock_name="handoff-dupe-$(printf '%s:%s' "$agent_provider" "$agent_session_id" | tr -c 'A-Za-z0-9' '_')"
  dupe_found_file="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-dupe.XXXXXX")"
  rw_check_duplicate_writer() {
    local endpoints_dir f other_id other_provider other_session other_state other_worker
    endpoints_dir="$(rw_endpoints_dir)"
    [ -d "$endpoints_dir" ] || return 0
    for f in "$endpoints_dir"/*.json; do
      [ -f "$f" ] || continue
      other_id="$(jq -r '.endpoint_id // empty' "$f" 2>/dev/null)"
      [ -n "$other_id" ] && [ "$other_id" != "$endpoint_id" ] || continue
      other_provider="$(jq -r '.agent.provider // empty' "$f" 2>/dev/null)"
      other_session="$(jq -r '.agent.session_id // empty' "$f" 2>/dev/null)"
      other_state="$(jq -r '.agent.state // empty' "$f" 2>/dev/null)"
      if [ "$other_provider" = "$agent_provider" ] && [ "$other_session" = "$agent_session_id" ] && [ "$other_state" = "handed-off" ]; then
        other_worker="$(jq -r '.worker // empty' "$f" 2>/dev/null)"
        printf '%s\t%s\n' "$other_id" "$other_worker" >"$dupe_found_file"
        return 1
      fi
    done
    return 0
  }
  if ! rw_with_lock "$dupe_lock_name" rw_check_duplicate_writer; then
    dupe_info="$(cat "$dupe_found_file" 2>/dev/null)"
    dupe_endpoint="${dupe_info%%$'\t'*}"
    dupe_worker="${dupe_info#*$'\t'}"
    rw_warn "rw handoff: refusing -- $agent_provider session $agent_session_id is already an active managed writer on endpoint '$dupe_endpoint' (worker '$dupe_worker'). This command never launches two managed writers for the same logical agent session; return or close that endpoint first."
    rm -f "$dupe_found_file"
    rw_log_event "handoff" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "duplicate_managed_writer:$agent_provider"
    exit 1
  fi
  rm -f "$dupe_found_file"
fi

# ---------------------------------------------------------------------------
# Claim: bump the LOCAL claim's writer/generation before capturing the
# snapshot, so the marker that travels with the workspace already reflects
# the new active_writer_host. Skipped cleanly when there is no claim
# (claims are optional). Never invoked over ssh -- worktree-claim adopts a
# newer-generation marker lazily on the far side the next time anything
# there touches it (wt_sync_claim_from_marker).
# ---------------------------------------------------------------------------

claim_bin="$(rw_sync_worktree_claim_bin)"
had_claim="false"
if [ "$local_is_git" = "true" ] && [ -f "$local_worktree_root/$(rw_sync_claim_marker_name)" ] && [ -n "$claim_bin" ]; then
  had_claim="true"
  claim_out_file="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-claim.XXXXXX")"
  if ! "$claim_bin" handoff-writer --host "$worker" --path "$local_worktree_root" >"$claim_out_file" 2>&1; then
    claim_status=$?
    rw_warn "rw handoff: refusing -- worktree-claim handoff-writer failed (exit $claim_status): $(cat "$claim_out_file")"
    rm -f "$claim_out_file"
    rw_log_event "handoff" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "claim_mismatch:$claim_status"
    exit 1
  fi
  rm -f "$claim_out_file"
fi

# ---------------------------------------------------------------------------
# Step 2: workspace transfer (skipped for a non-git plain-directory pane --
# nothing to transfer). Backup-root/staging-root are pinned to the WORKER's
# own $HOME (from preflight), per libexec/sync/handoff's documented
# requirement that its own local-default only applies to same-host testing.
# ---------------------------------------------------------------------------

sync_generation=0
if [ "$local_is_git" = "true" ]; then
  # libexec/sync/handoff writes its workspace.sync bookkeeping onto this
  # endpoint's registry entry as part of a successful sync, which requires
  # the entry to already exist. On a fresh (non-reattach) handoff nothing
  # has been written yet -- seed a minimal placeholder now; the full entry
  # written later in this script re-merges workspace.sync back in rather
  # than clobbering it.
  if ! rw_endpoint_exists "$endpoint_id"; then
    rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" \
      "$(jq -nc --arg id "$endpoint_id" '{endpoint_id: $id, workspace: {}}')"
  fi

  sync_backup_root="$(rw_state_dir_at "$worker_home")/handoff-backups"
  sync_staging_root="$(rw_state_dir_at "$worker_home")/handoff-staging"
  sync_args=(sync --direction handoff
    --source-path "$local_worktree_root" --dest-path "$remote_path"
    --dest-mode ssh --dest-worker "$worker"
    --endpoint "$endpoint_id"
    --backup-root "$sync_backup_root" --staging-root "$sync_staging_root")
  [ "$check_lfs" = "true" ] && sync_args+=(--check-lfs)
  [ "$force_diverged" = "true" ] && sync_args+=(--force-diverged)

  sync_err_file="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-sync.XXXXXX")"
  sync_status=0
  sync_result="$("$SYNC_DIR/handoff" "${sync_args[@]}" 2>"$sync_err_file")" || sync_status=$?
  if [ "$sync_status" -ne 0 ]; then
    rw_warn "rw handoff: workspace transfer failed (exit $sync_status):"
    rw_warn "$(cat "$sync_err_file")"
    rm -f "$sync_err_file"
    # Remove the placeholder seeded above on a fresh (non-reattach) attempt
    # so a failed handoff leaves no registry trace at all, matching "abort
    # leaves local untouched" for the registry layer too.
    [ "$reattach" = "true" ] || rm -f "$(rw_endpoint_file "$endpoint_id")"
    # Roll back the writer flip made before the transfer: without this the
    # worktree stays claimed to a worker that has no endpoint, and
    # verify-writer then blocks the focus machine itself.
    if [ "$had_claim" = "true" ] && [ -n "$claim_bin" ]; then
      "$claim_bin" return-writer --path "$local_worktree_root" >/dev/null 2>&1 ||
        rw_warn "rw handoff: could not roll back the writer claim after the failed transfer -- run 'worktree-claim return-writer --path $local_worktree_root' manually."
    fi
    rw_log_event "handoff" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "sync_failed:$sync_status"
    exit 1
  fi
  rm -f "$sync_err_file"
  sync_generation="$(printf '%s' "$sync_result" | jq -r '.generation')"

  # Best-effort: give the destination an `origin` remote when we know the
  # source's, so ordinary push/pull/fetch keep working there later. Handoff
  # itself never needed the worker's git-host auth (all history/state
  # travels via the bundle+patches, not a clone) -- this is a courtesy, not
  # a requirement, and failure here never aborts the handoff.
  clone_url="$(git -C "$local_worktree_root" remote get-url origin 2>/dev/null || true)"
  if [ -n "$clone_url" ]; then
    rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "git -C '$remote_path' remote get-url origin >/dev/null 2>&1 || git -C '$remote_path' remote add origin '$clone_url'" \
      >/dev/null 2>&1 || true
  fi
else
  rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" "mkdir -p '$remote_path'" >/dev/null 2>&1 ||
    rw_die "rw handoff: could not prepare non-git workspace directory '$remote_path' on '$worker'"
fi

# ---------------------------------------------------------------------------
# Ensure the remote tmux endpoint session exists (same session-naming
# convention as `rw ensure`, so `rw status`/`rw close`/reattach all treat a
# handed-off pane identically to an ensured one).
# ---------------------------------------------------------------------------

session_name="$(rw_session_name "$endpoint_id")"
session_exists="$(rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" \
  "tmux has-session -t '$session_name' 2>/dev/null && echo yes || echo no" 2>/dev/null || echo no)"
if [ "$session_exists" != "yes" ]; then
  rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)" ||
    rw_die "rw handoff: failed to create remote endpoint session '$session_name' on '$worker'"
fi

# ---------------------------------------------------------------------------
# Steps 2 (agent snapshot)/3 (resume) -- only when a supported agent was
# detected and version policy allowed proceeding.
# ---------------------------------------------------------------------------

agent_resume_cmd=""
agent_outcome="not_attempted"
if [ "$agent_mode" = "full" ]; then
  adapter="$ADAPTERS_DIR/$agent_provider"
  export_dir="$(mktemp -d "${TMPDIR:-/tmp}/rw-handoff-agent-export.XXXXXX")"
  export_err="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-agent.XXXXXX")"

  if ! "$adapter" export --session-id "$agent_session_id" --project-path "$agent_project_path" --out "$export_dir" 2>"$export_err"; then
    rw_warn "rw handoff: $agent_provider export failed; continuing as workspace-only. $(cat "$export_err")"
    agent_outcome="export_failed"
  elif ! "$adapter" install --snapshot "$export_dir" --dest-path "$remote_path" --worker "$worker" 2>"$export_err"; then
    rw_warn "rw handoff: $agent_provider install on '$worker' failed; continuing as workspace-only. $(cat "$export_err")"
    agent_outcome="install_failed"
  else
    resume_status=0
    agent_resume_cmd="$("$adapter" resume-cmd --dest-path "$remote_path" --session-id "$agent_session_id" 2>"$export_err")" || resume_status=$?
    if [ "$resume_status" -ne 0 ]; then
      # NOTE: exit 4 (no resumable transcript) belongs to export/install, not
      # resume-cmd (see libexec/adapters/README.md's contract) -- no adapter
      # ever exits 4 here, so there is no separate branch for it.
      rw_warn "rw handoff: $agent_provider resume-cmd failed (exit $resume_status); continuing as workspace-only. $(cat "$export_err")"
      agent_outcome="resume_gated"
      agent_resume_cmd=""
    else
      # Dispatch the resume command, then verify it actually started before
      # this script's Step 4 stops the local agent (initial-plan.md step 4:
      # "Stop the local agent ... only after the remote resume has started
      # successfully"). Both the dispatch's own exit status AND a brief
      # poll for the provider process in the remote session are checked --
      # a successful `tmux send-keys` only proves the keystrokes were
      # delivered, not that the command they typed actually ran.
      dispatch_err="$(mktemp "${TMPDIR:-/tmp}/rw-handoff-dispatch.XXXXXX")"
      if ! rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
        "tmux send-keys -t '$session_name' $(rw_sync_shquote "$agent_resume_cmd") Enter" >/dev/null 2>"$dispatch_err"; then
        dispatch_status=$?
        rw_warn "rw handoff: failed to dispatch the $agent_provider resume command to '$worker' (tmux send-keys exit $dispatch_status): $(cat "$dispatch_err")"
        rw_warn "rw handoff: the local $agent_provider session was NOT stopped -- it is still running, untouched."
        agent_outcome="resume_dispatch_failed"
        rw_log_event "handoff" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "agent_resume_dispatch_failed:$agent_provider"
      elif ! rw_wait_remote_provider_started "$worker" "$session_name" "$agent_provider"; then
        rw_warn "rw handoff: dispatched the $agent_provider resume command to '$worker' but could not confirm the $agent_provider process started in session '$session_name' after polling."
        rw_warn "rw handoff: the local $agent_provider session was NOT stopped -- it is still running, untouched. Attach to '$worker'/'$session_name' to check manually."
        agent_outcome="resume_unverified"
        rw_log_event "handoff" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$handoff_start_ts")" "fail" "agent_resume_unverified:$agent_provider"
      else
        agent_outcome="resumed"
      fi
      rm -f "$dispatch_err"
    fi
  fi
  rm -rf "$export_dir"
  rm -f "$export_err"
fi

# ---------------------------------------------------------------------------
# Step 4: stop the local agent (default) only after a successful remote
# resume. --keep-local records divergence risk instead of stopping.
# ---------------------------------------------------------------------------

divergence_risk="false"
if [ "$agent_mode" = "full" ] && [ "$agent_outcome" = "resumed" ]; then
  if [ "$keep_local" = "true" ]; then
    divergence_risk="true"
    rw_warn "rw handoff: --keep-local -- the local $agent_provider session keeps running; transcript divergence risk recorded."
  else
    pane_pid="$(tmux list-panes -t "$pane_id" -F '#{pane_pid}' 2>/dev/null | head -1)"
    if [ -n "$pane_pid" ] && command -v pgrep >/dev/null 2>&1; then
      deepest="$pane_pid"
      while true; do
        child="$(pgrep -P "$deepest" 2>/dev/null | head -1)"
        [ -n "$child" ] || break
        deepest="$child"
      done
      if [ "$deepest" != "$pane_pid" ]; then
        kill -TERM "$deepest" 2>/dev/null || true
        sleep 0.5
        kill -0 "$deepest" 2>/dev/null && kill -KILL "$deepest" 2>/dev/null
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Registry + pane options (mirrors rw-ensure.sh's shape so this endpoint is
# indistinguishable from an ensured one afterward).
# ---------------------------------------------------------------------------

now="$(rw_now_iso)"
if [ "$reattach" = "true" ]; then
  created_at="$(printf '%s' "$endpoint_json" | jq -r '.created_at // empty')"
  [ -n "$created_at" ] || created_at="$now"
  prior_generation="$(printf '%s' "$endpoint_json" | jq -r '.generation // 0')"
else
  created_at="$now"
  prior_generation=0
fi
registry_generation=$((prior_generation + 1))

# Managed-writer state for the duplicate-writer guard above: "handed-off"
# only when this endpoint genuinely became (or remains) an active managed
# writer for this session -- i.e. the remote resume verifiably started.
# Every other outcome (workspace-only, export/install/resume failures,
# unverified dispatch) leaves no active remote copy of this session, so a
# later handoff of the same session_id elsewhere must not be blocked by it.
agent_state="null"
if [ -n "$agent_provider" ] && [ "$agent_outcome" = "resumed" ]; then
  agent_state="handed-off"
fi

registry_json="$(jq -nc \
  --arg endpoint_id "$endpoint_id" \
  --arg worker "$worker" \
  --arg worker_identity "$(printf '%s' "$preflight_json" | jq -r '.hostname')" \
  --arg focus_machine_id "$(rw_machine_id)" \
  --arg focus_session_uuid "$(rw_pane_get "$pane_id" @rw-session-uuid)" \
  --arg focus_pane_id "$pane_id" \
  --arg workspace_mode "$workspace_mode" \
  --arg workspace_identity "$workspace_identity" \
  --arg focus_path "$cwd" \
  --arg remote_path "$remote_path" \
  --arg launch_worker "$worker" \
  --arg launch_workspace_arg "$workspace_arg" \
  --arg created_at "$created_at" \
  --arg updated_at "$now" \
  --argjson generation "$registry_generation" \
  --argjson sync_generation "$sync_generation" \
  --arg agent_provider "$agent_provider" \
  --arg agent_session_id "$agent_session_id" \
  --arg agent_resume_cmd "$agent_resume_cmd" \
  --arg agent_outcome "$agent_outcome" \
  --argjson divergence_risk "$divergence_risk" \
  --argjson had_claim "$had_claim" \
  --arg agent_state "$agent_state" \
  '{
    endpoint_id: $endpoint_id, worker: $worker, worker_identity: $worker_identity,
    focus_machine_id: $focus_machine_id, focus_session_uuid: $focus_session_uuid,
    focus_pane_id: $focus_pane_id,
    workspace: {identity: $workspace_identity, mode: $workspace_mode, focus_path: $focus_path,
      remote_path: $remote_path,
      sync: {generation: $sync_generation}},
    launch_intent: {worker: $launch_worker, workspace_arg: $launch_workspace_arg},
    agent: (if $agent_provider == "" then {provider: null, session_id: null, resume_intent: null, state: null}
      else {provider: $agent_provider, session_id: $agent_session_id, resume_intent: $agent_resume_cmd,
        outcome: $agent_outcome, divergence_risk: $divergence_risk, had_claim: $had_claim,
        state: (if $agent_state == "null" then null else $agent_state end)} end),
    created_at: $created_at, updated_at: $updated_at, generation: $generation
  }')"

# Preserve the sync core's own workspace.sync bookkeeping (generation,
# fingerprint, ...) written directly onto this same endpoint file by
# libexec/sync/handoff -- re-merge it in rather than clobbering.
if [ "$local_is_git" = "true" ]; then
  merged="$(rw_read_endpoint "$endpoint_id" 2>/dev/null | jq -c '.workspace.sync // empty')"
  [ -n "$merged" ] && [ "$merged" != "null" ] &&
    registry_json="$(printf '%s' "$registry_json" | jq -c --argjson sync "$merged" '.workspace.sync = $sync')"
fi

rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$registry_json"

rw_pane_set "$pane_id" @rw-endpoint "$endpoint_id"
rw_pane_set "$pane_id" @rw-worker "$worker"
rw_pane_set "$pane_id" @rw-workspace "$remote_path"
rw_pane_set "$pane_id" @remote-host "$worker"
rw_pane_set "$pane_id" @workspace-resurrect-skip "1"

duration_ms="$(rw_elapsed_ms "$handoff_start_ts")"
rw_log_event "handoff" "$endpoint_id" "$worker" "$duration_ms" "success" \
  "generation=$sync_generation agent=${agent_provider:-none} agent_outcome=$agent_outcome keep_local=$keep_local"

# The attach loop must own the TARGET pane's tty. When --pane named a pane
# other than the calling one, exec-ing here would hijack the CALLER's
# terminal instead (smoke lane w5: pane Y got attached, and closing pane
# X's endpoint later collaterally killed Y) -- respawn the target pane
# into the loop in that case.
if [ "$pane_id" = "${TMUX_PANE:-}" ]; then
  exec "$SCRIPT_DIR/attach-loop.sh" "$endpoint_id" --fresh
else
  # respawn-pane -k kills whatever the target pane is running. Only safe
  # when that is a plain shell: with --keep-local, or when the source stop
  # could not be verified, the pane may still hold the RUNNING source
  # agent, and respawning would destroy the only live copy (smoke lane
  # w5r: "source untouched" message was false for exactly this reason).
  target_pane_cmd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
  case "$target_pane_cmd" in
    zsh | bash | sh | fish | -zsh | -bash)
      tmux respawn-pane -k -t "$pane_id" "$SCRIPT_DIR/attach-loop.sh '$endpoint_id' --fresh" 2>/dev/null ||
        rw_warn "rw handoff: could not start the attach loop in pane $pane_id -- attach manually with: $SCRIPT_DIR/attach-loop.sh $endpoint_id"
      ;;
    *)
      rw_warn "rw handoff: pane $pane_id still runs '$target_pane_cmd' (possibly the source agent) -- NOT respawning it into the attach loop. Attach manually with: $SCRIPT_DIR/attach-loop.sh $endpoint_id"
      ;;
  esac
fi
