#!/usr/bin/env bash
# `rw return` -- mirror of `rw handoff`: bring a remote-backed pane's
# workspace (and agent, if one was handed off) back to the focus machine.
#
# Always runs on the focus machine, on the SAME pane that was previously
# handed off (identified by its @rw-endpoint). It is the "pull" side of the
# same transactional transfer core: source = the worker's remote_path
# (reached only through the exec wrapper), dest = the ORIGINAL local
# worktree recorded at handoff time (this process's own filesystem). See
# libexec/sync/handoff's `--pull` flag and libexec/sync/README.md.
#
# Ordering (mirrors initial-plan.md's 5-step handoff ordering):
#   1. Preflight the worker; a failure aborts, remote agent/workspace
#      untouched.
#   2. Transfer the workspace back (shared safety model: destination
#      backup, divergence check, staging, verify -- identical code path to
#      `rw handoff`, just pulled instead of pushed).
#   3. If an agent was handed off, export/install its session locally and
#      resume it in THIS pane.
#   4. Stop the remote agent (default) only after the local resume has
#      started. `--keep-remote` skips this and records divergence risk.
#   5. Release the writer back to the focus host via `worktree-claim
#      return-writer` (claims are optional; skipped cleanly when absent).
#
# Usage: rw-return.sh [--pane <pane-id>] [--keep-remote] [--check-lfs]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/../libexec/sync"
ADAPTERS_DIR="$SCRIPT_DIR/../libexec/adapters"
# shellcheck source-path=SCRIPTDIR/../libexec/sync
# shellcheck source=../libexec/sync/common.sh
source "$SYNC_DIR/common.sh"

rw_need_jq

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

pane_id="${TMUX_PANE:-}"
keep_remote="false"
check_lfs="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --pane) pane_id="${2:?}"; shift 2 ;;
    --keep-remote) keep_remote="true"; shift ;;
    --check-lfs) check_lfs="true"; shift ;;
    *) rw_die "rw return: unknown argument: $1" 64 ;;
  esac
done

[ -n "$pane_id" ] || rw_die "rw return: must be run inside a tmux pane, or pass --pane explicitly (TMUX_PANE is unset)"

endpoint_id="$(rw_pane_get "$pane_id" @rw-endpoint)"
[ -n "$endpoint_id" ] || rw_die "rw return: pane $pane_id has no @rw-endpoint -- nothing to return (it was never handed off/ensured)."
endpoint_json="$(rw_read_endpoint "$endpoint_id")" || rw_die "rw return: endpoint '$endpoint_id' has no registry entry (already closed?)."

worker="$(printf '%s' "$endpoint_json" | jq -r '.worker')"
remote_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.remote_path')"
focus_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.focus_path')"
workspace_mode="$(printf '%s' "$endpoint_json" | jq -r '.workspace.mode')"
agent_provider="$(printf '%s' "$endpoint_json" | jq -r '.agent.provider // empty')"
agent_session_id="$(printf '%s' "$endpoint_json" | jq -r '.agent.session_id // empty')"
had_claim="$(printf '%s' "$endpoint_json" | jq -r '.agent.had_claim // false')"
prior_divergence_risk="$(printf '%s' "$endpoint_json" | jq -r '.agent.divergence_risk // false')"

rw_worker_known "$worker" || rw_die "rw return: worker '$worker' (recorded on this endpoint) is not declared in config.json"

return_start_ts="$(rw_now_epoch)"

# ---------------------------------------------------------------------------
# Step 1: preflight. A failure aborts with nothing touched on either side.
# ---------------------------------------------------------------------------

# Git-host auth preflight: focus_path is the ORIGINAL local worktree
# (already on disk from the original handoff) -- pass its origin remote
# along, when it has one, so preflight.sh adds its worker-side git-host
# authentication check.
focus_repo_remote="$(git -C "$focus_path" remote get-url origin 2>/dev/null || true)"
preflight_args=(--worker "$worker" --check-lfs)
[ -n "$focus_repo_remote" ] && preflight_args+=(--repo-remote "$focus_repo_remote")

preflight_status=0
# Discarded on purpose: unlike `rw handoff`, the destination for a return is
# always this (focus) machine's own $HOME -- libexec/sync/handoff's default
# backup/staging root is already correct without needing preflight's worker
# `.home` field.
"$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}" >/dev/null || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  rw_log_event "return" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$return_start_ts")" "fail" "preflight_failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 (continued): agent version policy -- mirror image of
# rw-handoff.sh's Step 1 version check, run here (before anything is
# touched) for the same reason: a version block must abort with nothing
# transferred, not after a workspace transfer has already run.
#
# `versions --worker <worker>` always compares THIS (local) machine's own
# CLI against the given worker's, i.e. exactly the local-vs-worker pair
# needed here too; only the blocking direction is inverted for a return:
# - policy "newer_worker" from that call means the worker's CLI is newer
#   than local's -- for a HANDOFF that's fine (worker resumes), but for a
#   RETURN it means LOCAL is the older CLI about to resume a transcript the
#   worker's newer CLI may have written in a newer format -- this is
#   return's block condition (same exit-3 semantics, remediation aimed at
#   the local install instead of the worker's).
# - an exit-3 "blocked" result from that call means the worker is older
#   than local -- for a RETURN that's safe (local is newer or equal
#   resuming an older-worker transcript), so it proceeds with a notice
#   instead (mirror of the newer-worker-proceeds branch).
# ---------------------------------------------------------------------------

if [ -n "$agent_provider" ] && [ -n "$agent_session_id" ] && [ -x "$ADAPTERS_DIR/$agent_provider" ]; then
  version_err="$(mktemp "${TMPDIR:-/tmp}/rw-return-versions.XXXXXX")"
  version_status=0
  version_json="$("$ADAPTERS_DIR/$agent_provider" versions --worker "$worker" 2>"$version_err")" || version_status=$?
  if [ "$version_status" -eq 0 ]; then
    version_policy="$(printf '%s' "$version_json" | jq -r '.policy // empty' 2>/dev/null)"
    if [ "$version_policy" = "newer_worker" ]; then
      rw_warn "rw return: $agent_provider version policy blocks this return -- local CLI is older than the worker's that authored this transcript. This plugin never updates itself -- update the LOCAL $agent_provider install (e.g. the same command rw-handoff.sh would print for the reverse direction) and retry."
      rw_log_event "return" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$return_start_ts")" "fail" "agent_version_blocked:$agent_provider"
      rm -f "$version_err"
      exit 1
    fi
  elif [ "$version_status" -eq 3 ]; then
    rw_warn "rw return: notice -- local $agent_provider is newer than the worker's; proceeding (mirror image of the newer-worker-proceeds policy). $(cat "$version_err")"
  else
    rw_warn "rw return: $agent_provider versions check failed unexpectedly (exit $version_status); proceeding with resume anyway. $(cat "$version_err")"
  fi
  rm -f "$version_err"
fi

# ---------------------------------------------------------------------------
# Step 2: workspace transfer back (worker -> focus_path). Skipped for a
# non-git plain-directory workspace, same as `rw handoff`.
# ---------------------------------------------------------------------------

local_is_git="false"
sync_generation="$(printf '%s' "$endpoint_json" | jq -r '.workspace.sync.generation // 0')"
if [ "$workspace_mode" != "plain" ] || git -C "$focus_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  local_is_git="true"
fi

if [ "$local_is_git" = "true" ]; then
  sync_args=(sync --direction return --pull
    --source-path "$remote_path" --dest-path "$focus_path"
    --dest-mode ssh --dest-worker "$worker"
    --endpoint "$endpoint_id")
  [ "$check_lfs" = "true" ] && sync_args+=(--check-lfs)

  sync_err_file="$(mktemp "${TMPDIR:-/tmp}/rw-return-sync.XXXXXX")"
  sync_status=0
  sync_result="$("$SYNC_DIR/handoff" "${sync_args[@]}" 2>"$sync_err_file")" || sync_status=$?
  if [ "$sync_status" -ne 0 ]; then
    rw_warn "rw return: workspace transfer failed (exit $sync_status):"
    rw_warn "$(cat "$sync_err_file")"
    rm -f "$sync_err_file"
    exit 1
  fi
  rm -f "$sync_err_file"
  sync_generation="$(printf '%s' "$sync_result" | jq -r '.generation')"
fi

# ---------------------------------------------------------------------------
# Claim: release the writer back to this (focus) host, AFTER the transfer
# so any marker that just arrived from the worker is already on disk and
# available for wt_sync_claim_from_marker to adopt-if-newer before this
# call's own flip. Skipped cleanly when there is no claim.
# ---------------------------------------------------------------------------

claim_bin="$(rw_sync_worktree_claim_bin)"
if [ "$local_is_git" = "true" ] && { [ "$had_claim" = "true" ] || [ -f "$focus_path/$(rw_sync_claim_marker_name)" ]; } && [ -n "$claim_bin" ]; then
  claim_out_file="$(mktemp "${TMPDIR:-/tmp}/rw-return-claim.XXXXXX")"
  if ! "$claim_bin" return-writer --path "$focus_path" >"$claim_out_file" 2>&1; then
    claim_status=$?
    rw_warn "rw return: worktree-claim return-writer failed (exit $claim_status): $(cat "$claim_out_file") -- workspace content was already returned; resolve the claim manually with 'worktree-claim status --path $focus_path'."
  fi
  rm -f "$claim_out_file"
fi

# ---------------------------------------------------------------------------
# Steps 3/4: resume the agent locally (if one was handed off), then stop
# the remote copy by default. Lineage note: when the original handoff
# recorded divergence_risk (the local agent was kept running with
# --keep-local), the local resume uses the adapter's provider-native
# `resume-cmd --fork` instead of a plain resume -- forking preserves both
# lineages (initial-plan.md: "adapters lean on provider-native forking ...
# rather than building bespoke copy-and-track bookkeeping"). The remote
# lineage is deliberately left running/backed up either way, never
# auto-stopped, since both lineages are being kept.
# ---------------------------------------------------------------------------

agent_outcome="not_attempted"
remote_stopped="false"
if [ -n "$agent_provider" ] && [ -n "$agent_session_id" ]; then
  adapter="$ADAPTERS_DIR/$agent_provider"
  if [ ! -x "$adapter" ]; then
    rw_warn "rw return: adapter for '$agent_provider' is not installed locally; workspace was returned, agent resume skipped."
    agent_outcome="adapter_missing"
  else
    # Version policy was already checked and enforced in Step 1 (continued),
    # above, before the workspace transfer ran.
    export_dir="$(mktemp -d "${TMPDIR:-/tmp}/rw-return-agent-export.XXXXXX")"
    export_err="$(mktemp "${TMPDIR:-/tmp}/rw-return-agent.XXXXXX")"
    if ! "$adapter" export --session-id "$agent_session_id" --project-path "$remote_path" --out "$export_dir" --worker "$worker" 2>"$export_err"; then
      rw_warn "rw return: $agent_provider export from '$worker' failed; workspace was returned, agent resume skipped. $(cat "$export_err")"
      agent_outcome="export_failed"
    elif ! "$adapter" install --snapshot "$export_dir" --dest-path "$focus_path" 2>"$export_err"; then
      rw_warn "rw return: $agent_provider install locally failed; workspace was returned, agent resume skipped. $(cat "$export_err")"
      agent_outcome="install_failed"
    else
      resume_cmd_args=(resume-cmd --dest-path "$focus_path" --session-id "$agent_session_id")
      fork_used="false"
      if [ "$prior_divergence_risk" = "true" ]; then
        resume_cmd_args+=(--fork)
        fork_used="true"
      fi
      resume_status=0
      agent_resume_cmd="$("$adapter" "${resume_cmd_args[@]}" 2>"$export_err")" || resume_status=$?
      if [ "$resume_status" -ne 0 ]; then
        rw_warn "rw return: $agent_provider resume-cmd failed (exit $resume_status); workspace was returned, agent resume skipped. $(cat "$export_err")"
        agent_outcome="resume_gated"
      else
        # Dispatch, then verify the local resume actually started before
        # stopping the remote copy (initial-plan.md step 4, mirrored: never
        # stop the OTHER side's agent until THIS side's resume has
        # verifiably started).
        if ! tmux send-keys -t "$pane_id" "$agent_resume_cmd" Enter 2>"$export_err"; then
          rw_warn "rw return: failed to dispatch the $agent_provider resume command into this pane: $(cat "$export_err")"
          rw_warn "rw return: the remote $agent_provider session was NOT stopped -- it is still running, untouched."
          agent_outcome="resume_dispatch_failed"
          rw_log_event "return" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$return_start_ts")" "fail" "agent_resume_dispatch_failed:$agent_provider"
        elif ! rw_wait_local_provider_started "$pane_id" "$agent_provider"; then
          rw_warn "rw return: dispatched the $agent_provider resume command locally but could not confirm the $agent_provider process started in this pane after polling."
          rw_warn "rw return: the remote $agent_provider session was NOT stopped -- it is still running, untouched."
          agent_outcome="resume_unverified"
          rw_log_event "return" "$endpoint_id" "$worker" "$(rw_elapsed_ms "$return_start_ts")" "fail" "agent_resume_unverified:$agent_provider"
        elif [ "$fork_used" = "true" ]; then
          agent_outcome="resumed_forked"
          rw_warn "rw return: this endpoint was handed off with --keep-local, so the local and remote $agent_provider sessions may have diverged. Resumed locally using --fork ($agent_provider's own provider-native forking) to preserve both lineages. The remote session on '$worker' is left running and backed up -- it is NOT stopped automatically; stop it manually once you've reconciled."
        else
          agent_outcome="resumed"
          if [ "$keep_remote" != "true" ]; then
            session_name="$(rw_session_name "$endpoint_id")"
            rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
              "tmux send-keys -t '$session_name' C-c" >/dev/null 2>&1 || true
            remote_stopped="true"
          else
            rw_warn "rw return: --keep-remote -- the remote $agent_provider session keeps running; transcript divergence risk recorded."
          fi
        fi
      fi
    fi
    rm -rf "$export_dir"
    rm -f "$export_err"
  fi
fi

# ---------------------------------------------------------------------------
# Release the pane's remote-endpoint state: a returned pane is local again.
# The remote endpoint session/registry entry are intentionally NOT torn
# down here (that is `rw close`'s job, on a separate explicit decision) --
# `rw return` only stops being the active writer, it does not delete the
# worker-side session, so a subsequent `rw handoff` can reuse it.
# ---------------------------------------------------------------------------

now="$(rw_now_iso)"
registry_json="$(printf '%s' "$endpoint_json" | jq -c \
  --arg now "$now" \
  --argjson sync_generation "$sync_generation" \
  --arg agent_outcome "$agent_outcome" \
  --argjson keep_remote "$([ "$keep_remote" = "true" ] && echo true || echo false)" \
  --argjson remote_stopped "$([ "$remote_stopped" = "true" ] && echo true || echo false)" \
  '.updated_at = $now
   | .workspace.sync.generation = $sync_generation
   | .agent.outcome = $agent_outcome
   | .agent.divergence_risk = $keep_remote
   | (if $remote_stopped then .agent.state = "returned" else . end)
   | .generation = ((.generation // 0) + 1)')"
rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$registry_json"

rw_pane_unset "$pane_id" @rw-endpoint
rw_pane_unset "$pane_id" @rw-worker
rw_pane_unset "$pane_id" @rw-workspace
rw_pane_unset "$pane_id" @remote-host
rw_pane_unset "$pane_id" @workspace-resurrect-skip

duration_ms="$(rw_elapsed_ms "$return_start_ts")"
rw_log_event "return" "$endpoint_id" "$worker" "$duration_ms" "success" \
  "generation=$sync_generation agent=${agent_provider:-none} agent_outcome=$agent_outcome keep_remote=$keep_remote"

printf 'rw: returned %s from %s to %s (generation %s)\n' "$endpoint_id" "$worker" "$focus_path" "$sync_generation"
if [ "$local_is_git" = "true" ] && [ -d "$focus_path" ]; then
  cd "$focus_path" 2>/dev/null || true
fi
exec "${SHELL:-bash}" -l
