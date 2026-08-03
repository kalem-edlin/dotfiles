#!/usr/bin/env bash
# Attach/reconnect loop for one remote endpoint. Runs as the pane's foreground
# process (rw-ensure.sh `exec`s into this; rw-post-restore.sh `respawn-pane`s
# into this after a laptop resurrection). Not invoked as a separate `rw`
# subcommand -- see initial-plan.md Resolved decision #5.
#
# Usage: attach-loop.sh <endpoint-id> [--fresh]
#
#   --fresh   The caller (rw-ensure.sh) confirmed/created this endpoint's
#             remote session in this SAME invocation, moments ago. Only
#             affects the very first loop iteration: a "session absent"
#             reading there is treated as a transient race and retried,
#             never as a remote-intentional-close or a rebuild trigger (see
#             "First-ever attach" below). Never passed by rw-post-restore.sh,
#             which cannot make that guarantee about a session that may have
#             existed for a long time already.
#
# Before EVERY reconnect this loop determines actual remote state over ssh,
# rather than blindly running `tmux new-session -A` (which would silently
# recreate a session an operator intentionally killed directly on the
# worker, forever). See initial-plan.md, "Endpoint lifetime follows user
# intent": "Directly killing the remote endpoint is also intentional and
# must be reconciled back into the focus registry instead of being
# recreated forever."
#
# Branches, from a single cheap status probe over ssh each iteration:
#   (a) worker unreachable            -> ordinary drop: backoff, retry.
#   (b) server up, session EXISTS     -> plain attach (the steady-state case).
#   (c) server up, session ABSENT     -> remote-intentional-close: write a
#                                         tombstone, log it, notify this pane
#                                         only, exit the loop and close it.
#   (d) no tmux server on the worker  -> infrastructure loss: ask the
#                                         worker's own tmux-resurrect
#                                         installation to restore
#                                         (non-interactively, same entrypoint
#                                         setup-headless's save timer's
#                                         wrapper documents as $TMUX-unset
#                                         safe), recheck, and if the session
#                                         is still absent, rebuild it from
#                                         the registry manifest exactly as
#                                         `rw ensure` would (initial-plan.md,
#                                         "Local restore of remote
#                                         attachments", steps 3-5).
#
# Also still distinguishes a LOCAL intentional close (tombstone/registry
# entry gone, e.g. `rw close` run concurrently) from all of the above --
# checked before every remote probe and again right after every attach
# attempt returns.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

endpoint_id="${1:?attach-loop: endpoint id required}"
shift
fresh="false"
if [ "${1:-}" = "--fresh" ]; then
  fresh="true"
fi

pane_id="${TMUX_PANE:-}"

backoff_seconds=1
backoff_cap=30
attempt=0

status() {
  # Unobtrusive: only touch the pane's own display, never another pane/TUI.
  [ -n "$pane_id" ] || return 0
  tmux display-message -pt "$pane_id" -F "rw: $1" 2>/dev/null || true
}

intentional_close() {
  rw_tombstone_exists "$endpoint_id" && return 0
  rw_endpoint_exists "$endpoint_id" || return 0
  return 1
}

reset_local_terminal() {
  # Known artifact: an unclean inner-session end can leave the outer pane
  # with garbled mouse state because the nested tmux never sent its cleanup
  # sequences. Reset/redraw on the way back out.
  printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l' 2>/dev/null || true
  reset -I >/dev/null 2>&1 || true
  [ -n "$pane_id" ] && tmux refresh-client 2>/dev/null || true
}

exit_intentional_close() {
  echo "rw: endpoint $endpoint_id was intentionally closed; exiting."
  [ -n "$pane_id" ] && tmux kill-pane -t "$pane_id" 2>/dev/null
  exit 0
}

# remote_state <worker> <session_name>
# Prints exactly one of: unreachable | no-server | session-absent |
# session-present. A single short-timeout ssh round trip (multiplexed via
# ControlMaster/ControlPersist -- ssh/.ssh/config -- so this is cheap on top
# of the plain attach that normally follows it). The remote inline script
# always itself exits 0 on success (every branch ends in `echo`), so ssh's
# own exit status reflects connectivity only, never tmux's internal
# has-session result.
remote_state() {
  local worker="$1" session_name="$2" out status
  out="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "
    if ! tmux list-sessions >/dev/null 2>&1; then
      echo no-server
    elif tmux has-session -t '=${session_name}' 2>/dev/null; then
      echo session-present
    else
      echo session-absent
    fi
  " 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$out" ]; then
    printf 'unreachable\n'
  else
    printf '%s\n' "$out"
  fi
}

# ask_worker_to_restore_then_recheck <worker> <session_name>
# Case (d), steps 3-4 of "Local restore of remote attachments": start the
# worker's tmux server and ask its own tmux-resurrect installation to
# restore non-interactively, then recheck for our specific session. Prints
# "yes" or "no". The worker runs the same dotfiles, so its tmux-resurrect
# plugin lives at the same relative path as ours
# ($HOME/.config/tmux/plugins/tmux-resurrect) -- the exact path
# setup/templates/tmux-resurrect-save.sh already assumes and documents as
# safe to invoke with $TMUX unset (verified 2026-07-31, see that script's
# header). A missing restore.sh (worker not using tmux-resurrect) or a
# restore.sh failure is not fatal here -- the recheck below is authoritative
# either way, and a still-absent session falls through to the manifest
# rebuild.
ask_worker_to_restore_then_recheck() {
  local worker="$1" session_name="$2"
  rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" "
    tmux start-server 2>/dev/null
    resurrect_restore=\"\$HOME/.config/tmux/plugins/tmux-resurrect/scripts/restore.sh\"
    if [ -f \"\$resurrect_restore\" ]; then
      TMUX='' bash \"\$resurrect_restore\" >/dev/null 2>&1 || true
    fi
    tmux has-session -t '=${session_name}' 2>/dev/null && echo yes || echo no
  " 2>/dev/null
}

while true; do
  if intentional_close; then
    exit_intentional_close
  fi

  endpoint_json="$(rw_read_endpoint "$endpoint_id")" || {
    echo "rw: endpoint $endpoint_id has no registry entry; exiting."
    [ -n "$pane_id" ] && tmux kill-pane -t "$pane_id" 2>/dev/null
    exit 0
  }
  worker="$(printf '%s' "$endpoint_json" | jq -r '.worker')"
  remote_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.remote_path')"
  session_name="$(rw_session_name "$endpoint_id")"

  event="attach"
  is_first_iteration="false"
  if [ "$attempt" -eq 0 ]; then
    is_first_iteration="true"
  else
    event="reconnect"
  fi
  attempt=$((attempt + 1))

  echo "rw: checking $worker ($session_name), attempt $attempt..."
  rw_pane_set "$pane_id" @remote-host "$worker"

  probe_start_ts="$(rw_now_epoch)"
  state="$(remote_state "$worker" "$session_name")"

  case "$state" in
    unreachable)
      duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
      rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "drop" "unreachable"
      status "reconnecting to $worker in ${backoff_seconds}s..."
      sleep "$backoff_seconds"
      backoff_seconds=$((backoff_seconds * 2))
      [ "$backoff_seconds" -gt "$backoff_cap" ] && backoff_seconds="$backoff_cap"
      continue
      ;;
    no-server)
      if [ "$fresh" = "true" ] && [ "$is_first_iteration" = "true" ]; then
        # rw-ensure.sh confirmed/created this session moments ago in this
        # same invocation. A "no server at all" reading right now is a
        # transient race, not real infrastructure loss -- don't guess,
        # just retry (never applies past the first iteration).
        duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
        rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "drop" "fresh_race:no-server"
        status "reconnecting to $worker in ${backoff_seconds}s..."
        sleep "$backoff_seconds"
        backoff_seconds=$((backoff_seconds * 2))
        [ "$backoff_seconds" -gt "$backoff_cap" ] && backoff_seconds="$backoff_cap"
        continue
      fi
      status "no tmux server on $worker; requesting its own resurrection to restore..."
      recheck="$(ask_worker_to_restore_then_recheck "$worker" "$session_name")"
      duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
      if printf '%s' "$recheck" | grep -q '^yes$'; then
        rw_log_event "worker-restore" "$endpoint_id" "$worker" "$duration_ms" "success" "session recovered via worker resurrection"
      else
        status "rebuilding $session_name on $worker from the endpoint manifest..."
        if rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)"; then
          rw_log_event "rebuild" "$endpoint_id" "$worker" "$duration_ms" "success" "worker resurrection did not recover the session; rebuilt from manifest"
        else
          rw_log_event "rebuild" "$endpoint_id" "$worker" "$duration_ms" "fail" "worker unreachable or rebuild failed"
          status "reconnecting to $worker in ${backoff_seconds}s..."
          sleep "$backoff_seconds"
          backoff_seconds=$((backoff_seconds * 2))
          [ "$backoff_seconds" -gt "$backoff_cap" ] && backoff_seconds="$backoff_cap"
          continue
        fi
      fi
      # Fall through to the plain attach below -- the session now exists.
      ;;
    session-absent)
      if [ "$fresh" = "true" ] && [ "$is_first_iteration" = "true" ]; then
        # Same rationale as the no-server/fresh case above: we just
        # confirmed/created this session ourselves: absence here is a
        # transient race, not evidence of an intentional remote close.
        duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
        rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "drop" "fresh_race:session-absent"
        status "reconnecting to $worker in ${backoff_seconds}s..."
        sleep "$backoff_seconds"
        backoff_seconds=$((backoff_seconds * 2))
        [ "$backoff_seconds" -gt "$backoff_cap" ] && backoff_seconds="$backoff_cap"
        continue
      fi
      # The worker's tmux server is up but our specific endpoint session is
      # gone. Nothing else can do that except a deliberate `tmux
      # kill-session` run directly on the worker -- reconcile it as an
      # intentional close instead of recreating it.
      rw_close_endpoint_core "$endpoint_id" "remote-intentional-close"
      echo "rw: endpoint $endpoint_id was closed directly on $worker; exiting."
      [ -n "$pane_id" ] && tmux kill-pane -t "$pane_id" 2>/dev/null
      exit 0
      ;;
    session-present) : ;; # fall through to the plain attach below
  esac

  start_ts="$(rw_now_epoch)"
  echo "rw: attaching to $worker ($session_name), attempt $attempt..."

  # TERM=screen-256color: the only ssh call here that allocates a PTY, so the
  # only one that forwards TERM. The focus terminal may be one the worker's
  # terminfo has never heard of (ghostty's xterm-ghostty broke agents-roll:
  # every attach died with "missing or unsuitable terminal" and backed off
  # forever). screen-256color is universally present and fine for an outer
  # client whose only job is displaying the remote tmux.
  TERM=screen-256color "$(rw_ssh_bin)" -t \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    "$worker" "tmux attach-session -t '=${session_name}'"
  exit_code=$?
  duration_ms="$(rw_elapsed_ms "$start_ts")"

  reset_local_terminal

  if intentional_close; then
    rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "closed" "exit=$exit_code"
    exit_intentional_close
  fi

  if [ "$exit_code" -eq 0 ] && [ "$duration_ms" -gt 2000 ]; then
    # A session that stayed connected a meaningful amount of time counts as
    # a successful attach; reset backoff so the next drop retries fast.
    rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "success" ""
    backoff_seconds=1
  else
    rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "drop" "exit=$exit_code"
  fi

  status "reconnecting to $worker in ${backoff_seconds}s..."
  sleep "$backoff_seconds"
  backoff_seconds=$((backoff_seconds * 2))
  [ "$backoff_seconds" -gt "$backoff_cap" ] && backoff_seconds="$backoff_cap"
done
