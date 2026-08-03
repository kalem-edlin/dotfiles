#!/usr/bin/env bash
# Post-restore re-establishment of remote attachments: chained onto
# tmux-resurrect's @resurrect-hook-post-restore-all (see
# tmux-remote-workspaces.tmux), appended BEFORE libexec/reconcile in that
# same hook. See initial-plan.md, "Local restore of remote attachments" and
# Phase 2 ("Reattach remembered endpoints on laptop restore... Define UUID
# re-resolution across restore/renumber, with the endpoint registry
# authoritative and pane `@vars` treated as cache only").
#
# Never destructive: this script only ever sets cache pane options and
# respawns a pane's *local* foreground process into attach-loop.sh, which
# itself only reconnects/reattaches (or, per its own case-d logic, restores
# or rebuilds the REMOTE session -- never anything this script decides). If
# an endpoint's local pane cannot be re-resolved unambiguously, this script
# does nothing to it and leaves it for `rw status`/`rw doctor` and
# libexec/reconcile to reason about instead of guessing.
#
# Matching strategy (both steps use ONLY information that survives a tmux
# server restart -- sessions.jsonl and endpoints/*.json on disk, plus
# whatever the just-completed resurrect restore produced):
#
#   1. Session-level: tmux assigns every (re)created session a brand-new
#      internal $-id and, because our own session-created hook is
#      global (`tmux set-hook -g session-created`), a brand-new
#      @session-uuid too -- restored sessions do NOT keep their pre-crash
#      UUID for free. Each endpoint's registry entry remembers the OLD
#      stable UUID (focus_session_uuid). We look that UUID up in
#      sessions.jsonl to recover the SESSION NAME it was last bound to
#      (that lookup is safe even though session-created-hook.sh has
#      already appended fresh entries for the new session by the time this
#      runs -- those new entries are keyed on the NEW uuid, so a query for
#      the OLD uuid's last-known name is unaffected). If a live tmux
#      session with that exact name exists post-restore, we forcibly
#      re-stamp ITS @session-uuid back to the OLD uuid (overriding the
#      fresh one session-created-hook.sh assigned) and re-register it, so
#      the stable identity survives the restart transparently. tmux's
#      `=name` exact-match target syntax is used throughout to avoid its
#      normal fuzzy/prefix session matching.
#
#   2. Pane-level: there is no stable per-pane UUID yet (only per-session --
#      that is still Phase 2/3 future work per the plan's "Pane and window
#      model" and "Worktree claims" sections). `renumber-windows on` means
#      the recorded focus_window_index/focus_pane_index cannot be trusted
#      as a primary key across a restart. Instead, within the now-resolved
#      session, we match candidate panes by `#{pane_current_path}` against
#      the endpoint's recorded workspace.focus_path -- tmux-resurrect
#      itself recreates each pane at its originally-saved cwd regardless of
#      the @workspace-resurrect-skip opt-out (that seam only stops the
#      RESUME COMMAND from being pasted, never pane/window recreation), so
#      a remote-backed pane reliably comes back as a bare shell sitting in
#      the same directory. Exactly one path match -> unambiguous, use it.
#      Zero matches -> pane wasn't restored (or moved); leave alone. More
#      than one match (e.g. two endpoints legitimately shared a cwd) -> try
#      narrowing to the candidate(s) whose CURRENT window/pane index also
#      equals the recorded focus_window_index/focus_pane_index; if that
#      narrows to exactly one, use it, otherwise give up rather than guess.
#      A pane already claimed by an earlier endpoint in this same pass is
#      never claimed again.
#
# For each successfully resolved pane: set the @rw-* cache options fresh
# (they do not survive a server restart) and `tmux respawn-pane` its local
# foreground process into attach-loop.sh for that endpoint -- WITHOUT
# --fresh, since this script makes no claim about the remote session's
# current liveness (unlike rw-ensure.sh, which just created/confirmed it a
# moment earlier in the same invocation). attach-loop.sh's own probe
# handles whatever it finds remotely from there, including case (d)
# infrastructure-loss recovery if the worker itself needs restoring too.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

command -v jq >/dev/null 2>&1 || {
  rw_log "post-restore skipped: jq is unavailable"
  exit 0
}

endpoints_dir="$(rw_endpoints_dir)"
if [ ! -d "$endpoints_dir" ] || [ -z "$(ls -A "$endpoints_dir" 2>/dev/null)" ]; then
  rw_log "post-restore: no registered endpoints, nothing to re-establish"
  exit 0
fi

claimed_panes_file="$(mktemp "${TMPDIR:-/tmp}/rw-post-restore-claimed.XXXXXX")"
trap 'rm -f "$claimed_panes_file"' EXIT
: >"$claimed_panes_file"

reattached=0
skipped=0

for f in "$endpoints_dir"/*.json; do
  [ -f "$f" ] || continue
  endpoint_json="$(cat "$f")"
  id="$(printf '%s' "$endpoint_json" | jq -r '.endpoint_id // empty')"
  [ -n "$id" ] || continue

  old_uuid="$(printf '%s' "$endpoint_json" | jq -r '.focus_session_uuid // empty')"
  worker="$(printf '%s' "$endpoint_json" | jq -r '.worker // empty')"
  remote_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.remote_path // empty')"
  focus_path="$(printf '%s' "$endpoint_json" | jq -r '.workspace.focus_path // empty')"
  focus_window_index="$(printf '%s' "$endpoint_json" | jq -r '.focus_window_index // empty')"
  focus_pane_index="$(printf '%s' "$endpoint_json" | jq -r '.focus_pane_index // empty')"

  if [ -z "$old_uuid" ]; then
    rw_log "post-restore: endpoint $id has no focus_session_uuid recorded; left for status/reconcile"
    skipped=$((skipped + 1))
    continue
  fi

  session_name="$(rw_session_name_for_uuid "$old_uuid")"
  if [ -z "$session_name" ]; then
    rw_log "post-restore: endpoint $id's session uuid $old_uuid has no known session name; left for status/reconcile"
    skipped=$((skipped + 1))
    continue
  fi

  if ! tmux has-session -t "=$session_name" 2>/dev/null; then
    rw_log "post-restore: endpoint $id's session '$session_name' is not present after restore; left for status/reconcile"
    skipped=$((skipped + 1))
    continue
  fi

  # --- Step 1: re-stamp the stable session UUID (idempotent across
  # multiple endpoints that share the same local session) -----------------
  # NOTE: unlike has-session/list-panes -s above, tmux's `display-message
  # -t` target parser does NOT honor the "=name" exact-match session syntax
  # (verified empirically -- it silently resolves to nothing). Resolve the
  # exact session id ourselves by scanning `list-sessions` session ids one
  # at a time and comparing names, instead of trusting tmux's own (fuzzy,
  # prefix-matching) plain-name target resolution here.
  #
  # Deliberately NOT a TAB-joined `list-sessions -F '#{session_id}\t#{session_name}'`
  # parsed with `awk -F'\t'`: tmux (observed: Homebrew 3.7b) sanitizes
  # control characters -- including TAB -- to `_` in command output, which
  # silently collapses the whole delimited record into one field and makes
  # `$2 == n` never match (see tmux-workspace-resurrect/scripts/save.sh for
  # the incident this mirrors). Since this script runs on the laptop at
  # restore time, it can hit the exact same tmux version as the mini
  # worker. A single #{...} format per call has nothing to delimit, so it's
  # immune regardless of tmux version.
  session_id=""
  while IFS= read -r cand_session_id; do
    [ -n "$cand_session_id" ] || continue
    # -p is load-bearing: without it display-message routes to the client
    # status line, the substitution is always empty, and the session-UUID
    # re-stamp below never fires (smoke lane w6: restored sessions kept
    # fresh UUIDs instead of re-resolving to their saved ones).
    cand_session_name="$(tmux display-message -pt "$cand_session_id" -F '#{session_name}' 2>/dev/null || true)"
    if [ "$cand_session_name" = "$session_name" ]; then
      session_id="$cand_session_id"
      break
    fi
  done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null)
  if [ -n "$session_id" ]; then
    current_uuid="$(tmux show-option -t "$session_id" -qv @session-uuid 2>/dev/null || true)"
    if [ "$current_uuid" != "$old_uuid" ]; then
      tmux set-option -t "$session_id" -q @session-uuid "$old_uuid"
      rw_register_session_uuid "$old_uuid" "$session_name"
      rw_log "post-restore: re-stamped session '$session_name' ($session_id) back to stable uuid $old_uuid"
    fi
  fi

  # --- Step 2: resolve the pane by cwd match, narrowing on ambiguity -----
  # NOTE: pane fields are fetched one field per `display-message` call
  # (immune to tmux's control-character sanitization, see Step 1 above)
  # rather than a single TAB-joined `list-panes -F` format string parsed by
  # `read`. The array elements built below (`cand_pane$'\t'cand_window...`)
  # are safe to split on TAB even so: that TAB is inserted by this script
  # itself from already-parsed, always-numeric window/pane index values --
  # it never passes through tmux's own stdout sanitization.
  candidates=()
  while IFS= read -r cand_pane; do
    [ -n "$cand_pane" ] || continue
    cand_path="$(tmux display-message -pt "$cand_pane" -F '#{pane_current_path}' 2>/dev/null || true)"
    [ "$cand_path" = "$focus_path" ] || continue
    grep -Fqx "$cand_pane" "$claimed_panes_file" 2>/dev/null && continue
    cand_window="$(tmux display-message -pt "$cand_pane" -F '#{window_index}' 2>/dev/null || true)"
    cand_index="$(tmux display-message -pt "$cand_pane" -F '#{pane_index}' 2>/dev/null || true)"
    candidates+=("$cand_pane"$'\t'"$cand_window"$'\t'"$cand_index")
  done < <(tmux list-panes -s -t "=$session_name" -F '#{pane_id}' 2>/dev/null)

  resolved_pane=""
  if [ "${#candidates[@]}" -eq 1 ]; then
    resolved_pane="${candidates[0]%%$'\t'*}"
  elif [ "${#candidates[@]}" -gt 1 ]; then
    narrowed=()
    for c in "${candidates[@]}"; do
      c_pane="${c%%$'\t'*}"
      c_rest="${c#*$'\t'}"
      c_window="${c_rest%%$'\t'*}"
      c_index="${c_rest#*$'\t'}"
      if [ "$c_window" = "$focus_window_index" ] && [ "$c_index" = "$focus_pane_index" ]; then
        narrowed+=("$c_pane")
      fi
    done
    if [ "${#narrowed[@]}" -eq 1 ]; then
      resolved_pane="${narrowed[0]}"
    fi
  fi

  if [ -z "$resolved_pane" ]; then
    rw_log "post-restore: endpoint $id ($session_name, path=$focus_path) has ${#candidates[@]} candidate pane(s) -- ambiguous or absent, left for status/reconcile"
    skipped=$((skipped + 1))
    continue
  fi

  printf '%s\n' "$resolved_pane" >>"$claimed_panes_file"

  rw_pane_set "$resolved_pane" @rw-endpoint "$id"
  rw_pane_set "$resolved_pane" @rw-worker "$worker"
  rw_pane_set "$resolved_pane" @rw-workspace "$remote_path"
  rw_pane_set "$resolved_pane" @remote-host "$worker"
  rw_pane_set "$resolved_pane" @rw-session-uuid "$old_uuid"
  # Same opt-out rw-ensure.sh sets: this pane is managed, so a subsequent
  # tmux-workspace-resurrect restore must never paste a stale command into
  # it. Cache-only, so it needs to be re-set here too.
  rw_pane_set "$resolved_pane" @workspace-resurrect-skip "1"

  # No --fresh here: unlike rw-ensure.sh, this script has not itself just
  # confirmed/created the remote session, so attach-loop.sh must run its
  # full remote-state discrimination from its very first iteration.
  tmux respawn-pane -k -t "$resolved_pane" "bash '$SCRIPT_DIR/attach-loop.sh' '$id'" 2>/dev/null &&
    rw_log_event "restore-reattach" "$id" "$worker" "" "success" "pane=$resolved_pane session=$session_name"

  reattached=$((reattached + 1))
done

rw_log "post-restore complete: reattached=$reattached skipped=$skipped"
