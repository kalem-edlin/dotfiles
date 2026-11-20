#!/usr/bin/env bash
# Root-level operations shared by rw handoff / handback / open / forget /
# reclaim. Sourced only; never executed directly. Builds on common.sh
# (ownership records, ssh transport, endpoint registry, per-root locks) --
# see the ownership section there for the record layout, and
# docs/tasks/remote-owned-directories.md for the contracts.

RW_ROOTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$RW_ROOTS_DIR/common.sh"

RW_TAB="$(printf '\t')"

# rw_root_panes <root_local>
# Every pane on this tmux server (any session) whose cwd is the root or
# inside it, one line each:
#   pane_id<TAB>cwd<TAB>session<TAB>window_index<TAB>pane_index<TAB>@rw-endpoint<TAB>@rw-root-id<TAB>command
# The root travels through ENVIRON, not `awk -v`, which would interpret
# backslashes in the path.
rw_root_panes() {
  tmux list-panes -a -F "#{pane_id}${RW_TAB}#{pane_current_path}${RW_TAB}#{session_name}${RW_TAB}#{window_index}${RW_TAB}#{pane_index}${RW_TAB}#{@rw-endpoint}${RW_TAB}#{@rw-root-id}${RW_TAB}#{pane_current_command}" 2>/dev/null |
    RW_AWK_ROOT="$1" awk -F '\t' '{ r = ENVIRON["RW_AWK_ROOT"] } $2 == r || index($2, r "/") == 1'
}

# rw_root_offsite_agents <root_local>
# Agent panes a hand-off of the root would NOT move although the agent works
# inside it (the off-root agent guard, docs/tasks/remote-owned-directories.md
# A5). tmux's pane_current_path is the foreground process's cwd, and Claude
# Code never chdirs, so a session launched outside the root that later cds
# into it keeps reporting its launch directory: rw_root_panes misses it and
# it would keep writing the root here while the worker owns it.
#
# Candidates: local panes (empty @rw-endpoint) NOT under the root by
# pane_current_path, with @agent_kind set and a live @agent_pid (the liveness
# rule rw-picker.sh uses). For claude, the last non-null `cwd` in the tail of
# the session's transcript, under the root (symlinks resolved; the root
# itself or a path below it), makes the pane offending. pi records its cwd
# once, in the session header, and never updates it, so it cannot be told
# apart here and is skipped. Any lookup failure (no recorded session, no
# transcript, adapter or jq error) is "not offending": an unreadable
# transcript never blocks a hand-off.
# Prints one line per offending pane:
#   pane_id<TAB>session:window.pane<TAB>kind<TAB>agent_cwd<TAB>pane_current_path
# Test seam: RW_ADAPTERS_DIR (as rw-handoff.sh), RW_OFFSITE_TAIL_LINES.
rw_root_offsite_agents() {
  local root="$1" adapters pane_id label ppath kind agent_pid detect_out session project transcript acwd
  adapters="${RW_ADAPTERS_DIR:-$RW_ROOTS_DIR/../libexec/adapters}"
  while IFS="$RW_TAB" read -r pane_id label ppath kind agent_pid; do
    [ -n "$pane_id" ] && [ -n "$kind" ] && [ -n "$agent_pid" ] || continue
    kill -0 "$agent_pid" 2>/dev/null || continue
    [ "$kind" = claude ] || continue
    [ -x "$adapters/claude" ] || continue
    detect_out="$("$adapters/claude" detect --pane "$pane_id" </dev/null 2>/dev/null)" || continue
    session="$(printf '%s' "$detect_out" | jq -r '.session_id // empty' 2>/dev/null)" || continue
    project="$(printf '%s' "$detect_out" | jq -r '.project_path // empty' 2>/dev/null)" || continue
    [ -n "$session" ] && [ -n "$project" ] || continue
    transcript="$("$adapters/claude" transcript-path --session-id "$session" --project-path "$project" </dev/null 2>/dev/null)" || continue
    [ -n "$transcript" ] && [ -f "$transcript" ] || continue
    # Bounded read: the last RW_OFFSITE_TAIL_LINES lines (default 200) of at
    # most the last 16 MiB; a line cut by the byte bound fails to parse and
    # is skipped. Lines without a string cwd (api-request entries) are
    # skipped; the newest one that has it wins.
    acwd="$(tail -c 16777216 "$transcript" 2>/dev/null | tail -n "${RW_OFFSITE_TAIL_LINES:-200}" |
      jq -Rr 'fromjson? | objects | .cwd | strings | select(length > 0)' 2>/dev/null | tail -n 1)"
    [ -n "$acwd" ] || continue
    acwd="$(rw_physical_path "$acwd")"
    case "$acwd" in
      "$root" | "$root"/*) printf '%s\t%s\t%s\t%s\t%s\n' "$pane_id" "$label" "$kind" "$acwd" "$ppath" ;;
    esac
  done < <(tmux list-panes -a -F "#{pane_id}${RW_TAB}#{session_name}:#{window_index}.#{pane_index}${RW_TAB}#{pane_current_path}${RW_TAB}#{@agent_kind}${RW_TAB}#{@agent_pid}${RW_TAB}#{@rw-endpoint}" 2>/dev/null |
    RW_AWK_ROOT="$root" awk -F '\t' '
      { r = ENVIRON["RW_AWK_ROOT"] }
      $6 == "" && $3 != "" && $4 != "" && $5 != "" && !($3 == r || index($3, r "/") == 1) { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }')
  return 0
}

# rw_offsite_agents_refusal <root_local>
# The one-line refusal (no "rw: " prefix; rw_die adds it) when
# rw_root_offsite_agents finds a pane; returns 1 and prints nothing when it
# finds none. Names the first pane and counts the rest.
rw_offsite_agents_refusal() {
  local root="$1" found first n more=""
  found="$(rw_root_offsite_agents "$root")"
  [ -n "$found" ] || return 1
  first="$(printf '%s\n' "$found" | head -n 1)"
  n="$(printf '%s\n' "$found" | grep -c .)"
  [ "$n" -le 1 ] || more=" (and $((n - 1)) more)"
  printf '%s%s runs %s working in %s (started in %s); it would keep writing %s on this machine. Stop it or start it inside %s, then hand off.\n' \
    "$(printf '%s' "$first" | cut -f2)" "$more" "$(printf '%s' "$first" | cut -f3)" \
    "$(rw_display_path "$(printf '%s' "$first" | cut -f4)")" "$(rw_display_path "$(printf '%s' "$first" | cut -f5)")" \
    "$(rw_display_path "$root")" "$(rw_display_path "$root")"
}

# rw_display_path <path> -- ~/... under $HOME (as given or physical), for messages.
# shellcheck disable=SC2088 # a literal ~ is the point
rw_display_path() {
  local home_p
  home_p="$(rw_physical_path "$HOME")"
  case "$1" in
    "$HOME") printf '~\n' ;;
    "$home_p") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    "$home_p"/*) printf '~/%s\n' "${1#"$home_p"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# rw_root_bound_panes <root_id> <endpoint-ids...>
# Panes bound to the root ON ITS OWNER: those whose @rw-endpoint is one of
# the record's endpoints (passed in). @rw-root-id alone is not enough: a
# visit pane on another remote carries the root id too (rw switch stamps
# it, CS2) and must never be released or counted as the owner's (fix wave
# A, finding 1). <root_id> only keeps the callers' shape.
# Prints pane_id<TAB>endpoint_id.
rw_root_bound_panes() {
  shift
  [ $# -gt 0 ] || return 0
  tmux list-panes -a -F "#{pane_id}${RW_TAB}#{@rw-endpoint}" 2>/dev/null |
    awk -F '\t' -v eps="$*" '
      BEGIN { n = split(eps, e, " "); for (i = 1; i <= n; i++) want[e[i]] = 1 }
      $2 != "" && ($2 in want) { print $1 "\t" $2 }'
}

# rw_path_under_root <path> <root_local> <worker_root>
# Maps a focus-side path inside the root onto the worker; a path outside
# the root maps to the worker root itself.
rw_path_under_root() {
  local path="$1" root="$2" worker_root="$3"
  case "$path" in
    "$root") printf '%s\n' "$worker_root" ;;
    "$root"/*) printf '%s/%s\n' "$worker_root" "${path#"$root"/}" ;;
    *) printf '%s\n' "$worker_root" ;;
  esac
}

# rw_is_idle_command <pane_current_command> -- a shell or an editor: safe to
# replace (editors only lose unsaved buffers, which the picker warns about).
rw_is_idle_command() {
  case "$1" in
    zsh | bash | sh | fish | dash | ksh | -zsh | -bash | nvim | vim | vi) return 0 ;;
  esac
  return 1
}

# rw_mirror_push_from_record <worker> <worker_home> <root_id>
# Pushes the focus record (rewritten for the worker: root_local = the
# worker's own path) and both manifests to the worker's mirror dir.
rw_mirror_push_from_record() {
  local worker="$1" worker_home="$2" root_id="$3" json
  json="$(rw_owned_record_read "$root_id")" || return 1
  rw_mirror_push_json "$worker" "$worker_home" "$root_id" "$json" "$(rw_owned_record_dir "$root_id")"
}

# rw_mirror_push_json <worker> <worker_home> <root_id> <record-json> [manifest-dir]
# Pushes an explicit mirror record (and manifest.*.tsv from [manifest-dir]).
rw_mirror_push_json() {
  local worker="$1" worker_home="$2" root_id="$3" json="$4" mdir="${5:-}" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rw-mirror.XXXXXX")"
  printf '%s' "$json" | jq -c '.root_local = .worker_root' >"$tmp/record.json"
  if [ -n "$mdir" ]; then
    [ -f "$mdir/manifest.focus.tsv" ] && cp "$mdir/manifest.focus.tsv" "$tmp/"
    [ -f "$mdir/manifest.worker.tsv" ] && cp "$mdir/manifest.worker.tsv" "$tmp/"
  fi
  rw_worker_mirror_push "$worker" "$worker_home" "$root_id" "$tmp"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

# rw_release_pane <pane_id> <dir>
# Replaces a pane's root process (attach-loop -> ssh) with tmux's local
# shell in <dir>, keeping the pane id, layout and window, and clears its
# remote options. Atomic via respawn-pane -k: an attach loop never sees a
# tombstone first and takes its intentional-close path (2026-08-09).
rw_release_pane() {
  local pane_id="$1" dir="$2" shell cmd
  shell="$(tmux show-options -gv default-shell 2>/dev/null || true)"
  if [ -z "$shell" ] || [ ! -x "$shell" ]; then
    shell="${SHELL:-/bin/sh}"
  fi
  printf -v cmd 'exec %q -l' "$shell"
  [ -d "$dir" ] || dir="$HOME"
  tmux respawn-pane -k -t "$pane_id" -c "$dir" "$cmd" 2>/dev/null || return 1
  local opt
  for opt in @rw-endpoint @rw-worker @rw-workspace @rw-root-id @remote-host @workspace-resurrect-skip; do
    rw_pane_unset "$pane_id" "$opt"
  done
  return 0
}

# rw_reattach_pane <pane_id> <endpoint_id> <root_id> <dir>
# The inverse of rw_release_pane: the pane runs the endpoint's attach loop
# again (used to roll a failed hand-back back).
rw_reattach_pane() {
  local pane_id="$1" endpoint_id="$2" root_id="$3" dir="$4" ej cmd
  ej="$(rw_read_endpoint "$endpoint_id")" || return 1
  [ -d "$dir" ] || dir="$HOME"
  printf -v cmd '%q %q' "$RW_ROOTS_DIR/attach-loop.sh" "$endpoint_id"
  tmux respawn-pane -k -t "$pane_id" -c "$dir" "$cmd" 2>/dev/null || return 1
  rw_pane_set "$pane_id" @rw-endpoint "$endpoint_id"
  rw_pane_set "$pane_id" @rw-worker "$(printf '%s' "$ej" | jq -r '.worker')"
  rw_pane_set "$pane_id" @rw-workspace "$(printf '%s' "$ej" | jq -r '.workspace.remote_path // empty')"
  rw_pane_set "$pane_id" @rw-root-id "$root_id"
  return 0
}

# rw_wait_local_shell <pane_id> -- up to ~10s for the pane to show a shell.
rw_wait_local_shell() {
  local pane_id="$1" i=0 cmd
  while [ "$i" -lt 20 ]; do
    cmd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
    case "$cmd" in
      zsh | bash | sh | fish | -zsh | -bash) return 0 ;;
    esac
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

# rw_stop_local_agent <pane_id> <provider>
# Stops the provider's own processes under the pane (never a blind child
# walk: claude keeps helper children), then waits for the pane's shell.
rw_stop_local_agent() {
  local pane_id="$1" provider="$2" pane_pid pids p
  pane_pid="$(tmux display-message -pt "$pane_id" -F '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$pane_pid" ] || return 1
  pids="$(ps axo pid=,ppid=,command= 2>/dev/null | rw_ps_tree_match_pids "$(rw_provider_pattern "$provider")" "$pane_pid")"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086 # pid list is intentionally word-split
    kill -TERM $pids 2>/dev/null || true
    sleep 0.5
    for p in $pids; do
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    done
  fi
  rw_wait_local_shell "$pane_id"
}

# rw_stop_remote_agent <worker> <session_name> <provider>
# Same, for the agent inside a worker endpoint session: its process tree is
# read over ssh and matched here with the same per-provider pattern.
rw_stop_remote_agent() {
  local worker="$1" session_name="$2" provider="$3" listing pane_pids pids
  listing="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "tmux list-panes -t $(rw_shquote "=$session_name") -F '#{pane_pid}' 2>/dev/null; echo ---; ps axo pid=,ppid=,command=" \
    </dev/null 2>/dev/null)" || return 1
  pane_pids="$(printf '%s\n' "$listing" | sed '/^---$/,$d' | tr '\n' ' ')"
  [ -n "${pane_pids// /}" ] || return 0
  # shellcheck disable=SC2086 # pane pid list intentionally expands into roots
  pids="$(printf '%s\n' "$listing" | sed '1,/^---$/d' | rw_ps_tree_match_pids "$(rw_provider_pattern "$provider")" $pane_pids | tr '\n' ' ')"
  [ -n "${pids// /}" ] || return 0
  rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "kill -TERM $pids 2>/dev/null; sleep 0.5; kill -KILL $pids 2>/dev/null; true" </dev/null >/dev/null 2>&1
}

# rw_forget_worker_copy <worker> <worker_home> <root_id> <root_rel>
# Deletes the worker copy and its mirror record. The copy itself is deleted
# only when the mirror names the same root_rel AND records that rw created
# that directory (`"worker_root_created":true`); a directory that existed
# before the first handoff is left in place and only the mirror goes.
# Prints one of: deleted | kept | no-mirror. Returns 6 when unreachable.
rw_forget_worker_copy() {
  local worker="$1" worker_home="$2" root_id="$3" root_rel="$4" mirror root out status=0 wstate
  case "$root_rel" in '' | /* | '~'* | ..* | */..*) return 7 ;; esac
  mirror="$(rw_worker_mirror_dir "$worker_home" "$root_id")"
  root="${worker_home%/}/$root_rel"
  wstate="$(rw_state_dir_at "$worker_home")"
  # Besides the copy: the root's backups and staging on the worker always go,
  # and when the copy goes, so do parent directories it leaves empty (never
  # a top-level folder of the worker's home).
  out="$(rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" "
    rm -rf -- $(rw_shquote "$wstate/handoff-backups/root-$root_id") $(rw_shquote "$wstate/handoff-staging/root-$root_id")
    h=$(rw_shquote "${worker_home%/}")
    m=$(rw_shquote "$mirror"); r=$(rw_shquote "$root")
    rmparents() { p=\"\$(dirname \"\$1\")\"; while [ \"\$(dirname \"\$p\")\" != \"\$h\" ] && [ \"\$p\" != \"\$h\" ] && rmdir \"\$p\" 2>/dev/null; do p=\"\$(dirname \"\$p\")\"; done; }
    if [ -f \"\$m/record.json\" ] && sed 's/\"[[:space:]]*:[[:space:]]*/\":/g' \"\$m/record.json\" | grep -Fq $(rw_shquote "\"root_rel\":\"$root_rel\""); then
      if sed 's/\"[[:space:]]*:[[:space:]]*/\":/g' \"\$m/record.json\" | grep -Fq '\"worker_root_created\":true'; then
        if rm -rf -- \"\$r\" && rm -rf -- \"\$m\"; then rmparents \"\$r\"; echo deleted; else echo failed; fi
      else
        rm -rf -- \"\$m\" && echo kept
      fi
    else
      echo no-mirror
    fi" </dev/null 2>/dev/null)" || status=$?
  [ "$status" -eq 0 ] || return 6
  printf '%s\n' "$out"
}

# rw_close_root_endpoints <root_id> <reason> [endpoint ids...]
# Tombstone-first close of each endpoint (kills its worker session when
# reachable) and removes it from the record.
rw_close_root_endpoints() {
  local root_id="$1" reason="$2" e w workers=" "
  shift 2
  for e in "$@"; do
    [ -n "$e" ] || continue
    w="$(rw_read_endpoint "$e" 2>/dev/null | jq -r '.worker // empty' 2>/dev/null)"
    [ -n "$w" ] && case "$workers" in *" $w "*) ;; *) workers="$workers$w " ;; esac
    rw_close_endpoint_core "$e" "$reason" </dev/null
    rw_record_remove_endpoint "$root_id" "$e"
  done
  # One verified save per worker, so its snapshot forgets the closed sessions.
  for w in $workers; do rw_worker_request_save "$w"; done
}

# rw_endpoint_has_agent <endpoint_id> -- a handed-off agent runs in it.
rw_endpoint_has_agent() {
  [ "$(rw_read_endpoint "$1" 2>/dev/null | jq -r '.agent.state // empty' 2>/dev/null)" = "handed-off" ]
}

# rw_reconcile_pending <worker> <worker_home>
# Runs every pending action recorded for <worker>, now that it answered:
#   pending.action = forget    -> delete the worker copy (when rw created
#                                 it) and mirror, close the endpoints, drop
#                                 the focus record
#   pending.action = reconcile -> (after `rw reclaim`) close the root's
#                                 endpoints EXCEPT those running a handed-off
#                                 agent, which are never closed automatically
#                                 (`rw close --endpoint <id>` once its work is
#                                 rescued); mark the mirror stale and
#                                 focus-owned; keep the worker copy; drop the
#                                 focus record
#   endpoint pending.action = close -> (after `rw switch --to local --force`
#                                 released its pane while <worker> was
#                                 unreachable) close the endpoint: its
#                                 session (and anything still running in it)
#                                 and visit marker go; an owned one's mirror
#                                 is rewritten from the record
# Each root whose owner changed gets its off-owner flags recomputed (CS3).
# Roots another rw process holds locked are skipped (next contact). Best
# effort: a failure leaves the record pending.
rw_reconcile_pending() {
  local worker="$1" worker_home="$2" rec root_id root_rel root_local action eps closable kept e out
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    root_id="$(printf '%s' "$rec" | jq -r '.root_id')"
    root_rel="$(printf '%s' "$rec" | jq -r '.root_rel')"
    root_local="$(printf '%s' "$rec" | jq -r '.root_local // empty')"
    action="$(printf '%s' "$rec" | jq -r '.pending.action // empty')"
    rw_root_lock "$root_id" || continue
    # shellcheck disable=SC2207 # endpoint ids are fixed-format hex
    eps=($(printf '%s' "$rec" | jq -r '.endpoints[]?'))
    case "$action" in
      forget)
        out="$(rw_forget_worker_copy "$worker" "$worker_home" "$root_id" "$root_rel")" || continue
        rw_close_root_endpoints "$root_id" "forget" ${eps[@]+"${eps[@]}"}
        rw_owned_record_remove "$root_id"
        rw_held_unmark "$worker" "$root_id"
        [ -z "$root_local" ] || rw_refresh_indicators --root "$root_local"
        rw_log_event "forget" "" "$worker" "" "success" "root=$root_rel pending=1 worker_copy=$out"
        ;;
      reconcile)
        closable=()
        kept=()
        for e in ${eps[@]+"${eps[@]}"}; do
          if rw_endpoint_has_agent "$e"; then kept+=("$e"); else closable+=("$e"); fi
        done
        rw_close_root_endpoints "$root_id" "reconcile" ${closable[@]+"${closable[@]}"}
        rw_mirror_push_json "$worker" "$worker_home" "$root_id" \
          "$(printf '%s' "$rec" | jq -c '.owner = "focus" | .endpoints = [] | .stale_worker = true | del(.pending)')" || continue
        rw_owned_record_remove "$root_id"
        [ -z "$root_local" ] || rw_refresh_indicators --root "$root_local"
        if [ "${#kept[@]}" -gt 0 ]; then
          rw_warn "rw: the remote agent(s) on endpoint(s) ${kept[*]} kept running on $worker's stale copy of $root_rel; close each with 'rw close --endpoint <id>' once its work is rescued."
        fi
        rw_log_event "reconcile" "" "$worker" "" "success" "root=$root_rel pending=1 closed=${#closable[@]} kept_agents=${#kept[@]}"
        ;;
    esac
  done < <(rw_owned_records_json | jq -c --arg w "$worker" '.[] | select(.worker == $w and .pending != null)')

  # Held entries with a pending forget whose focus record is gone (a second
  # unreachable worker during one `rw forget`).
  local f
  for f in "$(rw_held_dir)/$worker"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.pending.action // empty' "$f" 2>/dev/null)" = "forget" ] || continue
    root_id="$(jq -r '.root_id' "$f")"
    root_rel="$(jq -r '.root_rel' "$f")"
    rw_root_lock "$root_id" || continue
    out="$(rw_forget_worker_copy "$worker" "$worker_home" "$root_id" "$root_rel")" || continue
    rm -f "$f"
    rw_log_event "forget" "" "$worker" "" "success" "root=$root_rel pending=1 worker_copy=$out"
  done

  # Endpoints released while <worker> was unreachable (rw switch --force).
  local ej
  for f in "$(rw_endpoints_dir)"/*.json; do
    [ -f "$f" ] || continue
    ej="$(cat "$f" 2>/dev/null)" || continue
    [ "$(printf '%s' "$ej" | jq -r --arg w "$worker" 'select(.worker == $w) | .pending.action // empty' 2>/dev/null)" = "close" ] ||
      continue
    e="$(printf '%s' "$ej" | jq -r '.endpoint_id // empty')"
    [ -n "$e" ] || continue
    root_id="$(printf '%s' "$ej" | jq -r 'select((.kind // "owned") == "owned") | .root_id // empty')"
    if [ -n "$root_id" ] && rw_owned_record_read "$root_id" >/dev/null 2>&1; then
      rw_root_lock "$root_id" || continue
    fi
    rw_close_endpoint_core "$e" "pending-close" </dev/null
    if [ -n "$root_id" ] && rw_owned_record_read "$root_id" >/dev/null 2>&1; then
      rw_record_remove_endpoint "$root_id" "$e"
      rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null ||
        rw_warn "rw: could not rewrite the ownership mirror on '$worker' after closing endpoint $e (rewritten on the next ownership change)."
    fi
    rw_worker_request_save "$worker"
    rw_log_event "reconcile" "$e" "$worker" "" "success" "pending_close=1"
  done
  return 0
}

# rw_worker_agent_probe <worker> <session_name>...
# One ssh round trip that shows what each endpoint session is running NOW:
#   <session><TAB><pane_id><TAB><pane_pid><TAB><@agent_state><TAB><agent-state JSON or empty><TAB><pane_current_command>
# (@agent_state is the agent-state publisher's pane option on the worker:
# idle, working, awaiting, ...; empty when no agent ever published one)
# per session, then a `---` line, then the worker's `ps axo pid=,ppid=,command=`.
# The agent state is the worker's server-scoped SessionStart record
# (tmux-workspace-resurrect: <state>/agents/server-<pid>-<start>/pane-N.json),
# never the legacy flat file. Returns 6 when the worker cannot be reached.
rw_worker_agent_probe() {
  local worker="$1" script s
  shift
  script="$(mktemp "${TMPDIR:-/tmp}/rw-agent-probe.XXXXXX")"
  {
    printf 'set -u\n'
    printf '__rw_sessions=('
    for s in "$@"; do printf ' %q' "$s"; done
    printf ' )\n'
    cat <<'EOS'
sid="$(tmux display-message -p '#{pid}:#{start_time}' 2>/dev/null || true)"
sd="${TMUX_WORKSPACE_RESURRECT_STATE_DIR:-}"
[ -n "$sd" ] || sd="$(tmux show-environment -g TMUX_WORKSPACE_RESURRECT_STATE_DIR 2>/dev/null | sed -n 's/^TMUX_WORKSPACE_RESURRECT_STATE_DIR=//p')"
[ -n "$sd" ] || sd="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-workspace-resurrect"
for s in ${__rw_sessions[@]+"${__rw_sessions[@]}"}; do
  line="$(tmux list-panes -t "=$s" -F '#{pane_id} #{pane_pid} #{pane_current_command}' 2>/dev/null | head -n1)"
  pane="" ppid="" pcmd=""
  [ -n "$line" ] && read -r pane ppid pcmd <<<"$line"
  st="" as=""
  [ -n "$pane" ] && as="$(tmux show-option -pqvt "$pane" @agent_state 2>/dev/null || true)"
  if [ -n "$pane" ] && [ -n "$sid" ]; then
    f="$sd/agents/server-${sid/:/-}/pane-${pane#%}.json"
    [ -f "$f" ] && st="$(tr -d '\n' <"$f")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$pane" "$ppid" "$as" "$st" "$pcmd"
done
echo ---
ps axo pid=,ppid=,command=
EOS
  } >"$script"
  rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "bash -s" <"$script" 2>/dev/null
  local status=$?
  rm -f "$script"
  [ "$status" -eq 0 ] || return 6
}

# rw_live_provider <ps-output-file> <pane_pid>
# The provider whose process runs under the pane right now, or nothing.
rw_live_provider() {
  local ps_file="$1" ppid="$2" p
  [ -n "$ppid" ] || return 0
  for p in claude pi; do
    if rw_ps_tree_matches "$(rw_provider_pattern "$p")" "$ppid" <"$ps_file"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
}

# rw_prune_root_backups <root_id> [worker worker_home]
# After a successful hand-back: keep only the newest backup of this root
# (focus side, and on the worker when given) and drop its staging dirs.
rw_prune_root_backups() {
  local root_id="$1" worker="${2:-}" worker_home="${3:-}" script
  # shellcheck disable=SC2016 # expands where the script runs
  script='keep() { [ -d "$1" ] || return 0; command ls -1t "$1" 2>/dev/null | tail -n +2 | while IFS= read -r d; do rm -rf -- "$1/$d"; done; }'
  bash -c "$script; keep $(rw_shquote "$(rw_state_dir)/handoff-backups/root-$root_id"); rm -rf -- $(rw_shquote "$(rw_state_dir)/handoff-staging/root-$root_id")" 2>/dev/null || true
  if [ -n "$worker" ] && [ -n "$worker_home" ]; then
    local ws
    ws="$(rw_state_dir_at "$worker_home")"
    rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "$script; keep $(rw_shquote "$ws/handoff-backups/root-$root_id"); rm -rf -- $(rw_shquote "$ws/handoff-staging/root-$root_id"); true" \
      </dev/null >/dev/null 2>&1 || true
  fi
}

# rw_forget_local_backups <root_id> -- the focus side's backups and staging.
rw_forget_local_backups() {
  rm -rf -- "$(rw_state_dir)/handoff-backups/root-$1" "$(rw_state_dir)/handoff-staging/root-$1"
}

# ---------------------------------------------------------------------------
# Pane host switching (docs/tasks/remote-owned-directories.md, "Pane host
# switching", S1-S8 and CS1-CS4): where a pane works, path mapping between
# machines, and endpoint creation shared by `rw open` and `rw switch`.
#
# Endpoint kinds (CS2): `owned` (absent `kind` reads as owned) is listed in
# its root's ownership record; `visit` is a pane on a worker that does not
# own its directory. A visit endpoint has the same hidden worker session and
# attach loop, is never listed in a record, and has a worker-side marker
# <worker state>/visits/<endpoint_id>.json so the worker's post-restore keeps
# its restored session. Closing any endpoint removes that marker.
# ---------------------------------------------------------------------------

# rw_map_home_path <abs-path> <from-home> <to-home>
# Maps a path between machines relative to the home directory (C1):
# <from-home> itself or anything under it moves under <to-home>; any other
# path (outside the home directory, e.g. /tmp) is printed unchanged.
rw_map_home_path() {
  local p="$1" from="${2%/}" to="${3%/}"
  case "$p" in
    "$from") printf '%s\n' "$to" ;;
    "$from"/*) printf '%s/%s\n' "$to" "${p#"$from"/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# rw_endpoint_worker_home <endpoint-json>
# The worker's home as the endpoint knows it: its `worker_home` (endpoints
# written by `rw open` / `rw switch` since X1), else workspace.worker_root
# minus root_rel. Empty when neither says.
rw_endpoint_worker_home() {
  printf '%s' "$1" | jq -r '
    if (.worker_home // "") != "" then .worker_home
    else ((.workspace.worker_root // "") as $w | (.root_rel // "") as $r
      | if $w != "" and $r != "" and ($w | endswith("/" + $r))
        then $w[0:(($w | length) - ($r | length) - 1)] else "" end)
    end' 2>/dev/null
}

# rw_endpoint_local_path <endpoint-json> <worker-path>
# A worker path of that endpoint mapped back to this machine: under the
# endpoint's worker root to its local root, else under the worker's home to
# this machine's home, else unchanged.
rw_endpoint_local_path() {
  local ej="$1" p="$2" wr rl wh
  wr="$(printf '%s' "$ej" | jq -r '.workspace.worker_root // empty' 2>/dev/null)"
  rl="$(printf '%s' "$ej" | jq -r '.workspace.root_local // empty' 2>/dev/null)"
  if [ -n "$wr" ] && [ -n "$rl" ]; then
    case "$p" in
      "$wr" | "$wr"/*)
        rw_map_home_path "$p" "$wr" "$rl"
        return 0
        ;;
    esac
  fi
  wh="$(rw_endpoint_worker_home "$ej")"
  if [ -n "$wh" ]; then
    rw_map_home_path "$p" "$wh" "$(rw_physical_path "$HOME")"
  else
    printf '%s\n' "$p"
  fi
}

# rw_endpoint_pane_local_path <endpoint-json> <worker-path>
# The directory a remote pane works in, as a path on this machine, from the
# worker cwd its session reports: rw_endpoint_local_path, except while the
# pane is still where its endpoint opened (workspace.remote_path) and that
# was only the nearest existing parent of its directory, because the
# directory did not exist on the remote (S3). The pane is then in its focus
# path as far as this machine is concerned, so a switch there and back, a
# split, a new window or the menu keep the directory the pane was switched
# from instead of moving it up to that parent (smoke test X4, 2026-11-18).
rw_endpoint_pane_local_path() {
  local ej="$1" p="$2" mapped rp fp
  mapped="$(rw_endpoint_local_path "$ej" "$p")"
  rp="$(printf '%s' "$ej" | jq -r '.workspace.remote_path // empty' 2>/dev/null)"
  fp="$(printf '%s' "$ej" | jq -r '.workspace.focus_path // empty' 2>/dev/null)"
  if [ -n "$rp" ] && [ -n "$fp" ] && [ "$p" = "$rp" ]; then
    case "$fp" in
      "${mapped%/}"/*)
        printf '%s\n' "$fp"
        return 0
        ;;
    esac
  fi
  printf '%s\n' "$mapped"
}

# rw_pane_dir <pane-id> [--live]
# The directory a pane works in, as a path on THIS machine (S1). A remote
# pane (its attach loop runs: @remote-host, and its @rw-endpoint is
# registered): the live worker cwd its hidden session reports as the pane
# title (set-titles-string '#{pane_current_path}', the directory chip's
# source) when that is an absolute path, mapped back through the endpoint
# (rw_endpoint_pane_local_path: the focus path while the pane is still in
# the parent it opened in for a directory the remote lacks); else the
# endpoint's focus path. A local pane: its pane_current_path. The path may
# not exist here (a directory only the remote has); rw_local_existing_dir
# finds where a local shell can start.
#
# --live first asks the worker for the hidden session's pane_current_path
# (rw_pane_remote_probe: one ssh with a hard deadline) and uses the title
# only when that fails. The title can lag: a hidden session has `status
# off`, and tmux re-sends a title only on a full redraw, so a `cd` on the
# worker reaches the title late (measured: over a minute on a throwaway
# pair of servers; on the real worker, whose shell redraws its prompt, about
# 0.5 s at 300-450 ms RTT in the X4 smoke test). Actions that open something in that directory (rw
# switch, including the one a split or prefix c runs in its new pane) use
# --live; a display, and anything a key binding waits on, uses the title.
rw_pane_dir() {
  local pane_id="$1" live="${2:-}" ep host ej title focus out
  ep="$(rw_pane_get "$pane_id" @rw-endpoint)"
  host="$(rw_pane_get "$pane_id" @remote-host)"
  if [ -n "$ep" ] && [ -n "$host" ] && ej="$(rw_read_endpoint "$ep" 2>/dev/null)"; then
    if [ "$live" = "--live" ] && out="$(rw_pane_remote_probe "$pane_id")"; then
      printf '%s\n' "${out%%"$RW_TAB"*}"
      return 0
    fi
    title="$(tmux display-message -pt "$pane_id" -F '#{pane_title}' 2>/dev/null || true)"
    case "$title" in
      /*)
        [ "$title" = "/" ] || title="${title%/}"
        rw_endpoint_pane_local_path "$ej" "$title"
        return 0
        ;;
    esac
    focus="$(printf '%s' "$ej" | jq -r '.workspace.focus_path // empty' 2>/dev/null)"
    if [ -n "$focus" ]; then
      printf '%s\n' "$focus"
      return 0
    fi
  fi
  tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null
}

# rw_pane_remote_probe <pane-id>   (pinned interface I3, fix wave A)
# For a remote pane (@remote-host set and a registered @rw-endpoint): ONE
# ssh to its remote that reads the endpoint's hidden session, under a HARD
# deadline of the status timeout. Prints
#   <its directory, mapped to this machine><TAB><its pane_current_command>
# The ssh runs in the background and is killed at the deadline, because
# ssh's ConnectTimeout does not bound a ControlMaster whose remote end is
# dead. Exit 0; 6 on the deadline, an unreachable remote, or no answer (the
# session is missing there); 1 when the pane is not a remote pane.
rw_pane_remote_probe() {
  local pane_id="$1" ep host ej worker limit out pid i=0 status=0 line path cmd=""
  ep="$(rw_pane_get "$pane_id" @rw-endpoint)"
  host="$(rw_pane_get "$pane_id" @remote-host)"
  [ -n "$ep" ] && [ -n "$host" ] && ej="$(rw_read_endpoint "$ep" 2>/dev/null)" || return 1
  worker="$(printf '%s' "$ej" | jq -r '.worker // empty' 2>/dev/null)"
  [ -n "$worker" ] || worker="$host"
  limit="$(rw_ssh_status_timeout)"
  case "$limit" in '' | *[!0-9]* | 0) limit=3 ;; esac
  out="$(mktemp "${TMPDIR:-/tmp}/rw-pane-probe.XXXXXX")" || return 6
  # A simple command run with & is exec'd by the forked shell, so $! is
  # ssh itself and the kill below reaches it.
  "$(rw_ssh_bin)" -o BatchMode=yes -o ConnectTimeout="$limit" "$worker" \
    "tmux display-message -p -t $(rw_shquote "=$(rw_session_name "$ep"):") $(rw_shquote "#{pane_current_path}${RW_TAB}#{pane_current_command}")" \
    </dev/null >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((limit * 10)) ]; then
      # Grouped under 2>/dev/null: bash reports a job killed by a signal
      # ("Terminated") on its stderr when it reaps it.
      {
        kill -TERM "$pid"
        sleep 0.1
        kill -KILL "$pid"
        wait "$pid"
      } 2>/dev/null
      rm -f "$out"
      return 6
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || status=$?
  line="$(tail -n 1 "$out" 2>/dev/null)"
  rm -f "$out"
  [ "$status" -eq 0 ] || return 6
  path="${line%%"$RW_TAB"*}"
  case "$line" in *"$RW_TAB"*) cmd="${line#*"$RW_TAB"}" ;; esac
  case "$path" in /*) : ;; *) return 6 ;; esac
  [ "$path" = "/" ] || path="${path%/}"
  printf '%s\t%s\n' "$(rw_endpoint_pane_local_path "$ej" "$path")" "$cmd"
}

# rw_owner_for_path <abs-path>   (pinned interface I2, fix wave A)
# The owner of a path as the off-owner chip sees it: prints
#   <root_id><TAB><worker><TAB><root_local>
# for the longest enclosing worker-owned root, ignoring a record whose
# pending action is `forget` (it is going away) and a mirror record whose
# focus_machine_id is not this machine's (on a worker, the copies it holds
# are owned there). Exit 1 when the path is owned by this machine. The same
# filters as scripts/rw-refresh-indicators.sh. No ssh.
rw_owner_for_path() {
  local path own out
  path="$(rw_physical_path "${1:?path required}")"
  own="$(cat "$(rw_machine_id_file)" 2>/dev/null || true)"
  out="$(rw_owned_records_json | jq -r --arg p "$path" --arg own "$own" '
    [ .[] | select(.owner == "worker")
      | select((.pending.action // "") != "forget")
      | select((.focus_machine_id // "") == "" or .focus_machine_id == $own)
      | select((.root_local // "") != "" and (.worker // "") != "")
      | select(.root_local as $r | $p == $r or ($p | startswith($r + "/"))) ]
    | sort_by(.root_local | length) | last
    | if . == null then empty else "\(.root_id)\t\(.worker)\t\(.root_local)" end' 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# rw_local_existing_dir <abs-path> -- the path, or its nearest existing parent.
rw_local_existing_dir() {
  local d="${1:-/}"
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  printf '%s\n' "$d"
}

# rw_worker_existing_dir <worker> <abs-path> -- the same on the worker (one
# ssh). Returns 6 when the worker cannot be reached.
rw_worker_existing_dir() {
  local out status=0
  # shellcheck disable=SC2016 # expanded by the worker's shell
  out="$(rw_ssh_batch "$1" "$(rw_ssh_status_timeout)" \
    "d=$(rw_shquote "$2"); "'while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done; printf "dir:%s\n" "$d"' \
    </dev/null 2>/dev/null)" || status=$?
  out="$(printf '%s\n' "$out" | sed -n 's/^dir://p' | tail -n 1)"
  [ "$status" -eq 0 ] && [ -n "$out" ] || return 6
  printf '%s\n' "$out"
}

# rw_visit_marker_push <worker> <worker_home> <endpoint_id> <session_name> <worker_path>
# Writes the visit endpoint's worker-side marker (see above), 0600 in a 0700
# directory. Non-zero when it could not be written.
rw_visit_marker_push() {
  local worker="$1" wh="$2" ep="$3" sess="$4" wpath="$5" dir json q tmp
  dir="$(rw_state_dir_at "$wh")/visits"
  q="$(rw_shquote "$dir")"
  tmp="$(rw_shquote "$dir/.$ep.json.tmp")"
  json="$(jq -nc --arg e "$ep" --arg s "$sess" --arg f "$(rw_machine_id)" --arg p "$wpath" --arg at "$(rw_now_iso)" \
    '{endpoint_id: $e, session_name: $s, focus_machine_id: $f, worker_path: $p, kind: "visit", created_at: $at}')"
  printf '%s\n' "$json" | rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "mkdir -p $q && chmod 0700 $q && cat >$tmp && chmod 0600 $tmp && mv -f $tmp $(rw_shquote "$dir/$ep.json")" \
    >/dev/null 2>&1
}

# rw_visit_marker_remove <worker> <worker_home> <endpoint_id>...
# Removes the markers in one ssh; non-zero when the worker did not answer.
rw_visit_marker_remove() {
  local worker="$1" wh="$2" files="" e
  shift 2
  for e in "$@"; do files="$files $(rw_shquote "$(rw_state_dir_at "$wh")/visits/$e.json")"; done
  [ -n "$files" ] || return 0
  rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "rm -f$files" </dev/null >/dev/null 2>&1
}

# rw_endpoint_open <kind> <worker> <worker_home> <worker_identity> <pane_id>
#                  <root_id> <root_rel> <root_kind> <root_local> <worker_root>
#                  <focus_path> <remote_path> <launch>
# Creates the hidden worker session of a new endpoint for <pane_id> in
# <remote_path> and registers it: endpoints/<id>.json (C3 fields, plus
# `kind` and `worker_home`); an owned endpoint joins its record and the
# worker mirror, a visit endpoint gets its worker-side marker. <root_id> and
# <root_rel> may be empty for a visit (no enclosing root). The pane is not
# bound yet: the caller runs rw_bind_pane once everything else is in place.
# Sets RW_ENDPOINT_ID. Returns 0, or 1 / 6 (unreachable) with
# RW_WORKER_SERVER_ERROR set and nothing left registered.
# shellcheck disable=SC2034 # read by the callers
RW_ENDPOINT_ID=""
rw_endpoint_open() {
  local kind="$1" worker="$2" worker_home="$3" identity="$4" pane_id="$5"
  local root_id="$6" root_rel="$7" root_kind="$8" root_local="$9" worker_root="${10}"
  local focus_path="${11}" remote_path="${12}" launch="${13}"
  local endpoint_id session_name status=0 session_uuid sname windex pindex now
  RW_ENDPOINT_ID=""
  endpoint_id="$(rw_new_short_id)"
  session_name="$(rw_session_name "$endpoint_id")"
  # A worker with no tmux server gets one through its boot restore wrapper
  # (never a bare new-session); a server whose last restore did not
  # complete is refused, since nothing created there would ever be saved.
  rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)" \
    </dev/null >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || return "$status"

  session_uuid="$(tmux show-option -t "$pane_id" -qv @session-uuid 2>/dev/null || true)"
  [ -n "$session_uuid" ] || session_uuid="$(rw_pane_get "$pane_id" @rw-session-uuid)"
  sname="$(tmux display-message -pt "$pane_id" -F '#{session_name}' 2>/dev/null || true)"
  windex="$(tmux display-message -pt "$pane_id" -F '#{window_index}' 2>/dev/null || true)"
  pindex="$(tmux display-message -pt "$pane_id" -F '#{pane_index}' 2>/dev/null || true)"
  case "$windex" in '' | *[!0-9]*) windex=0 ;; esac
  case "$pindex" in '' | *[!0-9]*) pindex=0 ;; esac
  now="$(rw_now_iso)"

  rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$(jq -nc \
    --arg endpoint_id "$endpoint_id" \
    --arg kind "$kind" \
    --arg worker "$worker" \
    --arg worker_identity "$identity" \
    --arg worker_home "$worker_home" \
    --arg focus_machine_id "$(rw_machine_id)" \
    --arg root_id "$root_id" \
    --arg root_rel "$root_rel" \
    --arg focus_session_uuid "$session_uuid" \
    --arg focus_session_name "$sname" \
    --argjson focus_window_index "$windex" \
    --argjson focus_pane_index "$pindex" \
    --arg focus_pane_id "$pane_id" \
    --arg mode "$root_kind" \
    --arg focus_path "$focus_path" \
    --arg remote_path "$remote_path" \
    --arg root_local "$root_local" \
    --arg worker_root "$worker_root" \
    --arg launch "$launch" \
    --arg now "$now" \
    '{endpoint_id: $endpoint_id, kind: $kind, worker: $worker, worker_identity: $worker_identity,
      worker_home: $worker_home, focus_machine_id: $focus_machine_id,
      root_id: (if $root_id == "" then null else $root_id end),
      root_rel: (if $root_rel == "" then null else $root_rel end),
      focus_session_uuid: $focus_session_uuid, focus_session_name: $focus_session_name,
      focus_window_index: $focus_window_index, focus_pane_index: $focus_pane_index,
      focus_pane_id: $focus_pane_id,
      workspace: {mode: $mode, identity: "", focus_path: $focus_path, remote_path: $remote_path,
        root_local: $root_local, worker_root: $worker_root},
      launch_intent: {worker: $worker, workspace_arg: $launch},
      agent: {provider: null, session_id: null, resume_intent: null, state: null},
      editor: null,
      created_at: $now, updated_at: $now, generation: 1}')"

  if [ "$kind" = "owned" ]; then
    # Fix wave A, finding 5: the endpoint is owned only once the record AND
    # the worker's mirror list it. Without the mirror the worker's
    # post-restore would kill its session at the next boot, so a failed push
    # is a failure (the endpoint is discarded, nothing is left registered).
    if ! rw_owned_record_read "$root_id" 2>/dev/null |
      jq -e --arg w "$worker" '.owner == "worker" and .worker == $w' >/dev/null 2>&1 ||
      ! rw_record_add_endpoint "$root_id" "$endpoint_id"; then
      rw_close_endpoint_core "$endpoint_id" "record-add-failed" </dev/null
      # shellcheck disable=SC2034 # read by the callers
      RW_WORKER_SERVER_ERROR="the root is no longer remote on '$worker' (its ownership record changed)"
      return 1
    fi
    if ! rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null; then
      rw_record_remove_endpoint "$root_id" "$endpoint_id"
      rw_close_endpoint_core "$endpoint_id" "mirror-push-failed" </dev/null
      # shellcheck disable=SC2034 # read by the callers
      RW_WORKER_SERVER_ERROR="could not record the pane in the ownership mirror on '$worker'"
      return 1
    fi
  elif ! rw_visit_marker_push "$worker" "$worker_home" "$endpoint_id" "$session_name" "$remote_path" </dev/null; then
    rw_close_endpoint_core "$endpoint_id" "visit-marker-failed" </dev/null
    # shellcheck disable=SC2034 # read by the callers
    RW_WORKER_SERVER_ERROR="could not record the pane on '$worker'"
    return 1
  fi
  # shellcheck disable=SC2034 # read by the callers
  RW_ENDPOINT_ID="$endpoint_id"
  return 0
}

# rw_endpoint_discard <endpoint_id> <reason>
# Undoes rw_endpoint_open (a later step failed): tombstone-first close of the
# endpoint and its worker session (and visit marker); an owned endpoint
# also leaves its record and mirror.
rw_endpoint_discard() {
  local ep="$1" reason="$2" ej root_id worker wh
  ej="$(rw_read_endpoint "$ep" 2>/dev/null || true)"
  root_id="$(printf '%s' "$ej" | jq -r 'select((.kind // "owned") == "owned") | .root_id // empty' 2>/dev/null)"
  worker="$(printf '%s' "$ej" | jq -r '.worker // empty' 2>/dev/null)"
  wh="$(rw_endpoint_worker_home "$ej")"
  rw_close_endpoint_core "$ep" "$reason" </dev/null
  if [ -n "$root_id" ] && rw_owned_record_read "$root_id" >/dev/null 2>&1; then
    rw_record_remove_endpoint "$root_id" "$ep"
    [ -n "$worker" ] && [ -n "$wh" ] && rw_mirror_push_from_record "$worker" "$wh" "$root_id" </dev/null
  fi
  [ -n "$worker" ] && rw_worker_request_save "$worker"
  return 0
}

# rw_bind_pane <pane_id> <endpoint_id>
# Stamps the endpoint's pane options on <pane_id> (the attach loop itself
# sets @remote-host when it runs) and clears @workspace-last-command, which
# would otherwise be replayed by a restore (C3).
rw_bind_pane() {
  local pane_id="$1" ep="$2" ej v
  ej="$(rw_read_endpoint "$ep")" || return 1
  rw_pane_set "$pane_id" @rw-endpoint "$ep"
  rw_pane_set "$pane_id" @rw-worker "$(printf '%s' "$ej" | jq -r '.worker')"
  rw_pane_set "$pane_id" @rw-workspace "$(printf '%s' "$ej" | jq -r '.workspace.remote_path // empty')"
  v="$(printf '%s' "$ej" | jq -r '.root_id // empty')"
  if [ -n "$v" ]; then rw_pane_set "$pane_id" @rw-root-id "$v"; else rw_pane_unset "$pane_id" @rw-root-id; fi
  v="$(printf '%s' "$ej" | jq -r '.focus_session_uuid // empty')"
  [ -n "$v" ] && rw_pane_set "$pane_id" @rw-session-uuid "$v"
  rw_pane_unset "$pane_id" @workspace-last-command
  return 0
}
