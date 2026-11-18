#!/usr/bin/env bash
# Root-level operations shared by rw handoff / handback / open / forget /
# reclaim. Sourced only; never executed directly. Builds on common.sh
# (ownership records, ssh transport, endpoint registry, per-root locks) --
# see the ownership section there for the record layout, and
# docs/tasks/mini-remote-sessions.md for the contracts.

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

# rw_root_bound_panes <root_id> <endpoint-ids...>
# Panes bound to the root: @rw-root-id equals it, or @rw-endpoint is one of
# the record's endpoints (a pane restored before @rw-root-id existed).
# Prints pane_id<TAB>endpoint_id.
rw_root_bound_panes() {
  local root_id="$1"
  shift
  tmux list-panes -a -F "#{pane_id}${RW_TAB}#{@rw-endpoint}${RW_TAB}#{@rw-root-id}" 2>/dev/null |
    awk -F '\t' -v id="$root_id" -v eps="$*" '
      BEGIN { n = split(eps, e, " "); for (i = 1; i <= n; i++) want[e[i]] = 1 }
      $2 != "" && ($3 == id || ($2 in want)) { print $1 "\t" $2 }'
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
# Roots another rw process holds locked are skipped (next contact). Best
# effort: a failure leaves the record pending.
rw_reconcile_pending() {
  local worker="$1" worker_home="$2" rec root_id root_rel action eps closable kept e out
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    root_id="$(printf '%s' "$rec" | jq -r '.root_id')"
    root_rel="$(printf '%s' "$rec" | jq -r '.root_rel')"
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
  return 0
}

# rw_worker_agent_probe <worker> <session_name>...
# One ssh round trip that shows what each endpoint session is running NOW:
#   <session><TAB><pane_id><TAB><pane_pid><TAB><@agent_state><TAB><agent-state JSON or empty>
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
  line="$(tmux list-panes -t "=$s" -F '#{pane_id} #{pane_pid}' 2>/dev/null | head -n1)"
  pane="${line%% *}"; ppid="${line#* }"
  [ -n "$line" ] || { pane=""; ppid=""; }
  st="" as=""
  [ -n "$pane" ] && as="$(tmux show-option -pqvt "$pane" @agent_state 2>/dev/null || true)"
  if [ -n "$pane" ] && [ -n "$sid" ]; then
    f="$sd/agents/server-${sid/:/-}/pane-${pane#%}.json"
    [ -f "$f" ] && st="$(tr -d '\n' <"$f")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$pane" "$ppid" "$as" "$st"
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
