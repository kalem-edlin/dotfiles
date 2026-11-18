#!/usr/bin/env bash
# Attach/reconnect loop for one remote endpoint. Runs as the pane's foreground
# process (rw-open.sh `exec`s into this; rw-post-restore.sh `respawn-pane`s
# into this after a laptop resurrection). Not invoked as a separate `rw`
# subcommand. See docs/tmux-remote-workspaces.md, "Endpoint and state model".
#
# Usage: attach-loop.sh <endpoint-id> [--fresh]
#
#   --fresh   The caller (rw-open.sh) confirmed/created this endpoint's
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
# worker forever). See docs/tmux-remote-workspaces.md, "Intentional close is
# different from a disconnect".
#
# Branches, from a single cheap status probe over ssh each iteration:
#   (a) worker unreachable            -> ordinary drop: backoff, retry.
#   (b) server up, session EXISTS     -> plain attach (the steady-state case).
#   (c) server up, session ABSENT     -> remote-intentional-close: write a
#                                         tombstone, log it, notify this pane
#                                         only, exit the loop and close it.
#   (d) no tmux server on the worker  -> infrastructure loss: run the
#                                         worker's boot restore wrapper
#                                         (setup/templates/tmux-resurrect-restore.sh,
#                                         the same one its LaunchAgent runs:
#                                         guarded restore under the save
#                                         lock, waits on a boot lock so
#                                         concurrent panes never race),
#                                         recheck, and if the session is
#                                         still absent, rebuild it from the
#                                         registry manifest exactly as
#                                         `rw open` would (docs/tmux-remote-workspaces.md,
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

endpoint_id=""
fresh="false"
pane_id="${TMUX_PANE:-}"

backoff_seconds=1
backoff_cap=30
# Retry interval while the worker reports a restore in progress.
restoring_wait=3
attempt=0

# The worker boot restore's bootstrap session
# (setup/templates/tmux-resurrect-restore.sh). While it exists, the worker's
# server is mid-restore and an absent endpoint session means nothing yet.
RW_BOOT_SESSION="_tmux_restore_boot"

status() {
  # The attach loop owns this pane while disconnected, so operational
  # progress belongs in the pane itself—not tmux's command/message row.
  printf 'rw: %s\n' "$1"
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
  forget_server_seen "$endpoint_id"
  echo "rw: endpoint $endpoint_id was intentionally closed; exiting."
  [ -n "$pane_id" ] && tmux kill-pane -t "$pane_id" 2>/dev/null
  exit 0
}

# `rw handback` releases a pane by clearing its @rw-endpoint cache and killing
# this loop's ssh client: the endpoint registry/session survive (close is a
# separate decision), but this pane must fall back to its local shell so the
# return can resume the agent locally in it -- so exit WITHOUT killing the
# pane, unlike an intentional close.
pane_released() {
  [ -n "$pane_id" ] || return 1
  [ "$(rw_pane_get "$pane_id" @rw-endpoint 2>/dev/null || true)" != "$endpoint_id" ]
}

exit_pane_released() {
  # The inner tmux enabled focus-event reporting (and possibly bracketed
  # paste) on this tty; the ssh teardown does not switch them off, so the
  # landing shell gets literal reports typed at it ("^[[I" on focus,
  # observed 2026-08-08). Reset both before handing the tty over.
  printf '\033[?1004l\033[?2004l'
  echo "rw: endpoint $endpoint_id was returned; this pane is local again."
  # This loop is normally the pane's ROOT process (rw-handoff/rw-open
  # exec it, or respawn-pane runs it directly), so a plain exit would KILL
  # the pane -- smoke lane w5r destroyed the target pane in 4/4 cross-pane
  # returns before this. Become the local shell instead, in the endpoint's
  # focus path when it is still known.
  local released_dir=""
  released_dir="$(rw_read_endpoint "$endpoint_id" 2>/dev/null | jq -r '.workspace.focus_path // empty' 2>/dev/null)"
  if [ -n "$released_dir" ] && [ -d "$released_dir" ]; then
    cd "$released_dir" 2>/dev/null || true
  fi
  exec "${SHELL:-bash}" -l
}

# --- Worker server identity ------------------------------------------------
# Whether an absent endpoint session was closed on purpose or lost with its
# server is decided from the worker server instance (start_time and pid, both
# worker-side values) the session was last SEEN on, persisted per endpoint on
# the focus machine so it survives this loop being respawned by a laptop
# restore. Same server instance, session gone: closed on the worker. A
# different instance: the server was lost and rebuilt, recreate. Nothing
# recorded (an endpoint this machine never saw attached since this rule
# existed): never treated as an intentional close.

rw_attach_seen_file() { printf '%s/attach-seen/%s\n' "$(rw_state_dir)" "${1:?endpoint id required}"; }

# record_server_seen <endpoint_id> <start_time> <pid>
record_server_seen() {
  local file value
  case "$2$3" in '' | *[!0-9]*) return 0 ;; esac
  file="$(rw_attach_seen_file "$1")"
  value="$2 $3"
  [ "$(cat "$file" 2>/dev/null)" = "$value" ] && return 0
  rw_ensure_private_dir "$(dirname "$file")"
  printf '%s\n' "$value" >"$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"
}

forget_server_seen() { rm -f "$(rw_attach_seen_file "$1")" 2>/dev/null || true; }

# absent_verdict <endpoint_id> <start_time> <pid>
# Prints `close` (the session vanished from the very server it was last seen
# on) or `recreate` (a different server instance, or no record at all).
absent_verdict() {
  local seen
  seen="$(cat "$(rw_attach_seen_file "$1")" 2>/dev/null || true)"
  if [ -n "$seen" ] && [ -n "$2" ] && [ "$seen" = "$2 $3" ]; then
    printf 'close\n'
  else
    printf 'recreate\n'
  fi
}

# remote_wrapper_sh -- worker-side shell that sets $w to the worker's boot
# restore wrapper (setup/templates/tmux-resurrect-restore.sh), or to '' when
# it is absent. The wrapper lives in the worker's dotfiles checkout, which
# ~/.config/tmux links into, so it is found without knowing the worker's
# home or checkout path.
remote_wrapper_sh() {
  # shellcheck disable=SC2016 # expanded by the worker's shell
  printf '%s' '
    cfg=$(cd -P "$HOME/.config/tmux" 2>/dev/null && cd .. && pwd)
    w="$cfg/setup/templates/tmux-resurrect-restore.sh"
    { [ -n "$cfg" ] && [ -x "$w" ]; } || w=""
    tmux_bin=$(command -v tmux || echo tmux)'
}

# remote_probe_cmd <session_name> -- the worker-side probe behind
# remote_state. A restore counts as in progress (`restoring`) while the boot
# restore's bootstrap session exists or the wrapper's --restoring says so
# (live boot lock from this boot, a guarded restore running, or the
# incomplete-restore marker for the live server). Checked only on the paths
# that would otherwise act on an absence: a present session is attached as
# usual. present/absent carry the server's start_time and pid.
remote_probe_cmd() {
  local session_name="$1"
  printf '%s' "
    unset TMUX TMUX_PANE
    $(remote_wrapper_sh)
    restoring() {
      tmux has-session -t '=${RW_BOOT_SESSION}' 2>/dev/null && return 0
      [ -n \"\$w\" ] && TMUX_RESURRECT_RESTORE_TMUX_BIN=\"\$tmux_bin\" \"\$w\" --restoring </dev/null >/dev/null 2>&1
    }
    if ! tmux list-sessions >/dev/null 2>&1; then
      if restoring; then echo restoring; else echo no-server; fi
    elif tmux has-session -t '=${session_name}' 2>/dev/null; then
      echo session-present \$(tmux display-message -p '#{start_time} #{pid}')
    elif restoring; then
      echo restoring
    else
      echo session-absent \$(tmux display-message -p '#{start_time} #{pid}')
    fi
  "
}

# remote_state <worker> <session_name>
# Prints one line whose first word is exactly one of: unreachable |
# no-server | restoring | session-absent | session-present (the last two
# followed by the worker server's start_time and pid). A single
# short-timeout ssh round trip (multiplexed via ControlMaster/ControlPersist
# -- ssh/.ssh/config -- so this is cheap on top of the plain attach that
# normally follows it). The remote inline script always itself exits 0 on
# success (every branch ends in `echo`), so ssh's own exit status reflects
# connectivity only, never tmux's internal has-session result.
remote_state() {
  local worker="$1" session_name="$2" out status
  out="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "$(remote_probe_cmd "$session_name")" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$out" ]; then
    printf 'unreachable\n'
  else
    printf '%s\n' "$out" | tail -n 1
  fi
}

# restore_recheck_cmd <session_name> -- worker-side: run the boot restore
# wrapper, then report `yes` (our session exists), `restoring` (the wrapper
# gave up waiting on the boot lock -- exit 75 -- or a restore is still in
# progress), or `no`. A missing wrapper (worker not yet updated) or a failed
# restore is not fatal: a plain `no` falls through to the manifest rebuild.
restore_recheck_cmd() {
  local session_name="$1"
  printf '%s' "
    unset TMUX TMUX_PANE
    $(remote_wrapper_sh)
    rc=0
    if [ -n \"\$w\" ]; then
      TMUX_RESURRECT_RESTORE_TMUX_BIN=\"\$tmux_bin\" \"\$w\" </dev/null >/dev/null 2>&1 || rc=\$?
    fi
    if tmux has-session -t '=${session_name}' 2>/dev/null; then
      echo yes
    elif [ \"\$rc\" = 75 ] || tmux has-session -t '=${RW_BOOT_SESSION}' 2>/dev/null ||
      { [ -n \"\$w\" ] && TMUX_RESURRECT_RESTORE_TMUX_BIN=\"\$tmux_bin\" \"\$w\" --restoring </dev/null >/dev/null 2>&1; }; then
      echo restoring
    else
      echo no
    fi
  "
}

# ask_worker_to_restore_then_recheck <worker> <session_name>
# Worker restore path. The wrapper starts the server with the worker's
# tmux.conf, runs the guarded restore (tmux/scripts/resurrect_restore.sh)
# under the lifecycle lock the verified save uses, and re-applies the hidden
# rw-* session options. Every caller takes the wrapper's boot lock first
# (bounded wait), so two panes reaching this branch together restore once:
# the second finds a live server and does nothing. Its output goes to the
# worker's boot-restore.log. This ssh can block for minutes behind a long
# restore, so it carries keepalives. Prints yes | restoring | no.
ask_worker_to_restore_then_recheck() {
  local worker="$1" session_name="$2"
  "$(rw_ssh_bin)" -o BatchMode=yes -o ConnectTimeout="$(rw_ssh_connect_timeout)" \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    "$worker" "$(restore_recheck_cmd "$session_name")" </dev/null 2>/dev/null | tail -n 1
}

attach_loop_main() {
  endpoint_id="${1:?attach-loop: endpoint id required}"
  shift
  if [ "${1:-}" = "--fresh" ]; then
    fresh="true"
  fi

  while true; do
    if pane_released; then
      exit_pane_released
    fi
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

    # These are execution-state markers, not endpoint-intent markers. Only
    # this foreground attach loop may make the pane advertise a remote host or
    # opt out of local workspace-resurrect capture.
    rw_pane_set "$pane_id" @remote-host "$worker"
    rw_pane_set "$pane_id" @workspace-resurrect-skip "1"

    # Tree endpoints have a focus-side companion (rw-tree-listener.sh) that
    # answers the worker shim's "need an editor pane" requests. It is a plain
    # background process, so a laptop restore respawns this loop but not it --
    # ensure it here, on attach and on every reconnect. Liveness is judged by
    # the listener's own pidfile, never pgrep -f: unrelated command lines
    # that mention the script name would false-positive and suppress the
    # spawn (2026-08-05). The listener dedups itself, so a redundant spawn
    # is harmless.
    if [ "$(printf '%s' "$endpoint_json" | jq -r '.role // empty')" = "tree" ]; then
      listener_pid="$(cat "$(rw_state_dir)/tree-listener-$endpoint_id.pid" 2>/dev/null || true)"
      if [ -z "$listener_pid" ] || ! kill -0 "$listener_pid" 2>/dev/null ||
        ! ps -p "$listener_pid" -o args= 2>/dev/null | grep -q "rw-tree-listener"; then
        nohup "$SCRIPT_DIR/rw-tree-listener.sh" "$endpoint_id" >/dev/null 2>&1 &
      fi
    fi

    event="attach"
    is_first_iteration="false"
    if [ "$attempt" -eq 0 ]; then
      is_first_iteration="true"
    else
      event="reconnect"
    fi
    attempt=$((attempt + 1))

    echo "rw: checking $worker ($session_name), attempt $attempt..."
    probe_start_ts="$(rw_now_epoch)"
    server_start="" server_pid=""
    read -r state server_start server_pid <<<"$(remote_state "$worker" "$session_name")"

    case "$state" in
      restoring)
        # The worker is mid-restore (or its last restore did not complete):
        # an absent session means nothing yet, and building one now would race
        # the restore. Wait without escalating the backoff.
        duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
        rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "drop" "worker-restoring"
        status "$worker is restoring its tmux sessions; checking again in ${restoring_wait}s..."
        sleep "$restoring_wait"
        continue
        ;;
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
          # rw-open.sh confirmed/created this session moments ago in this
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
        status "no tmux server on $worker; running its boot restore (waits for any restore in progress)..."
        recheck="$(ask_worker_to_restore_then_recheck "$worker" "$session_name")"
        duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
        if [ "$recheck" = "yes" ]; then
          rw_log_event "worker-restore" "$endpoint_id" "$worker" "$duration_ms" "success" "session recovered via worker resurrection"
        elif [ "$recheck" = "restoring" ] || [ -z "$recheck" ]; then
          # Another restore still holds the worker (or the ssh dropped): never
          # build an empty session under it; check again.
          rw_log_event "worker-restore" "$endpoint_id" "$worker" "$duration_ms" "drop" "worker-restoring"
          status "$worker is still restoring; checking again in ${restoring_wait}s..."
          sleep "$restoring_wait"
          continue
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
        # The worker resurrection that just ran (whichever branch) may have
        # also resurrected zombie siblings: endpoints closed AFTER that save
        # was written come back as unregistered sessions, and later worker
        # saves would persist them (smoke-journey 1R findings). Sweep them at
        # birth. min-age narrowed to 15s: restored zombies are seconds old,
        # while 15s still shields a concurrent open's create-to-registry
        # gap (pure-local bash+jq, no network). Best effort, never blocks.
        "$RW_PLUGIN_DIR/libexec/reconcile-worker" --worker "$worker" \
          --exclude "$endpoint_id" --min-age 15 </dev/null >/dev/null 2>&1 || true
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
        # The worker's tmux server is up, no restore is in progress, and our
        # specific endpoint session is gone. Two very different causes look
        # identical here:
        #   1. a deliberate `tmux kill-session` on the worker -- reconcile as
        #      an intentional close; or
        #   2. the shared server was LOST (reboot, crash) and has been started
        #      again, by a restore that did not bring this session back or by
        #      a sibling endpoint's rebuild -- self-closing would punish
        #      infrastructure loss (smoke lane w6: the losing endpoint
        #      tombstoned itself and killed its own pane).
        # Decided by the server instance the session was last seen on
        # (absent_verdict): only the same instance means an intentional close.
        if [ "$(absent_verdict "$endpoint_id" "$server_start" "$server_pid")" = "recreate" ]; then
          duration_ms="$(rw_elapsed_ms "$probe_start_ts")"
          rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "drop" "server_rebuilt:recreating-session"
          status "$session_name is not on $worker's current tmux server; recreating it..."
          if ! rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)"; then
            sleep "$backoff_seconds"
            backoff_seconds=$((backoff_seconds * 2))
            [ "$backoff_seconds" -gt "$backoff_cap" ] && backoff_seconds="$backoff_cap"
            continue
          fi
          # Session recreated -- fall through to the plain attach below.
        else
          forget_server_seen "$endpoint_id"
          rw_close_endpoint_core "$endpoint_id" "remote-intentional-close"
          echo "rw: endpoint $endpoint_id was closed directly on $worker; exiting."
          [ -n "$pane_id" ] && tmux kill-pane -t "$pane_id" 2>/dev/null
          exit 0
        fi
        ;;
      session-present)
        record_server_seen "$endpoint_id" "$server_start" "$server_pid"
        ;; # fall through to the plain attach below
    esac

    start_ts="$(rw_now_epoch)"
    echo "rw: attaching to $worker ($session_name), attempt $attempt..."
    # Record the reattach when it happens: the event logged after ssh returns
    # only appears once that attachment ends, which can be hours later.
    if [ "$event" = "reconnect" ]; then
      rw_log_event "reconnect" "$endpoint_id" "$worker" "" "attached" "attempt=$attempt"
    fi

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

    if pane_released; then
      rw_log_event "$event" "$endpoint_id" "$worker" "$duration_ms" "returned" "exit=$exit_code"
      exit_pane_released
    fi
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
}

# Sourced by tests for the helpers above; run as a pane's root process
# otherwise.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  attach_loop_main "$@"
fi
