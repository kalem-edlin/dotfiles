#!/usr/bin/env bash
# `rw handback` -- bring a remote root, and every pane working in it, back
# to this machine (docs/tasks/remote-owned-directories.md, P1 and contract C2).
#
# All or nothing. Order:
#   1. Find the root's ownership record (--root, the pane's @rw-root-id or
#      @rw-endpoint, or the cwd's enclosing remote root). Exit 7 when the
#      root is not remote. Take the per-root lock. Preflight the worker:
#      unreachable is exit 6 and nothing changes (see `rw reclaim`).
#   2. Agent version policy, inverted (the LOCAL CLI resumes now): a local
#      CLI older than the remote one aborts with exit 3.
#   3. Stop the remote agents, so the pull holds their last write.
#   4. ONE pull of the root (git channel + rsync channel with delete). The
#      frozen local copy is first checked against its stored manifest (exit
#      5 unless --resolve). The new manifests are stored right away, so a
#      retry after an interruption converges. On failure the remote agents
#      resume and the root stays remote.
#   5. Export and install every agent transcript locally; then give each
#      pane its local shell back (same pane id, layout, window) and resume
#      its agent there, verified. If ANY pane fails, everything rolls back:
#      local agents stopped, panes back on their attach loops, remote agents
#      resumed, the root stays remote (exit 1, nothing pending). An editor
#      (nvim, vim, vi) running in a remote pane is reopened in its laptop
#      pane (its nvim session, or its argv, with the root's paths
#      rewritten); best effort: one that does not come back is a warning.
#   6. Commit: close the worker sessions, delete the ownership record, and
#      rewrite the worker's mirror (owner focus, fresh manifests).
#
# Only the record's endpoints move (S8): visit panes of this root on other
# remotes (soft switches, `rw switch`) stay where they are.
#
# Must run on the focus machine from a local pane or popup, never from the
# worker side of a remote pane (that shell is on the worker).
#
# Usage: rw-handback.sh [--root <path>] [--pane <pane-id>] [--check-lfs]
#                       [--force-diverged] [--resolve overwrite|keep-both|abort]
#                       [--wait-idle [seconds]]
#
# A remote agent in the middle of a turn is never stopped: the hand-back
# refuses (exit 1) while any is `working`, or with --wait-idle waits up to
# <seconds> (default 300) for all of them to go idle first.
#
# Exit: 0 ok, 1 failure (rolled back), 2 git divergence, 3 agent CLI version
#       gate, 5 manifest conflict, 6 worker unreachable, 7 not a remote
#       root, 64 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_DIR="$SCRIPT_DIR/../libexec/sync"
# RW_ADAPTERS_DIR: test seam (tests/test_agent_flow.sh fakes the adapters).
ADAPTERS_DIR="${RW_ADAPTERS_DIR:-$SCRIPT_DIR/../libexec/adapters}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

# Worker-side guard: an rw endpoint session is named rw-<8hex>-<8hex>; a
# shell inside one is on the worker, where no ownership record exists.
if [ -n "${TMUX:-}" ]; then
  case "$(tmux display-message -p '#{session_name}' 2>/dev/null || true)" in
    rw-????????-????????)
      rw_die "rw handback: this shell is the remote side of a handed-off pane; run 'rw handback --root <path>' from a local pane or the picker instead." 64
      ;;
  esac
fi

root_arg=""
pane_id="${TMUX_PANE:-}"
check_lfs="false"
force_diverged="false"
resolve=""
wait_idle=""

while [ $# -gt 0 ]; do
  case "$1" in
    --wait-idle)
      case "${2:-}" in
        '' | -*) wait_idle=300; shift ;;
        *[!0-9]*) rw_die "rw handback: --wait-idle takes a number of seconds" 64 ;;
        *) wait_idle="$2"; shift 2 ;;
      esac
      ;;
    --root) root_arg="${2:?}"; shift 2 ;;
    --pane) pane_id="${2:?}"; shift 2 ;;
    --check-lfs) check_lfs="true"; shift ;;
    --force-diverged) force_diverged="true"; shift ;;
    --resolve) resolve="${2:?}"; shift 2 ;;
    *) rw_die "rw handback: unknown argument: $1" 64 ;;
  esac
done
case "$resolve" in '' | overwrite | keep-both | abort) : ;; *) rw_die "rw handback: --resolve must be overwrite, keep-both or abort" 64 ;; esac

start_ts="$(rw_now_epoch)"

# ---------------------------------------------------------------------------
# 1. Record
# ---------------------------------------------------------------------------

root_id=""
if [ -n "$root_arg" ]; then
  rel="$(rw_root_rel "$root_arg")" || rw_die "rw handback: '$root_arg' is not inside your home directory." 7
  root_id="$(rw_root_id "$rel")"
elif [ -n "$pane_id" ]; then
  root_id="$(rw_pane_get "$pane_id" @rw-root-id)"
  if [ -z "$root_id" ]; then
    ep="$(rw_pane_get "$pane_id" @rw-endpoint)"
    [ -n "$ep" ] && root_id="$(rw_read_endpoint "$ep" 2>/dev/null | jq -r '.root_id // empty')"
  fi
  if [ -z "$root_id" ]; then
    cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
    [ -n "$cwd" ] && root_id="$(rw_owned_root_for_path "$cwd" || true)"
  fi
else
  root_id="$(rw_owned_root_for_path "$(pwd -P)" || true)"
fi

record=""
[ -n "$root_id" ] && record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
if [ -z "$record" ] || [ "$(printf '%s' "$record" | jq -r '.owner')" != "worker" ]; then
  rw_die "rw handback: ${root_arg:-this pane} is not in a remote root; nothing to hand back." 7
fi

rw_root_lock_or_die "$root_id" "rw handback"
work="$(mktemp -d "${TMPDIR:-/tmp}/rw-handback.XXXXXX")"
trap 'rm -rf "$work"; rw_root_unlock_all' EXIT
# Re-read under the lock: a concurrent operation may have changed it.
record="$(rw_owned_record_read "$root_id" 2>/dev/null || true)"
[ -n "$record" ] && [ "$(printf '%s' "$record" | jq -r '.owner')" = "worker" ] ||
  rw_die "rw handback: ${root_arg:-this root} is no longer remote." 7

worker="$(printf '%s' "$record" | jq -r '.worker')"
root_rel="$(printf '%s' "$record" | jq -r '.root_rel')"
root_local="$(printf '%s' "$record" | jq -r '.root_local')"
kind="$(printf '%s' "$record" | jq -r '.kind')"
# shellcheck disable=SC2207 # endpoint ids are fixed-format hex
endpoints=($(printf '%s' "$record" | jq -r '.endpoints[]?'))
fail_event() { rw_log_event "handback" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "root=$root_rel $1"; }

rw_worker_known "$worker" || rw_die "rw handback: worker '$worker' (from the ownership record) is not declared in config.json" 1

preflight_args=(--worker "$worker")
[ "$check_lfs" = "true" ] && preflight_args+=(--check-lfs)
preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  code="$(rw_preflight_exit "$preflight_json")"
  fail_event "preflight_failed"
  if [ "$code" = "6" ]; then
    rw_warn "rw handback: '$worker' cannot be reached, so '$root_rel' was not handed back and nothing changed. If it will stay unreachable, 'rw reclaim $root_local' takes ownership back from the local (frozen) copy."
  fi
  exit "$code"
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"
worker_root="$(printf '%s' "$record" | jq -r '.worker_root // empty')"
[ -n "$worker_root" ] || worker_root="${worker_home%/}/$root_rel"

rw_reconcile_pending "$worker" "$worker_home"

# Endpoint data, index-aligned. The agents are discovered LIVE on the
# worker, not only taken from the endpoint records: an agent started in a
# remote pane after the handoff (or a different session than the one handed
# off) must come back too. A pane running an agent whose session cannot be
# identified refuses the whole hand-back before anything is stopped.
e_json=()
e_provider=()
e_session=()
e_pfocus=()
e_pworker=()
e_mode=()
e_resume_remote=()
ej_field() { printf '%s' "${e_json[$1]}" | jq -r "$2 // empty" 2>/dev/null; }

sessions=()
for e in ${endpoints[@]+"${endpoints[@]}"}; do sessions+=("$(rw_session_name "$e")"); done
# probe_agents -- refresh $work/probe(.ps); prints the remote sessions whose
# pane runs an agent that is in the middle of a turn (@agent_state working).
probe_agents() {
  local status=0 line sess ppid astate
  rw_worker_agent_probe "$worker" ${sessions[@]+"${sessions[@]}"} >"$work/probe" || status=$?
  if [ "$status" -ne 0 ]; then
    fail_event "agent_probe_unreachable"
    rw_die "rw handback: lost contact with '$worker' while checking its panes for agents; nothing changed." 6
  fi
  sed '1,/^---$/d' "$work/probe" >"$work/probe.ps"
  sed '/^---$/,$d' "$work/probe" | while IFS= read -r line; do
    sess="$(printf '%s' "$line" | cut -f1)"
    ppid="$(printf '%s' "$line" | cut -f3)"
    astate="$(printf '%s' "$line" | cut -f4)"
    [ "$astate" = "working" ] || continue
    [ -n "$(rw_live_provider "$work/probe.ps" "$ppid")" ] && printf '%s\n' "$sess"
  done
}
# Not in $(...): an unreachable worker must end the script, not a subshell.
probe_agents >"$work/busy"
busy="$(cat "$work/busy")"
if [ -n "$busy" ] && [ -n "$wait_idle" ]; then
  deadline=$(($(date +%s) + wait_idle))
  rw_warn "rw handback: waiting up to ${wait_idle}s for the remote agent(s) in $(printf '%s' "$busy" | paste -sd' ' -) to finish their turn..."
  while [ -n "$busy" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    probe_agents >"$work/busy"
    busy="$(cat "$work/busy")"
  done
fi
if [ -n "$busy" ]; then
  fail_event "remote_agent_working"
  rw_die "rw handback: the remote agent in $(printf '%s' "$busy" | paste -sd' ' -) is working (mid-turn); stopping it now would lose that turn. Nothing was moved or stopped. Retry when it is idle, or run 'rw handback --wait-idle'." 1
fi

# focus_path_for <worker path> -- the laptop path of a worker path in the root.
focus_path_for() {
  case "$1" in
    "$worker_root") printf '%s
' "$root_local" ;;
    "$worker_root"/*) printf '%s/%s
' "$root_local" "${1#"$worker_root"/}" ;;
    *) printf '%s
' "$root_local" ;;
  esac
}

for i in "${!endpoints[@]}"; do
  e_json[i]="$(rw_read_endpoint "${endpoints[$i]}" 2>/dev/null || true)"
  e_provider[i]="" e_session[i]="" e_pfocus[i]="" e_pworker[i]="" e_mode[i]="" e_resume_remote[i]=""
  case "$(ej_field "$i" '.role')" in tree | tree-editor) continue ;; esac
  rec_provider="$(printf '%s' "${e_json[$i]}" | jq -r 'select(.agent.state == "handed-off") | .agent.provider // empty' 2>/dev/null)"
  rec_session="$(ej_field "$i" '.agent.transcript_id')"
  [ -n "$rec_session" ] || rec_session="$(ej_field "$i" '.agent.session_id')"
  probe_line="$(sed '/^---$/,$d' "$work/probe" | awk -F '\t' -v s="${sessions[$i]}" '$1 == s { print; exit }')"
  live_ppid="$(printf '%s' "$probe_line" | cut -f3)"
  live_state="$(printf '%s' "$probe_line" | cut -f5)"
  live_provider="$(rw_live_provider "$work/probe.ps" "${live_ppid:-}")"
  if [ -n "$live_provider" ]; then
    live_tool="$(printf '%s' "${live_state:-}" | jq -r '.tool // empty' 2>/dev/null)"
    live_session="$(printf '%s' "${live_state:-}" | jq -r '.session_id // empty' 2>/dev/null)"
    live_cwd="$(printf '%s' "${live_state:-}" | jq -r '.cwd // empty' 2>/dev/null)"
    if [ "$live_tool" != "$live_provider" ] || [ -z "$live_session" ]; then
      fail_event "agent_unidentified:${endpoints[$i]}"
      rw_die "rw handback: a $live_provider agent is running in remote session ${sessions[$i]}, but its session cannot be identified (no SessionStart record on the remote for that pane), so it cannot be brought back. Nothing was moved or stopped; quit it there (or let it record its session), then retry." 1
    fi
    [ -x "$ADAPTERS_DIR/$live_provider" ] || rw_die "rw handback: no local $live_provider adapter; nothing was moved." 1
    e_provider[i]="$live_provider"
    e_session[i]="$live_session"
    e_pworker[i]="${live_cwd:-$(ej_field "$i" '.workspace.remote_path')}"
    e_pfocus[i]="$(focus_path_for "${e_pworker[$i]}")"
    if [ "$live_provider" = "$rec_provider" ] && [ "$live_session" = "$rec_session" ]; then
      e_mode[i]="$(ej_field "$i" '.agent.mode_flags')"
      e_resume_remote[i]="$(ej_field "$i" '.agent.resume_intent')"
    else
      # Started (or switched) on the worker after the handoff.
      rw_warn "rw handback: found a $live_provider session started remotely in ${sessions[$i]}; bringing it back too."
      e_resume_remote[i]="$("$ADAPTERS_DIR/$live_provider" resume-cmd --dest-path "${e_pworker[$i]}" --session-id "$live_session" 2>/dev/null || true)"
    fi
  elif [ -n "$rec_provider" ]; then
    # Handed off but no longer running remotely: its transcript still comes
    # back and resumes here, as before.
    e_provider[i]="$rec_provider"
    e_session[i]="$rec_session"
    e_pworker[i]="$(ej_field "$i" '.agent.project_path_worker')"
    [ -n "${e_pworker[$i]}" ] || e_pworker[i]="$(ej_field "$i" '.workspace.remote_path')"
    e_pfocus[i]="$(ej_field "$i" '.agent.project_path_focus')"
    [ -n "${e_pfocus[$i]}" ] || e_pfocus[i]="$(ej_field "$i" '.workspace.focus_path')"
    e_mode[i]="$(ej_field "$i" '.agent.mode_flags')"
    e_resume_remote[i]="$(ej_field "$i" '.agent.resume_intent')"
  fi
done

# ---------------------------------------------------------------------------
# 2. Agent version policy, inverted: the local CLI resumes now.
# ---------------------------------------------------------------------------

checked=" "
for i in "${!endpoints[@]}"; do
  provider="${e_provider[$i]}"
  [ -n "$provider" ] || continue
  [ -x "$ADAPTERS_DIR/$provider" ] || rw_die "rw handback: no local $provider adapter; nothing was moved." 1
  case "$checked" in *" $provider "*) continue ;; esac
  checked="$checked$provider "
  vstatus=0
  vjson="$("$ADAPTERS_DIR/$provider" versions --worker "$worker" 2>"$work/versions.err" </dev/null)" || vstatus=$?
  if [ "$vstatus" -eq 0 ] && [ "$(printf '%s' "$vjson" | jq -r '.policy // empty')" = "newer_worker" ]; then
    # Only CLI oldness blocks; a Node-only difference with equal CLIs does not.
    lcli="$(printf '%s' "$vjson" | jq -r 'if (.local | type) == "object" then .local.cli // empty else .local // empty end')"
    wcli="$(printf '%s' "$vjson" | jq -r 'if (.worker | type) == "object" then .worker.cli // empty else .worker // empty end')"
    if [ -z "$lcli" ] || [ "$lcli" != "$wcli" ]; then
      rw_warn "rw handback: the local $provider CLI ($lcli) is older than the remote one ($wcli) that wrote this session; update the local $provider and retry. Nothing was moved."
      fail_event "agent_version_blocked:$provider"
      exit 3
    fi
  elif [ "$vstatus" -ne 0 ] && [ "$vstatus" -ne 3 ]; then
    rw_warn "rw handback: $provider version check failed (exit $vstatus); continuing. $(cat "$work/versions.err")"
  fi
done

# ---------------------------------------------------------------------------
# 3. Stop the remote agents: the pull must hold their last write.
# ---------------------------------------------------------------------------

remote_stopped=()
resume_remote_agents() {
  local i session_name cmd
  for i in ${remote_stopped[@]+"${remote_stopped[@]}"}; do
    session_name="$(rw_session_name "${endpoints[$i]}")"
    cmd="${e_resume_remote[$i]}"
    if [ -z "$cmd" ] ||
      ! rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
        "tmux send-keys -t $(rw_shquote "$session_name") $(rw_shquote "$cmd") Enter" </dev/null >/dev/null 2>&1 ||
      ! rw_wait_remote_provider_started "$worker" "$session_name" "${e_provider[$i]}" </dev/null; then
      rw_warn "rw handback: could not confirm the ${e_provider[$i]} agent restarted in remote session $session_name; attach that pane and run: ${cmd:-<its resume command>}"
    fi
  done
}

for i in "${!endpoints[@]}"; do
  [ -n "${e_provider[$i]}" ] || continue
  remote_stopped+=("$i")
  if ! rw_stop_remote_agent "$worker" "$(rw_session_name "${endpoints[$i]}")" "${e_provider[$i]}"; then
    resume_remote_agents
    fail_event "remote_agent_stop_failed"
    rw_die "rw handback: could not stop the remote ${e_provider[$i]} agent (endpoint ${endpoints[$i]}); nothing was moved." 1
  fi
done

# ---------------------------------------------------------------------------
# 4. One pull of the root
# ---------------------------------------------------------------------------

record_dir="$(rw_owned_record_dir "$root_id")"
sync_args=(sync --direction handback --pull --kind "$kind"
  --source-path "$worker_root" --dest-path "$root_local"
  --dest-mode ssh --dest-worker "$worker"
  --dest-manifest "$record_dir/manifest.focus.tsv" --manifest-out "$work/manifests"
  --token "root-$root_id")
[ "$check_lfs" = "true" ] && sync_args+=(--check-lfs)
[ "$force_diverged" = "true" ] && sync_args+=(--force-diverged)
[ -n "$resolve" ] && sync_args+=(--resolve "$resolve")

sync_status=0
sync_out="$("$SYNC_DIR/handoff" "${sync_args[@]}" 2>"$work/sync.err" </dev/null)" || sync_status=$?
if [ "$sync_status" -ne 0 ]; then
  cat "$work/sync.err" >&2
  resume_remote_agents
  case "$sync_status" in
    5)
      printf '%s\n' "$sync_out"
      fail_event "manifest_conflict"
      exit 5
      ;;
    2)
      fail_event "diverged"
      exit 2
      ;;
    *)
      rw_warn "rw handback: transfer of '$root_rel' failed (exit $sync_status); every pane is still remote."
      fail_event "sync_failed:$sync_status"
      exit 1
      ;;
  esac
fi
# The laptop copy now matches the worker copy: record that at once, so an
# interrupted or rolled-back hand-back never mistakes the pulled files for
# local edits on the frozen copy.
cp "$work/manifests/dest.tsv" "$record_dir/manifest.focus.tsv"
cp "$work/manifests/source.tsv" "$record_dir/manifest.worker.tsv"

# ---------------------------------------------------------------------------
# 5. Transcripts, then panes, all verified before anything is closed.
# ---------------------------------------------------------------------------

failure=""
e_local_resume=()
for i in "${!endpoints[@]}"; do
  e_local_resume[i]=""
  provider="${e_provider[$i]}"
  [ -n "$provider" ] || continue
  adapter="$ADAPTERS_DIR/$provider"
  dir="$(mktemp -d "$work/agent.XXXXXX")"
  err="$dir.err"
  session="${e_session[$i]}"
  pfocus="${e_pfocus[$i]}"
  pworker="${e_pworker[$i]}"
  mode="${e_mode[$i]}"
  if ! "$adapter" export --session-id "$session" --project-path "$pworker" --out "$dir" --worker "$worker" </dev/null >/dev/null 2>"$err"; then
    failure="$provider export from the remote failed (endpoint ${endpoints[$i]}): $(cat "$err")"
    break
  fi
  tid="$(jq -r '.session_id // empty' "$dir/manifest.json" 2>/dev/null)"
  if ! "$adapter" install --snapshot "$dir" --dest-path "$pfocus" </dev/null >/dev/null 2>"$err"; then
    failure="local $provider install failed (endpoint ${endpoints[$i]}): $(cat "$err")"
    break
  fi
  rc_args=(resume-cmd --dest-path "$pfocus" --session-id "${tid:-$session}")
  [ -n "$mode" ] && rc_args+=(--mode-flags "$mode")
  if ! e_local_resume[i]="$("$adapter" "${rc_args[@]}" 2>"$err")"; then
    failure="$provider resume-cmd failed (endpoint ${endpoints[$i]}): $(cat "$err")"
    break
  fi
done
if [ -n "$failure" ]; then
  resume_remote_agents
  fail_event "rolled_back: $failure"
  rw_die "rw handback: $failure. Nothing moved: '$root_rel' stays remote and its agents were resumed there." 1
fi

# Editors running in the remote panes come back too, best effort (never a
# reason to roll back): how to reopen each is captured now, while the worker
# sessions still exist, rewritten for the laptop root.
ED_PATTERN='(^|/)(nvim|vim|vi)([[:space:]]|$)'
e_editor=()
for i in "${!endpoints[@]}"; do
  e_editor[i]=""
  [ -z "${e_provider[$i]}" ] || continue
  case "$(ej_field "$i" '.role')" in tree | tree-editor) continue ;; esac
  [ -x "$ADAPTERS_DIR/editor" ] || continue
  live_ppid="$(sed '/^---$/,$d' "$work/probe" | awk -F '\t' -v s="${sessions[$i]}" '$1 == s { print $3; exit }')"
  [ -n "$live_ppid" ] || continue
  rw_ps_tree_matches "$ED_PATTERN" "$live_ppid" <"$work/probe.ps" || continue
  dir="$(mktemp -d "$work/editor.XXXXXX")"
  ed_status=0
  "$ADAPTERS_DIR/editor" export --pane "${sessions[$i]}" --worker "$worker" --out "$dir" </dev/null >/dev/null 2>"$dir.err" || ed_status=$?
  [ "$ed_status" -ne 1 ] || continue # no editor in that pane's foreground
  wcwd=""
  [ "$ed_status" -eq 0 ] && wcwd="$(jq -r '.cwd // empty' "$dir/manifest.json" 2>/dev/null)"
  if [ -n "$wcwd" ]; then fdir="$(focus_path_for "$wcwd")"; else fdir="$(ej_field "$i" '.workspace.focus_path')"; fi
  [ -d "$fdir" ] || fdir="$root_local"
  if [ "$ed_status" -ne 0 ] ||
    ! e_editor[i]="$("$ADAPTERS_DIR/editor" install --snapshot "$dir" --from-root "$worker_root" --to-root "$root_local" \
      --dest-dir "$fdir" --dest-file "$(rw_state_dir)/editor-sessions/${endpoints[$i]}.vim" </dev/null 2>"$dir.err")"; then
    e_editor[i]=""
    rw_warn "rw handback: could not capture the editor in remote session ${sessions[$i]}, so it will not be reopened here; open it again in its pane. $(head -c 300 "$dir.err")"
  fi
done

# The local shells about to start must already see the root as local (the
# zsh notice "is remote on <alias>" reads the ownership record): flip the
# record to owner=focus now; a rollback below flips it back.
rw_owned_record_write "$root_id" "$(rw_owned_record_read "$root_id" | jq -c '.owner = "focus"')"

bound="$(rw_root_bound_panes "$root_id" ${endpoints[@]+"${endpoints[@]}"})"
released=()   # "index<TAB>pane"
for i in "${!endpoints[@]}"; do
  e="${endpoints[$i]}"
  case "$(ej_field "$i" '.role')" in
    tree | tree-editor) continue ;; # no local equivalent; closed at commit
  esac
  pid="$(printf '%s\n' "$bound" | awk -F '\t' -v e="$e" '$2 == e { print $1; exit }')"
  focus_path="$(ej_field "$i" '.workspace.focus_path')"
  [ -d "$focus_path" ] || focus_path="$root_local"
  if [ -z "$pid" ]; then
    if [ -z "${e_provider[$i]}" ]; then
      [ -z "${e_editor[$i]}" ] ||
        rw_warn "rw handback: endpoint $e has no laptop pane any more, so its editor was not reopened; reopen it with: ${e_editor[$i]}"
      continue
    fi
    # The agent's laptop pane is gone (a restore that did not rebind it):
    # give it a fresh window in its session, or a new session.
    sess="$(ej_field "$i" '.focus_session_name')"
    pid="$(tmux new-window -d -P -F '#{pane_id}' -t "$sess:" -c "$focus_path" 2>/dev/null ||
      tmux new-session -d -P -F '#{pane_id}' -c "$focus_path" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
      failure="no local pane for the ${e_provider[$i]} agent of endpoint $e and none could be created"
      break
    fi
    released+=("$i$RW_TAB$pid${RW_TAB}new")
  else
    if ! rw_release_pane "$pid" "$focus_path"; then
      failure="could not give pane $pid its local shell back"
      break
    fi
    released+=("$i$RW_TAB$pid${RW_TAB}pane")
  fi
  rw_wait_local_shell "$pid" || rw_warn "rw handback: pane $pid did not show a local shell yet."
  if [ -n "${e_provider[$i]}" ]; then
    if ! tmux send-keys -t "$pid" "${e_local_resume[$i]}" Enter 2>/dev/null ||
      ! rw_wait_local_provider_started "$pid" "${e_provider[$i]}"; then
      failure="could not confirm the ${e_provider[$i]} agent started locally in pane $pid"
      break
    fi
  fi
  if [ -n "${e_editor[$i]}" ]; then
    if ! tmux send-keys -t "$pid" "${e_editor[$i]}" Enter 2>/dev/null ||
      ! rw_wait_local_provider_started "$pid" "$ED_PATTERN"; then
      rw_warn "rw handback: could not confirm the editor reopened in pane $pid; run there: ${e_editor[$i]}"
    fi
  fi
done

if [ -n "$failure" ]; then
  # Roll back every pane touched so far: stop what started locally, put the
  # attach loops back, resume the remote agents. Ownership never changed.
  for entry in ${released[@]+"${released[@]}"}; do
    IFS="$RW_TAB" read -r i pid how <<<"$entry"
    [ -n "${e_provider[$i]}" ] && rw_stop_local_agent "$pid" "${e_provider[$i]}" >/dev/null 2>&1
    if [ "$how" = "new" ]; then
      tmux kill-pane -t "$pid" 2>/dev/null || true
    else
      rw_reattach_pane "$pid" "${endpoints[$i]}" "$root_id" "$(ej_field "$i" '.workspace.focus_path')" ||
        rw_warn "rw handback: could not reattach pane $pid; 'rw open --pane $pid' does."
    fi
  done
  rw_owned_record_write "$root_id" "$(rw_owned_record_read "$root_id" | jq -c '.owner = "worker"')"
  resume_remote_agents
  rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null || true
  fail_event "rolled_back: $failure"
  rw_die "rw handback: $failure. Rolled back: '$root_rel' stays remote, its panes and agents run there as before." 1
fi

# ---------------------------------------------------------------------------
# 6. Commit
# ---------------------------------------------------------------------------

rw_close_root_endpoints "$root_id" "handback" ${endpoints[@]+"${endpoints[@]}"}
final="$(rw_owned_record_read "$root_id" | jq -c --arg now "$(rw_now_iso)" '.owner = "focus" | .since = $now | .endpoints = []')"
rw_owned_record_write "$root_id" "$final"
rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null ||
  rw_warn "rw handback: could not refresh the ownership mirror on '$worker'; the next handoff compares against the older manifest."
rw_owned_record_remove "$root_id"
rw_prune_root_backups "$root_id" "$worker" "$worker_home"

rw_log_event "handback" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "success" \
  "root=$root_rel kind=$kind panes=${#released[@]} closed=${#endpoints[@]} $(printf '%s' "$sync_out" | jq -r '"renamed=\(.renamed | length) overwritten=\(.overwritten)"' 2>/dev/null)"
printf 'rw: %s is local again (%d pane(s) back).\n' "$root_rel" "${#released[@]}"
# The root's owner changed: every pane in it (visit panes left on other
# remotes included) gets its display flags recomputed (CS3). Best effort.
rw_refresh_indicators --root "$root_local"
exit 0
