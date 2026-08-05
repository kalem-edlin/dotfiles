#!/usr/bin/env bash
# Focus-side companion of one tree endpoint (rw-treemux.sh backgrounds this
# at tree creation). The worker-side tree nvim cannot create LOCAL panes, so
# when its open policy needs one (associated shell busy, or orphaned tree --
# see nvim/rw-tree-init.lua case 3) it writes `<state>.request` on the
# worker; this loop polls for that file over the multiplexed ssh channel
# (~1s cadence, only while the tree is open) and answers by creating an
# editor endpoint: its own worker session running `nvim --listen <sock>`,
# its own local pane split from the associated shell pane (or from the tree
# pane when orphaned), registered in the ordinary endpoint registry. The
# editor socket is then written back into the worker state file, which the
# waiting tree nvim polls to complete the open.
#
# Lifetime: exits as soon as the tree endpoint is tombstoned/deregistered
# (toggle-off, `prefix q`, reconcile). attach-loop re-ensures a live
# listener per iteration (pidfile liveness), covering laptop restores.
#
# Usage: rw-tree-listener.sh <tree-endpoint-id>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

tree_id="${1:?rw-tree-listener: tree endpoint id required}"

# Single instance per tree, via pidfile handshake -- NOT pgrep -f: any
# process whose argv merely mentions this script+id (an orchestrating
# shell, a grep) matches pgrep and either kills a fresh listener here or
# suppresses the spawn in attach-loop (found 2026-08-05 when the test
# harness's own command line matched). attach-loop re-ensures the listener
# on every attach/reconnect, so concurrent spawns are expected; the
# write-then-reread settles races (last writer wins, the loser exits).
pid_file="$(rw_state_dir)/tree-listener-$tree_id.pid"
existing="$(cat "$pid_file" 2>/dev/null || true)"
if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null &&
  ps -p "$existing" -o args= 2>/dev/null | grep -q "rw-tree-listener"; then
  exit 0
fi
printf '%s' "$$" >"$pid_file"
sleep 0.2
[ "$(cat "$pid_file" 2>/dev/null)" = "$$" ] || exit 0
trap 'rm -f "$pid_file"' EXIT

local_pane_for_endpoint() {
  tmux list-panes -a -F '#{pane_id} #{@rw-endpoint}' 2>/dev/null |
    awk -v id="$1" '$2 == id { print $1; exit }'
}

failures=0
while true; do
  if rw_tombstone_exists "$tree_id" || ! rw_endpoint_exists "$tree_id"; then
    exit 0
  fi

  tree_json="$(rw_read_endpoint "$tree_id" 2>/dev/null || true)"
  worker="$(printf '%s' "$tree_json" | jq -r '.worker // empty')"
  state_file="$(printf '%s' "$tree_json" | jq -r '.tree_state_file // empty')"
  shell_endpoint="$(printf '%s' "$tree_json" | jq -r '.tree_of // empty')"
  shell_worker_pane="$(printf '%s' "$tree_json" | jq -r '.shell_worker_pane // empty')"
  root="$(printf '%s' "$tree_json" | jq -r '.workspace.remote_path // empty')"
  if [ -z "$worker" ] || [ -z "$state_file" ]; then
    exit 0
  fi

  # Consume a pending request (cat-then-rm in one remote invocation). The
  # trailing marker distinguishes "no request" (marker only) from a failed
  # ssh round trip (no output at all) -- `cat` on a missing file must not
  # read as connectivity loss.
  # The request json carries no trailing newline, so print our own before
  # the marker -- otherwise the marker lands on the request's line and the
  # extraction below discards the request while having already rm'd it.
  probe="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "if [ -f '$state_file.request' ]; then cat '$state_file.request'; rm -f '$state_file.request'; fi; printf '\n__rw_ok\n'" 2>/dev/null)"
  if ! printf '%s' "$probe" | grep -q '^__rw_ok$'; then
    failures=$((failures + 1))
    sleep "$([ "$failures" -ge 3 ] && echo 5 || echo 1)"
    continue
  fi
  failures=0
  request="$(printf '%s' "$probe" | grep -v '^__rw_ok$' || true)"

  if [ -n "$request" ]; then
    editor_id="$(rw_new_short_id)"
    editor_session="$(rw_session_name "$editor_id")"
    editor_sock="${state_file%.json}-$editor_id.sock"
    start_ts="$(rw_now_epoch)"

    editor_pane="$(rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" "
      tmux new-session -d -P -F '#{pane_id}' -s '$editor_session' -c '$root' 'nvim --listen \"$editor_sock\"' &&
      tmux set-option -t '$editor_session' prefix None &&
      tmux set-option -t '$editor_session' prefix2 None &&
      tmux set-option -t '$editor_session' mouse off &&
      tmux set-option -t '$editor_session' status off
    " 2>/dev/null | head -n 1)"
    if [ -z "$editor_pane" ]; then
      rw_log_event "tree-editor" "$editor_id" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "remote session create failed"
      sleep 1
      continue
    fi

    now="$(rw_now_iso)"
    registry_json="$(jq -nc \
      --arg endpoint_id "$editor_id" \
      --arg worker "$worker" \
      --arg focus_machine_id "$(rw_machine_id)" \
      --arg remote_path "$root" \
      --arg tree_of "$tree_id" \
      --arg now "$now" \
      '{
        endpoint_id: $endpoint_id,
        worker: $worker,
        role: "tree-editor",
        tree_of: $tree_of,
        focus_machine_id: $focus_machine_id,
        focus_pane_id: "",
        workspace: {identity: "", mode: "tree-editor", focus_path: "", remote_path: $remote_path},
        launch_intent: {worker: $worker, workspace_arg: "tree-editor"},
        agent: {provider: null, session_id: null, resume_intent: null},
        created_at: $now, updated_at: $now, generation: 1
      }')"
    rw_write_json_atomic "$(rw_endpoint_file "$editor_id")" "$registry_json"

    # Split beside the associated shell pane when it is still alive;
    # otherwise (orphaned tree) split off the tree pane itself.
    src_pane="$(local_pane_for_endpoint "$shell_endpoint")"
    split_args=(-v -b -l '70%') # editor above the shell, upstream's default shape
    if [ -z "$src_pane" ]; then
      src_pane="$(local_pane_for_endpoint "$tree_id")"
      split_args=(-h) # orphaned: editor takes the space right of the tree
    fi
    if [ -z "$src_pane" ]; then
      rw_close_endpoint_core "$editor_id" "tree-editor-no-local-pane"
      sleep 1
      continue
    fi
    tmux split-window "${split_args[@]}" -t "$src_pane" \
      "exec bash '$SCRIPT_DIR/rw-tree-pane.sh' '$editor_id'" 2>/dev/null

    # Publish the editor to the tree nvim (full-state overwrite; the shim
    # re-checks liveness itself, stale shell_pane is fine).
    rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "printf '%s' '{\"shell_pane\":\"$shell_worker_pane\",\"editor_pane\":\"$editor_pane\",\"editor_socket\":\"$editor_sock\"}' > '$state_file'" \
      >/dev/null 2>&1

    rw_log_event "tree-editor" "$editor_id" "$worker" "$(rw_elapsed_ms "$start_ts")" "success" "tree=$tree_id src=$src_pane"
  fi

  sleep 1
done
