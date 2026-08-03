#!/usr/bin/env bash
# `rw ensure` -- idempotent establish/re-establish of a durable remote
# endpoint for the CURRENT pane. See initial-plan.md, "Resolved decisions" #5:
# there is no separate attach/reconnect verb; ensure is idempotent and
# re-running it against a pane that already has a live endpoint revalidates
# and reattaches instead of creating a second one.
#
# Usage: rw-ensure.sh --worker <alias> [--workspace <path>|auto]
#
# On success this script `exec`s into attach-loop.sh -- it never returns to
# its caller when setup succeeds. It only returns (with the shell left
# intact) when preflight/workspace resolution fails, so a split pane that
# tried to inherit a remote context is not left dead.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/../libexec/sync"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# Sourced only for rw_sync_worktree_claim_bin/rw_sync_claim_marker_name (the
# claim checkpoint below) -- re-sources scripts/common.sh harmlessly.
# shellcheck source-path=SCRIPTDIR/../libexec/sync
# shellcheck source=../libexec/sync/common.sh
source "$SYNC_DIR/common.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

worker=""
workspace_arg="auto"
while [ $# -gt 0 ]; do
  case "$1" in
    --worker) worker="${2:?}"; shift 2 ;;
    --workspace) workspace_arg="${2:?}"; shift 2 ;;
    *) rw_die "rw ensure: unknown argument: $1" 64 ;;
  esac
done

pane_id="${TMUX_PANE:-}"
[ -n "$pane_id" ] || rw_die "rw ensure: must be run inside a tmux pane (TMUX_PANE is unset)"

existing_endpoint="$(rw_pane_get "$pane_id" @rw-endpoint)"
existing_worker="$(rw_pane_get "$pane_id" @rw-worker)"

reattach="false"
if [ -n "$existing_endpoint" ] && rw_endpoint_exists "$existing_endpoint" &&
  { [ -z "$worker" ] || [ "$worker" = "$existing_worker" ]; }; then
  reattach="true"
  worker="$existing_worker"
fi

[ -n "$worker" ] || rw_die "rw ensure: --worker is required (no existing endpoint on this pane to reattach)"
rw_worker_known "$worker" || rw_die "rw ensure: worker '$worker' is not declared in config.json"

start_ts="$(rw_now_epoch)"

cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || pwd)"

# ---------------------------------------------------------------------------
# Claim checkpoint (initial-plan.md, "Worktree claims and editing ownership",
# Enforcement surface 1: "Tmux and handoff commands: claim, handoff, return,
# endpoint launch, and release operations validate both responsibility and
# host. These are hard failures on mismatch."). Cheap and local-only (no ssh
# round trip, runs before preflight): a single verify-writer call, only when
# the resolved LOCAL workspace is a git worktree that actually has a claim
# marker, and only when the binary is on PATH -- claims are optional, so a
# missing binary or an unclaimed worktree both proceed silently.
# ---------------------------------------------------------------------------

claim_bin="$(rw_sync_worktree_claim_bin)"
if [ -n "$claim_bin" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  local_worktree_root="$(git -C "$cwd" rev-parse --show-toplevel)"
  if [ -f "$local_worktree_root/$(rw_sync_claim_marker_name)" ]; then
    claim_verify_err="$(mktemp "${TMPDIR:-/tmp}/rw-ensure-claim.XXXXXX")"
    "$claim_bin" verify-writer --path "$local_worktree_root" >/dev/null 2>"$claim_verify_err"
    claim_verify_status=$?
    case "$claim_verify_status" in
      0 | 12 | 14) : ;; # ok / no stable session identity (advisory here) / no existing claim
      10 | 11 | 13)
        rw_warn "rw ensure: worktree-claim blocks endpoint launch for '$local_worktree_root' (exit $claim_verify_status):"
        rw_warn "$(cat "$claim_verify_err")"
        rm -f "$claim_verify_err"
        exit 1
        ;;
      *)
        rw_warn "rw ensure: worktree-claim verify-writer failed unexpectedly (exit $claim_verify_status); proceeding. $(cat "$claim_verify_err")"
        ;;
    esac
    rm -f "$claim_verify_err"
  fi
fi

# Git-host auth preflight (Enforcement/"Consume, never provision"): pass the
# local repo's origin remote, when this pane resolves to one, so
# preflight.sh can add its worker-side git-host authentication check.
cwd_repo_remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
preflight_args=(--worker "$worker")
[ -n "$cwd_repo_remote" ] && preflight_args+=(--repo-remote "$cwd_repo_remote")

preflight_json="$("$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}")"
preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  # preflight.sh already printed an actionable message naming setup-headless.
  exit 1
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"

if [ "$reattach" = "true" ]; then
  endpoint_id="$existing_endpoint"
  endpoint_json="$(rw_read_endpoint "$endpoint_id")"
  remote_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.remote_path')"
  workspace_mode="$(printf '%s' "$endpoint_json" | jq -r '.workspace.mode')"
  workspace_identity="$(printf '%s' "$endpoint_json" | jq -r '.workspace.identity')"
  generation="$(printf '%s' "$endpoint_json" | jq -r '.generation // 0')"
  generation=$((generation + 1))
else
  resolution="$("$SCRIPT_DIR/resolve-workspace.sh" \
    --cwd "$cwd" --worker "$worker" --worker-home "$worker_home" --workspace "$workspace_arg")" ||
    rw_die "rw ensure: workspace resolution failed"

  workspace_mode="$(printf '%s' "$resolution" | jq -r '.mode')"
  workspace_identity="$(printf '%s' "$resolution" | jq -r '.identity')"
  remote_path="$(printf '%s' "$resolution" | jq -r '.remote_path')"
  needs_clone="$(printf '%s' "$resolution" | jq -r '.needs_clone')"
  clone_url="$(printf '%s' "$resolution" | jq -r '.clone_url')"

  if [ "$needs_clone" = "true" ]; then
    if [ -z "$clone_url" ]; then
      rw_die "rw ensure: could not determine a git remote to clone for an ad hoc workspace at '$cwd'"
    fi
    parent_dir="$(dirname "$remote_path")"
    if ! rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" \
      "mkdir -p '$parent_dir' && [ -d '$remote_path/.git' ] || git clone '$clone_url' '$remote_path'" \
      >/dev/null 2>"$(mktemp "${TMPDIR:-/tmp}/rw-clone-err.XXXXXX")"; then
      rw_die "rw ensure: ad hoc clone of '$clone_url' onto '$worker' failed -- likely the worker's own SSH key is not registered with the git host (setup-headless generates a worker key; registering it with GitHub/GitLab is a manual step)."
    fi
  fi

  endpoint_id="$(rw_new_short_id)"
  generation=1
fi

session_name="$(rw_session_name "$endpoint_id")"

session_exists="$(rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" \
  "tmux has-session -t '$session_name' 2>/dev/null && echo yes || echo no" 2>/dev/null || echo no)"

# Tracked so attach-loop.sh can be told this session was JUST (re)created in
# this very invocation -- see attach-loop.sh's --fresh handling: a "session
# absent" reading on its very first check is then a transient race, never a
# remote-intentional-close, because we ourselves confirmed/created it a
# moment ago.
just_created="false"
if [ "$session_exists" != "yes" ]; then
  rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)" ||
    rw_die "rw ensure: failed to create remote endpoint session '$session_name' on '$worker'"
  just_created="true"
fi

session_uuid="$(rw_pane_get "$pane_id" @rw-session-uuid)"
if [ -z "$session_uuid" ]; then
  session_uuid="$(tmux show-option -t "$pane_id" -qv @session-uuid 2>/dev/null || true)"
fi
window_index="$(tmux display-message -pt "$pane_id" -F '#{window_index}' 2>/dev/null || echo 0)"
pane_index="$(tmux display-message -pt "$pane_id" -F '#{pane_index}' 2>/dev/null || echo 0)"

now="$(rw_now_iso)"
created_at="$now"
if [ "$reattach" = "true" ]; then
  created_at="$(printf '%s' "$endpoint_json" | jq -r '.created_at // empty')"
  [ -n "$created_at" ] || created_at="$now"
fi

registry_json="$(jq -nc \
  --arg endpoint_id "$endpoint_id" \
  --arg worker "$worker" \
  --arg worker_identity "$(printf '%s' "$preflight_json" | jq -r '.hostname')" \
  --arg focus_machine_id "$(rw_machine_id)" \
  --arg focus_session_uuid "$session_uuid" \
  --argjson focus_window_index "${window_index:-0}" \
  --argjson focus_pane_index "${pane_index:-0}" \
  --arg focus_pane_id "$pane_id" \
  --arg workspace_mode "$workspace_mode" \
  --arg workspace_identity "$workspace_identity" \
  --arg focus_path "$cwd" \
  --arg remote_path "$remote_path" \
  --arg launch_worker "$worker" \
  --arg launch_workspace_arg "$workspace_arg" \
  --arg created_at "$created_at" \
  --arg updated_at "$now" \
  --argjson generation "$generation" \
  '{
    endpoint_id: $endpoint_id,
    worker: $worker,
    worker_identity: $worker_identity,
    focus_machine_id: $focus_machine_id,
    focus_session_uuid: $focus_session_uuid,
    focus_window_index: $focus_window_index,
    focus_pane_index: $focus_pane_index,
    focus_pane_id: $focus_pane_id,
    workspace: {
      identity: $workspace_identity,
      mode: $workspace_mode,
      focus_path: $focus_path,
      remote_path: $remote_path
    },
    launch_intent: {
      worker: $launch_worker,
      workspace_arg: $launch_workspace_arg
    },
    agent: {
      provider: null,
      session_id: null,
      resume_intent: null
    },
    created_at: $created_at,
    updated_at: $updated_at,
    generation: $generation
  }')"

rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$registry_json"

rw_pane_set "$pane_id" @rw-endpoint "$endpoint_id"
rw_pane_set "$pane_id" @rw-worker "$worker"
rw_pane_set "$pane_id" @rw-workspace "$remote_path"
rw_pane_set "$pane_id" @remote-host "$worker"
[ -n "$session_uuid" ] && rw_pane_set "$pane_id" @rw-session-uuid "$session_uuid"

# Opt this pane out of tmux-workspace-resurrect's command replay so a
# restore never pastes a stale `ssh worker` command into a pane this plugin
# now manages. See initial-plan.md, "Local restore of remote attachments".
rw_pane_set "$pane_id" @workspace-resurrect-skip "1"

duration_ms="$(rw_elapsed_ms "$start_ts")"
rw_log_event "$([ "$reattach" = "true" ] && echo reattach || echo create)" \
  "$endpoint_id" "$worker" "$duration_ms" "success" "mode=$workspace_mode"

if [ "$just_created" = "true" ]; then
  exec "$SCRIPT_DIR/attach-loop.sh" "$endpoint_id" --fresh
fi
exec "$SCRIPT_DIR/attach-loop.sh" "$endpoint_id"
