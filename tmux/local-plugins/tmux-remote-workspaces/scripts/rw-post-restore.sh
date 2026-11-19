#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Laptop-side reattach after a tmux-resurrect restore (D14, contract C6).
#
# Chained FIRST onto @resurrect-hook-post-restore-all by
# tmux-remote-workspaces.tmux: before tmux-workspace-resurrect's sidecar
# replay (scripts/restore.sh), which skips every pane this script stamped
# and every pane whose sidecar record carries `rw_endpoint`, and before
# libexec/reconcile.
#
# For every registered endpoint (endpoints/*.json without a tombstone), owned
# and visit endpoints alike (a visit endpoint, from a soft switch, is in no
# ownership record; it carries the same position fields, S7):
#
#   1. Find the restored pane by endpoint id. The endpoint record says where
#      its pane lived: focus_session_name + focus_window_index +
#      focus_pane_index (written by `rw handoff` / `rw open`, kept current
#      across session renames by rw-session-renamed.sh). The sidecar of the
#      snapshot that was just restored says where it was at that save
#      (`rw_endpoint` per pane, from @rw-endpoint). They normally agree. When
#      they disagree the sidecar wins: it describes exactly the layout
#      tmux-resurrect recreated, while the record's indices date from the
#      handoff. When the record has no position (older records), the sidecar
#      position is used; for records without focus_session_name the session
#      name is recovered from sessions.jsonl via focus_session_uuid. A
#      position the sidecar attributes to a different endpoint is never used,
#      nor one the sidecar records as a LOCAL pane when that sidecar was saved
#      after the endpoint was created (the record is stale; taking the pane
#      would also suppress its own replay).
#   2. A pane that already carries this endpoint's @rw-endpoint (a restore
#      over a live server) is "attached" and left exactly as it is, whatever
#      it runs. Otherwise the pane is taken only if it is unclaimed, carries
#      no other endpoint, was not started as an attach loop, and is a bare
#      shell: its current command is a shell AND its shell process has no
#      children. pane_current_command is the process-group leader's name, so
#      a foreground `bash script.sh`, an attach loop, or a shell with
#      suspended or background jobs would otherwise pass as idle. A freshly
#      restored zsh may still be running its rc files; a pane that is busy
#      only for that reason is re-checked for up to ~3s. A busy pane is never
#      killed.
#   3. respawn-pane the pane into attach-loop.sh <id> (no --fresh: nothing
#      here confirmed the worker session just now), then stamp @rw-endpoint,
#      @rw-worker, @rw-workspace, @rw-root-id, @rw-session-uuid,
#      @remote-host and @workspace-resurrect-skip, and re-stamp the
#      session's stable @session-uuid. Event `restore-reattach`.
#
# An endpoint whose pane cannot be found is logged (event
# `restore-reattach-missing`, with the reason) and left registered. This
# script never closes an endpoint and never touches a worker session: a
# worker session dies only by explicit hand-back, `rw forget` or `rw close`.
#
# The matching is a pure function, rw_restore_match, over a list-panes dump
# (tests/test_restore_match.sh runs it without tmux). Source this file to
# get it; executing it runs the reattach.

set -uo pipefail

RW_POST_RESTORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$RW_POST_RESTORE_DIR/common.sh"

# One list-panes call. Fields are space separated and the session name sits
# between the seventh space and the first colon (tmux replaces ':' in session
# names), so neither spaces in names nor commands break the split, and no
# TAB passes through tmux's control-character sanitization. The sixth field
# is L when the pane was started as an attach loop; the seventh is the pane
# pid, which rw_restore_panes_dump turns into K (the shell has children) or -.
RW_RESTORE_PANES_FORMAT='#{pane_id} #{session_id} #{window_index} #{pane_index} #{?@rw-endpoint,#{@rw-endpoint},-} #{?#{m:*attach-loop.sh*,#{pane_start_command}},L,-} #{pane_pid} #{session_name}:#{pane_current_command}'

# rw_restore_mark_children <parent-pids> -- stdin: raw list-panes lines;
# stdout: the dump rw_restore_match reads (pane pid replaced by K or -).
# <parent-pids> is every pid that has a child, space separated.
rw_restore_mark_children() {
  local parents=" $1 " pane_id session_id window pane endpoint loop pid rest kids
  while read -r pane_id session_id window pane endpoint loop pid rest; do
    [ -n "$pane_id" ] || continue
    case "$parents" in *" $pid "*) kids=K ;; *) kids=- ;; esac
    printf '%s %s %s %s %s %s %s %s\n' "$pane_id" "$session_id" "$window" "$pane" \
      "$endpoint" "$loop" "$kids" "$rest"
  done
}

rw_restore_panes_dump() {
  local parents
  parents="$(ps -axo ppid= 2>/dev/null | tr -s ' \n' ' ')"
  tmux list-panes -a -F "$RW_RESTORE_PANES_FORMAT" 2>/dev/null |
    rw_restore_mark_children "$parents"
}

# rw_restore_match <endpoints.json> <panes.dump> [sidecar.json] [sessions.jsonl]
#
#   endpoints.json  JSON array of endpoint records
#   panes.dump      output of rw_restore_panes_dump
#   sidecar.json    tmux-workspace-resurrect sidecar (may be absent/empty)
#   sessions.jsonl  rw's session uuid registry (may be absent/empty)
#
# Prints one JSON object per endpoint, in endpoint-id order:
#   {endpoint_id, outcome: "reattach"|"attached"|"missing", pane_id,
#    session_id, session_name, window, pane, via: "record"|"sidecar"|"",
#    reason}
rw_restore_match() {
  local endpoints="$1" dump="$2" sidecar="${3:-}" sessions="${4:-}"
  local sidecar_json='{}' sessions_json='[]'
  if [ -n "$sidecar" ] && [ -s "$sidecar" ]; then
    sidecar_json="$(jq -c 'if type == "object" then . else {} end' "$sidecar" 2>/dev/null || printf '{}')"
  fi
  if [ -n "$sessions" ] && [ -s "$sessions" ]; then
    sessions_json="$(jq -cs '[.[] | objects]' "$sessions" 2>/dev/null || printf '[]')"
  fi
  jq -nc \
    --slurpfile endpoints "$endpoints" \
    --rawfile dump "$dump" \
    --argjson sidecar "$sidecar_json" \
    --argjson sessions "$sessions_json" '
    def shells: ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "dash", "ksh", ""];
    def pos_key: "\(.session):\(.window).\(.pane)";

    ($dump | split("\n") | map(
      capture("^(?<pane_id>%[0-9]+) (?<session_id>\\$[0-9]+) (?<window>[0-9]+) (?<pane>[0-9]+) (?<endpoint>[^ ]+) (?<loop>[L-]) (?<kids>[K-]) (?<session>[^:]*):(?<command>.*)$")
      | .endpoint = (if .endpoint == "-" then "" else .endpoint end)
      | .shell = (.command as $c | shells | index([$c]) != null)
      | .idle = (.shell and .kids == "-" and .loop == "-")
    )) as $panes

    # Every sidecar row: endpoint "" for a pane that was local at the save.
    | ([($sidecar.panes // [])[]
        | objects
        | (.logical_id // "" | capture("^(?<session>.*):(?<window>[0-9]+)\\.(?<pane>[0-9]+)$")) as $p
        | {session: $p.session, window: $p.window, pane: $p.pane,
           endpoint: ((.rw_endpoint // "") | tostring)}]) as $rows
    | ([$rows[] | select(.endpoint != "")]) as $side
    | ($rows | map({key: pos_key, value: .endpoint}) | from_entries) as $side_owner
    | ($sidecar.saved_at // "" | tostring) as $saved_at

    | def name_for_uuid($u):
        if ($u // "") == "" then ""
        else ([$sessions[] | select(.uuid == $u)] | last | .session_name // "") end;

      def record_pos($e):
        ($e.focus_session_name // "") as $n
        | (if $n != "" then $n else name_for_uuid($e.focus_session_uuid) end) as $name
        | if $name != "" and ($e.focus_window_index | type) == "number"
             and ($e.focus_pane_index | type) == "number"
          then {session: $name, window: ($e.focus_window_index | tostring),
                pane: ($e.focus_pane_index | tostring)}
          else null end;

      def side_pos($id):
        [$side[] | select(.endpoint == $id)] | if length == 1 then .[0] | del(.endpoint) else null end;

      def missing($e; $reason; $via):
        {endpoint_id: $e.endpoint_id, outcome: "missing", pane_id: "", session_id: "",
         session_name: "", window: "", pane: "", via: $via, reason: $reason};

      def found($e; $outcome; $p; $via):
        {endpoint_id: $e.endpoint_id, outcome: $outcome, pane_id: $p.pane_id,
         session_id: $p.session_id, session_name: $p.session, window: $p.window,
         pane: $p.pane, via: $via, reason: ""};

    reduce ($endpoints[0] | map(select(type == "object" and (.endpoint_id | type) == "string"
              and .endpoint_id != "")) | sort_by(.endpoint_id) | .[]) as $e
      ({claimed: [], out: []};
       . as $state
       | $e.endpoint_id as $id
       | ([$panes[] | select(.endpoint == $id)
           | select(.pane_id as $pid | $state.claimed | index([$pid]) | not)] | first) as $live
       | if $live != null then
           .claimed += [$live.pane_id] | .out += [found($e; "attached"; $live; "live")]
         else
           record_pos($e) as $rec
           | side_pos($id) as $sp
           | (if $sp != null and $sp == $rec then {pos: $rec, via: "record"}
              elif $sp != null then {pos: $sp, via: "sidecar"}
              elif $rec == null then null
              else ($side_owner[$rec | pos_key]) as $owner
                | ($e.created_at // "" | tostring) as $created
                | if $owner == null or $owner == $id then {pos: $rec, via: "record"}
                  elif $owner != "" then {pos: $rec, via: "record", owned: $owner}
                  # Local at the save. A save older than the endpoint shows the
                  # pre-handoff pane: expected. A newer one means the record
                  # points at a pane that stayed local.
                  elif $saved_at != "" and $created != "" and $saved_at < $created then {pos: $rec, via: "record"}
                  else {pos: $rec, via: "record", local: true} end
              end) as $choice
           | if $choice == null then
               .out += [missing($e; "no-position"; "")]
             elif $choice.owned != null then
               .out += [missing($e; "position \($choice.pos | pos_key) belongs to endpoint \($choice.owned)"; "record")]
             elif $choice.local == true then
               .out += [missing($e; "sidecar records \($choice.pos | pos_key) as a local pane"; "record")]
             else
               ([$panes[] | select(.session == $choice.pos.session and .window == $choice.pos.window
                  and .pane == $choice.pos.pane)] | first) as $p
               | if $p == null then
                   .out += [missing($e; "no pane at \($choice.pos | pos_key)"; $choice.via)]
                 elif ($state.claimed | index([$p.pane_id])) != null then
                   .out += [missing($e; "pane \($p.pane_id) at \($choice.pos | pos_key) already claimed"; $choice.via)]
                 elif $p.endpoint != "" and $p.endpoint != $id then
                   .out += [missing($e; "pane \($p.pane_id) at \($choice.pos | pos_key) carries endpoint \($p.endpoint)"; $choice.via)]
                 elif $p.loop == "L" then
                   .out += [missing($e; "pane \($p.pane_id) at \($choice.pos | pos_key) runs another attach loop"; $choice.via)]
                 elif ($p.idle | not) then
                   .out += [missing($e; "pane \($p.pane_id) at \($choice.pos | pos_key) is busy (\($p.command)\(if $p.kids == "K" then ", has child processes" else "" end))"; $choice.via)
                     + {retry: ($p.shell and $p.kids == "K")}]
                 else
                   .claimed += [$p.pane_id] | .out += [found($e; "reattach"; $p; $choice.via)]
                 end
             end
         end)
    | .out[]'
}

rw_post_restore_main() {
  command -v jq >/dev/null 2>&1 || {
    rw_log "post-restore skipped: jq is unavailable"
    return 0
  }

  local endpoints_dir work f id
  endpoints_dir="$(rw_endpoints_dir)"
  if ! compgen -G "$endpoints_dir/*.json" >/dev/null; then
    rw_log "post-restore: no registered endpoints, nothing to reattach"
    return 0
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/rw-post-restore.XXXXXX")" || return 0
  # shellcheck disable=SC2064 # expand now: the path is fixed for this run
  trap "rm -rf '$work'" EXIT

  # Registered, untombstoned endpoints; an unreadable file is skipped, not
  # fatal to the others.
  : >"$work/endpoints.jsonl"
  for f in "$endpoints_dir"/*.json; do
    [ -f "$f" ] || continue
    id="$(jq -r 'select(type == "object") | .endpoint_id // empty' "$f" 2>/dev/null || true)"
    [ -n "$id" ] || continue
    if rw_tombstone_exists "$id"; then
      rw_log "post-restore: endpoint $id is tombstoned; not reattached"
      continue
    fi
    # Released by `rw switch --to local --force` while its remote was
    # unreachable: closed on the next contact, never reattached to a pane.
    if [ "$(jq -r '.pending.action // empty' "$f" 2>/dev/null)" = "close" ]; then
      rw_log "post-restore: endpoint $id has a pending close; not reattached"
      continue
    fi
    jq -c . "$f" >>"$work/endpoints.jsonl" 2>/dev/null || true
  done
  jq -s . "$work/endpoints.jsonl" >"$work/endpoints.json"

  # Read-only use of the sibling plugin's path helper, as libexec/reconcile
  # does: the sidecar of the snapshot that was just restored.
  local sidecar="" workspace_common="$RW_PLUGIN_DIR/../tmux-workspace-resurrect/scripts/common.sh"
  if [ -f "$workspace_common" ]; then
    # shellcheck source=../../tmux-workspace-resurrect/scripts/common.sh
    sidecar="$(source "$workspace_common" && workspace_sidecar_file 2>/dev/null || true)"
  fi

  # Restored shells may still be running their rc files (children), so a
  # pane that is busy only for that reason is re-checked for up to ~3s.
  local attempt=0
  while :; do
    rw_restore_panes_dump >"$work/panes.dump"
    rw_restore_match "$work/endpoints.json" "$work/panes.dump" "$sidecar" "$(rw_sessions_file)" \
      >"$work/matches.jsonl" || {
      rw_log "post-restore: endpoint matching failed; nothing reattached"
      return 0
    }
    jq -e 'select(.retry == true)' "$work/matches.jsonl" >/dev/null 2>&1 || break
    attempt=$((attempt + 1))
    [ "$attempt" -lt "${RW_POST_RESTORE_SETTLE_TRIES:-6}" ] || break
    sleep 0.5
  done

  local reattached=0 attached=0 missing=0 line outcome pane_id session_id session_name
  local window pane via reason endpoint_json worker remote_path root_id old_uuid dir cmd
  local current_uuid root_rel
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="$(jq -r '.endpoint_id' <<<"$line")"
    outcome="$(jq -r '.outcome' <<<"$line")"
    pane_id="$(jq -r '.pane_id' <<<"$line")"
    session_id="$(jq -r '.session_id' <<<"$line")"
    session_name="$(jq -r '.session_name' <<<"$line")"
    window="$(jq -r '.window' <<<"$line")"
    pane="$(jq -r '.pane' <<<"$line")"
    via="$(jq -r '.via' <<<"$line")"
    reason="$(jq -r '.reason' <<<"$line")"
    endpoint_json="$(jq -c --arg id "$id" '.[] | select(.endpoint_id == $id)' "$work/endpoints.json" | head -n 1)"
    worker="$(jq -r '.worker // empty' <<<"$endpoint_json")"

    case "$outcome" in
      attached)
        attached=$((attached + 1))
        rw_log "post-restore: endpoint $id already attached in $pane_id; left as is"
        continue
        ;;
      missing)
        missing=$((missing + 1))
        rw_log "post-restore: endpoint $id not reattached ($reason); left registered"
        rw_log_event "restore-reattach-missing" "$id" "$worker" "" "skipped" "$reason"
        continue
        ;;
    esac

    remote_path="$(jq -r '.workspace.remote_path // .workspace.worker_root // empty' <<<"$endpoint_json")"
    root_id="$(jq -r '.root_id // empty' <<<"$endpoint_json")"
    root_rel="$(jq -r '.root_rel // empty' <<<"$endpoint_json")"
    old_uuid="$(jq -r '.focus_session_uuid // empty' <<<"$endpoint_json")"
    dir="$(jq -r '.workspace.focus_path // empty' <<<"$endpoint_json")"
    [ -n "$dir" ] || { [ -n "$root_rel" ] && dir="$HOME/$root_rel"; }
    [ -d "$dir" ] || dir="$HOME"

    printf -v cmd '%q %q' "$RW_POST_RESTORE_DIR/attach-loop.sh" "$id"
    if ! tmux respawn-pane -k -t "$pane_id" -c "$dir" "$cmd" 2>/dev/null; then
      missing=$((missing + 1))
      rw_log "post-restore: endpoint $id: respawn of $pane_id failed; left registered"
      rw_log_event "restore-reattach-missing" "$id" "$worker" "" "fail" "respawn failed pane=$pane_id"
      continue
    fi

    rw_pane_set "$pane_id" @rw-endpoint "$id"
    rw_pane_set "$pane_id" @rw-worker "$worker"
    [ -n "$remote_path" ] && rw_pane_set "$pane_id" @rw-workspace "$remote_path"
    [ -n "$root_id" ] && rw_pane_set "$pane_id" @rw-root-id "$root_id"
    [ -n "$old_uuid" ] && rw_pane_set "$pane_id" @rw-session-uuid "$old_uuid"
    rw_pane_set "$pane_id" @remote-host "$worker"
    rw_pane_set "$pane_id" @workspace-resurrect-skip "1"
    rw_pane_unset "$pane_id" @workspace-last-command

    # A restored session got a fresh @session-uuid from session-created;
    # give it back the stable one the endpoint remembers.
    if [ -n "$old_uuid" ] && [ -n "$session_id" ]; then
      current_uuid="$(tmux show-option -t "$session_id" -qv @session-uuid 2>/dev/null || true)"
      if [ "$current_uuid" != "$old_uuid" ]; then
        tmux set-option -t "$session_id" -q @session-uuid "$old_uuid" 2>/dev/null || true
        rw_register_session_uuid "$old_uuid" "$session_name"
        rw_log "post-restore: re-stamped session '$session_name' ($session_id) to stable uuid $old_uuid"
      fi
    fi

    reattached=$((reattached + 1))
    rw_log_event "restore-reattach" "$id" "$worker" "" "success" \
      "pane=$pane_id session=$session_name window=$window pane_index=$pane via=$via"
  done <"$work/matches.jsonl"

  rw_log "post-restore complete: reattached=$reattached already=$attached missing=$missing"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rw_post_restore_main "$@"
fi
