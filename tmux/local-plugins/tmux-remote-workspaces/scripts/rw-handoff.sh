#!/usr/bin/env bash
# `rw handoff` -- hand a directory root, and every pane working inside it,
# to a worker (docs/tasks/remote-owned-directories.md, P1 and contract C2).
#
# The unit is a directory: the git toplevel of a worktree, or a plain
# folder. Every pane on this tmux server whose cwd is the root or inside it
# (any depth, any session) moves; the rest of a mixed session stays local.
# While the root is remote the worker copy is the single source of truth;
# the local copy stays on disk, frozen.
#
# All or nothing. Order:
#   1. Resolve the root (exit 7 when outside ~, inside a git worktree,
#      already remote, a top-level folder of ~, or a plain folder holding git
#      repositories -- the last two only without an explicit --root). Take
#      the per-root lock. Preflight the worker (exit 6 unreachable).
#   2. Per pane: detect a supported agent; refuse a working agent and a busy
#      pane no adapter recognizes; check the provider version policy (one
#      exit-3 block aborts everything).
#   3. Stop the local agents, so the snapshot holds their last write.
#   4. ONE sync of the root (git channel + rsync channel; divergence gate
#      exit 2, manifest gate exit 5). On failure the local agents resume.
#   5. Per pane: a hidden worker session in the pane's mapped directory; the
#      agent's (now final) transcript exported, installed and resumed there,
#      and verified. If ANY pane fails, everything rolls back: worker
#      sessions killed, local agents resumed, the root stays local (exit 1).
#      An editor pane (nvim, vim, vi) gets its editor reopened there (its
#      nvim session, or its argv, with the root's paths rewritten); that is
#      best effort: an editor that does not come back is only a warning.
#   6. Commit: ownership record (owner = worker) and mirror, endpoint
#      records (contract C3), panes replaced by their attach loops. Visit
#      panes already on this worker in the root (soft switches) are adopted
#      as owned panes (S8); visit panes on other workers stay as they are.
#
# Usage: rw-handoff.sh --worker <alias> [--root <path>] [--pane <pane-id>]
#                      [--check-lfs] [--force-diverged]
#                      [--resolve overwrite|keep-both|abort]
#
# Exit: 0 ok, 1 failure (rolled back), 2 git divergence, 3 agent CLI version
#       gate, 5 manifest conflict (stdout: conflict<TAB>path<TAB>kind),
#       6 worker unreachable, 7 root invalid or already remote, 64 usage.

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

worker=""
root_arg=""
pane_id="${TMUX_PANE:-}"
check_lfs="false"
force_diverged="false"
resolve=""

while [ $# -gt 0 ]; do
  case "$1" in
    --worker) worker="${2:?}"; shift 2 ;;
    --root) root_arg="${2:?}"; shift 2 ;;
    --pane) pane_id="${2:?}"; shift 2 ;;
    --check-lfs) check_lfs="true"; shift ;;
    --force-diverged) force_diverged="true"; shift ;;
    --resolve) resolve="${2:?}"; shift 2 ;;
    *) rw_die "rw handoff: unknown argument: $1" 64 ;;
  esac
done

[ -n "$worker" ] || rw_die "rw handoff: --worker is required" 64
rw_worker_known "$worker" || rw_die "rw handoff: worker '$worker' is not declared in config.json" 64
case "$resolve" in '' | overwrite | keep-both | abort) : ;; *) rw_die "rw handoff: --resolve must be overwrite, keep-both or abort" 64 ;; esac

start_ts="$(rw_now_epoch)"
fail_event() { rw_log_event "handoff" "" "$worker" "$(rw_elapsed_ms "$start_ts")" "fail" "$1"; }

# ---------------------------------------------------------------------------
# 1. Root
# ---------------------------------------------------------------------------

if [ -n "$root_arg" ]; then
  [ -d "$root_arg" ] || rw_die "rw handoff: --root '$root_arg' is not a directory" 7
  root_local="$(rw_physical_path "$root_arg")"
else
  if [ -n "$pane_id" ]; then
    cwd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_path}' 2>/dev/null || true)"
  fi
  [ -n "${cwd:-}" ] || cwd="$(pwd -P)"
  if existing="$(rw_owned_root_for_path "$cwd")"; then
    rw_die "rw handoff: '$cwd' is inside '$(jq -r '.root_local' "$(rw_owned_record_file "$existing")")', which is already remote. Use 'rw open' for a new remote pane there, or 'rw handback' to bring it back." 7
  fi
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  root_local="$(rw_physical_path "${top:-$cwd}")"
fi

root_rel="$(rw_root_rel "$root_local")" ||
  rw_die "rw handoff: '$root_local' is not inside your home directory (or is the home directory itself); only directories under ~ can be handed off." 7
kind="$(rw_root_kind "$root_local")"
[ "$kind" != "inside-git" ] ||
  rw_die "rw handoff: '$root_local' is inside the git worktree '$(git -C "$root_local" rev-parse --show-toplevel)'; hand off the worktree root instead." 7
root_id="$(rw_root_id "$root_rel")"

# A shell sitting in ~/Developer must not ship everything below it. Without
# an explicit --root, a plain root may be neither a top-level folder of ~ nor
# a folder that holds git repositories (hand those off one by one).
if [ -z "$root_arg" ] && [ "$kind" = "plain" ]; then
  case "$root_rel" in
    */*) : ;;
    *) rw_die "rw handoff: '~/$root_rel' is a top-level folder of your home directory; hand off the project inside it, or pass --root '$root_local' if you really mean all of it." 7 ;;
  esac
  nested_repo="$(find "$root_local" -mindepth 2 -maxdepth 5 -name .git -print -quit 2>/dev/null)"
  if [ -n "$nested_repo" ]; then
    rw_die "rw handoff: '~/$root_rel' contains the git repository '$(dirname "$nested_repo")'; hand off that worktree instead, or pass --root '$root_local' to move the whole folder." 7
  fi
fi

if record="$(rw_owned_record_read "$root_id")"; then
  rec_owner="$(printf '%s' "$record" | jq -r '.owner')"
  rec_worker="$(printf '%s' "$record" | jq -r '.worker')"
  if [ "$rec_owner" = "worker" ]; then
    rw_die "rw handoff: '$root_rel' is already remote on '$rec_worker'." 7
  fi
  if [ "$rec_worker" != "$worker" ]; then
    if [ "$(printf '%s' "$record" | jq -r '.pending.action // empty')" = "forget" ]; then
      rw_die "rw handoff: '$root_rel' still has a pending delete of its copy on '$rec_worker' (it was unreachable). Retry once '$rec_worker' is reachable again (any rw command that reaches it finishes the delete)." 7
    fi
    rw_die "rw handoff: '$root_rel' was reclaimed while '$rec_worker' was unreachable; its copy there may hold work done after the original handoff. Reach '$rec_worker' first (e.g. 'rw handoff --worker $rec_worker', which cleans up and keeps that copy), inspect it, and only then hand the root to '$worker'. 'rw forget $root_local --worker $rec_worker' DELETES that copy, including that work." 7
  fi
fi
if overlap="$(rw_owned_overlap "$root_local")"; then
  rw_die "rw handoff: '$root_local' overlaps the remote root '$overlap'; roots never nest across an ownership boundary." 7
fi

rw_root_lock_or_die "$root_id" "rw handoff"
work="$(mktemp -d "${TMPDIR:-/tmp}/rw-handoff.XXXXXX")"
trap 'rm -rf "$work"; rw_root_unlock_all' EXIT

# ---------------------------------------------------------------------------
# 1b. Preflight
# ---------------------------------------------------------------------------

preflight_args=(--worker "$worker")
repo_remote=""
if [ "$kind" = "git" ]; then
  repo_remote="$(git -C "$root_local" remote get-url origin 2>/dev/null || true)"
  if [ "$check_lfs" != "true" ] &&
    [ -n "$(git -C "$root_local" lfs ls-files --name-only 2>/dev/null | head -1)" ]; then
    check_lfs="true"
  fi
fi
[ "$check_lfs" = "true" ] && preflight_args+=(--check-lfs)
[ -n "$repo_remote" ] && preflight_args+=(--repo-remote "$repo_remote")

preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" "${preflight_args[@]}")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  fail_event "preflight_failed"
  exit "$(rw_preflight_exit "$preflight_json")"
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"
worker_identity="$(printf '%s' "$preflight_json" | jq -r '.hostname')"
[ -n "$worker_home" ] && [ "$worker_home" != "null" ] || rw_die "rw handoff: preflight did not report the remote home directory" 1
worker_root="${worker_home%/}/$root_rel"

# Anything left pending for this worker (an earlier forget or reclaim while
# it was unreachable) runs now that it answered.
rw_reconcile_pending "$worker" "$worker_home"

# The worker's tmux server must be one whose saves land: started through its
# boot restore wrapper when none runs, refused when its last restore did not
# complete. Checked before any agent stops; each session creation below
# checks again.
ensure_status=0
rw_worker_ensure_server "$worker" </dev/null >/dev/null 2>&1 || ensure_status=$?
if [ "$ensure_status" -ne 0 ]; then
  fail_event "worker_server: $RW_WORKER_SERVER_ERROR"
  rw_die "rw handoff: $RW_WORKER_SERVER_ERROR; nothing was moved." "$([ "$ensure_status" -eq 6 ] && echo 6 || echo 1)"
fi

# ---------------------------------------------------------------------------
# 2. Panes and agents
# ---------------------------------------------------------------------------

# Visit panes (S8): a pane already on this worker by a soft switch, in this
# root, is adopted as an owned pane at the commit (its session already sits
# in the worker copy's path; no second session). Visit panes on other
# workers stay where they are. An adopted pane's agent must not be
# mid-turn: the transfer below rewrites the directory it works in.
adopt_panes=()
while IFS="$RW_TAB" read -r a_pane a_ep a_cwd; do
  [ -n "$a_ep" ] || continue
  a_json="$(rw_read_endpoint "$a_ep" 2>/dev/null)" || continue
  [ "$(printf '%s' "$a_json" | jq -r '.kind // "owned"')" = "visit" ] || continue
  [ "$(printf '%s' "$a_json" | jq -r '.worker // empty')" = "$worker" ] || continue
  a_focus="$(printf '%s' "$a_json" | jq -r '.workspace.focus_path // empty')"
  case "$a_focus" in "$root_local" | "$root_local"/*) : ;; *)
    case "$a_cwd" in "$root_local" | "$root_local"/*) : ;; *) continue ;; esac
    ;;
  esac
  if [ "$(rw_pane_get "$a_pane" @agent_state)" = "working" ]; then
    fail_event "visit_agent_working:pane=$a_pane"
    rw_die "rw handoff: the agent in pane $a_pane (already on that remote) is working; nothing was moved. Retry when it is idle." 1
  fi
  adopt_panes+=("$a_pane$RW_TAB$a_ep")
done < <(tmux list-panes -a -F "#{pane_id}${RW_TAB}#{@rw-endpoint}${RW_TAB}#{pane_current_path}" 2>/dev/null |
  awk -F '\t' '$2 != ""')

pane_lines=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  p_endpoint="$(printf '%s' "$line" | cut -f6)"
  if [ -n "$p_endpoint" ]; then
    # Visit panes are adopted above (same worker) or stay as they are.
    [ "$(rw_read_endpoint "$p_endpoint" 2>/dev/null | jq -r '.kind // "owned"' 2>/dev/null)" = "visit" ] ||
      rw_warn "rw handoff: pane $(printf '%s' "$line" | cut -f1) already has remote endpoint $p_endpoint; left as is."
    continue
  fi
  pane_lines+=("$line")
done < <(rw_root_panes "$root_local")

# Per-pane agent detection results, index-aligned with pane_lines.
p_provider=()
p_session=()
p_project=()
p_mode=()
p_local_resume=()
version_checked=" "

for i in "${!pane_lines[@]}"; do
  line="${pane_lines[$i]}"
  pid="$(printf '%s' "$line" | cut -f1)"
  pcmd="$(printf '%s' "$line" | cut -f8)"
  provider="" session="" project="" mode=""
  for candidate in pi claude; do
    adapter="$ADAPTERS_DIR/$candidate"
    [ -x "$adapter" ] || continue
    detect_out="$("$adapter" detect --pane "$pid" 2>/dev/null)" || continue
    provider="$(printf '%s' "$detect_out" | jq -r '.provider // empty' 2>/dev/null)"
    session="$(printf '%s' "$detect_out" | jq -r '.session_id // empty' 2>/dev/null)"
    project="$(printf '%s' "$detect_out" | jq -r '.project_path // empty' 2>/dev/null)"
    mode="$(printf '%s' "$detect_out" | jq -r '.mode_flags // empty' 2>/dev/null)"
    if [ -n "$provider" ] && [ -n "$session" ]; then
      break
    fi
    provider="" session="" project="" mode=""
  done

  if [ -n "$provider" ] && [ "$pid" = "${TMUX_PANE:-}" ]; then
    rw_die "rw handoff: this command runs inside the $provider agent's own pane ($pid); stopping that agent would stop this command. Run it from another pane or the picker." 1
  fi
  # A busy pane no adapter recognizes must not be replaced: detection may
  # have raced the agent's own session recording, and respawning would kill
  # the only copy. Shells and editors are safe to replace (an editor is
  # reopened on the worker in step 5); the calling pane runs this very
  # command.
  if [ -z "$provider" ] && [ "$pid" != "${TMUX_PANE:-}" ] && ! rw_is_idle_command "$pcmd"; then
    fail_event "agent_detection_unconfirmed:pane=$pid cmd=${pcmd:-unknown}"
    rw_die "rw handoff: pane $pid runs '${pcmd:-unknown}', which is neither a shell, an editor, nor a recognized agent session; nothing was moved. Stop it or wait for the agent to finish starting, then retry." 1
  fi
  # An agent in the middle of a turn would lose it: wait until it is idle.
  if [ -n "$provider" ] && [ "$(rw_pane_get "$pid" @agent_state)" = "working" ]; then
    fail_event "agent_working:pane=$pid"
    rw_die "rw handoff: the $provider agent in pane $pid is working; nothing was moved. Retry when it is idle (or interrupt it first)." 1
  fi

  local_resume=""
  if [ -n "$provider" ]; then
    case "$version_checked" in
      *" $provider "*) : ;;
      *)
        versions_err="$work/versions-$provider.err"
        versions_status=0
        versions_json="$("$ADAPTERS_DIR/$provider" versions --worker "$worker" 2>"$versions_err" </dev/null)" || versions_status=$?
        if [ "$versions_status" -eq 3 ]; then
          rw_warn "rw handoff: the remote $provider CLI is older than the local one, so its session cannot be resumed there. Nothing was moved:"
          rw_warn "$(cat "$versions_err")"
          fail_event "agent_version_blocked:$provider"
          exit 3
        elif [ "$versions_status" -ne 0 ]; then
          rw_warn "rw handoff: $provider version check failed (exit $versions_status): $(cat "$versions_err")"
          fail_event "agent_version_check_failed:$provider"
          exit 1
        fi
        if [ "$(printf '%s' "$versions_json" | jq -r '.policy // empty' 2>/dev/null)" = "newer_worker" ]; then
          rw_warn "rw handoff: notice -- the remote $provider CLI is newer than the local one; proceeding."
        fi
        version_checked="$version_checked$provider "
        ;;
    esac
    # How to bring this agent back here if anything below fails.
    lr_args=(resume-cmd --dest-path "$(rw_physical_path "${project:-$(printf '%s' "$line" | cut -f2)}")" --session-id "$session")
    [ -n "$mode" ] && lr_args+=(--mode-flags "$mode")
    local_resume="$("$ADAPTERS_DIR/$provider" "${lr_args[@]}" 2>"$work/local-resume.err")" ||
      rw_die "rw handoff: cannot build the local resume command for the $provider agent in pane $pid, so it would not be safe to stop it: $(cat "$work/local-resume.err")" 1
  fi
  p_provider[i]="$provider"
  p_session[i]="$session"
  p_project[i]="$project"
  p_mode[i]="$mode"
  p_local_resume[i]="$local_resume"
done

# Duplicate managed-writer guard: never launch a second managed writer for
# an agent session that is already handed off on another endpoint.
for i in "${!pane_lines[@]}"; do
  [ -n "${p_provider[$i]}" ] || continue
  if [ -d "$(rw_endpoints_dir)" ] && dupe="$(jq -r --arg p "${p_provider[$i]}" --arg s "${p_session[$i]}" \
    'select(.agent.provider == $p and .agent.session_id == $s and .agent.state == "handed-off") | .endpoint_id' \
    "$(rw_endpoints_dir)"/*.json 2>/dev/null | head -n1)" && [ -n "$dupe" ]; then
    fail_event "duplicate_managed_writer:${p_provider[$i]}"
    rw_die "rw handoff: ${p_provider[$i]} session ${p_session[$i]} is already running remotely on endpoint $dupe; hand that root back or close the endpoint first." 1
  fi
done

pane_field() { printf '%s' "${pane_lines[$1]}" | cut -f"$2"; }

# ---------------------------------------------------------------------------
# 3. Stop the local agents: the snapshot must hold their last write.
# ---------------------------------------------------------------------------

stopped=()
resume_local_agents() {
  local i pid
  for i in ${stopped[@]+"${stopped[@]}"}; do
    pid="$(pane_field "$i" 1)"
    if ! tmux send-keys -t "$pid" "${p_local_resume[$i]}" Enter 2>/dev/null ||
      ! rw_wait_local_provider_started "$pid" "${p_provider[$i]}"; then
      rw_warn "rw handoff: could not confirm the ${p_provider[$i]} agent restarted in pane $pid; resume it there with: ${p_local_resume[$i]}"
    fi
  done
}

for i in "${!pane_lines[@]}"; do
  [ -n "${p_provider[$i]}" ] || continue
  pid="$(pane_field "$i" 1)"
  stopped+=("$i")
  if ! rw_stop_local_agent "$pid" "${p_provider[$i]}"; then
    rw_warn "rw handoff: the ${p_provider[$i]} agent in pane $pid did not stop; nothing was moved."
    resume_local_agents
    fail_event "agent_stop_failed:pane=$pid"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 4. One sync of the root
# ---------------------------------------------------------------------------

fetch_status=0
rw_worker_mirror_fetch "$worker" "$worker_home" "$root_id" manifest.worker.tsv "$work/stored.worker.tsv" || fetch_status=$?
rw_worker_mirror_fetch "$worker" "$worker_home" "$root_id" record.json "$work/mirror.json" || fetch_status=$?
if [ "$fetch_status" -ne 0 ]; then
  resume_local_agents
  fail_event "mirror_fetch_unreachable"
  rw_die "rw handoff: lost contact with '$worker' while reading its copy's manifest; nothing was moved." 6
fi
# Whether rw created the worker directory: only then may `rw forget` delete
# it. A mirror remembers the first handoff's answer.
if [ -s "$work/mirror.json" ]; then
  root_created="$(jq -r '.worker_root_created // false' "$work/mirror.json" 2>/dev/null)"
elif rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "[ -e $(rw_shquote "$worker_root") ]" </dev/null >/dev/null 2>&1; then
  root_created="false"
else
  root_created="true"
fi
[ "$root_created" = "true" ] || root_created="false"

worker_state="$(rw_state_dir_at "$worker_home")"
sync_args=(sync --direction handoff --kind "$kind"
  --source-path "$root_local" --dest-path "$worker_root"
  --dest-mode ssh --dest-worker "$worker"
  --dest-manifest "$work/stored.worker.tsv" --manifest-out "$work/manifests"
  --token "root-$root_id"
  --backup-root "$worker_state/handoff-backups" --staging-root "$worker_state/handoff-staging")
[ "$check_lfs" = "true" ] && sync_args+=(--check-lfs)
[ "$force_diverged" = "true" ] && sync_args+=(--force-diverged)
[ -n "$resolve" ] && sync_args+=(--resolve "$resolve")

sync_status=0
sync_out="$("$SYNC_DIR/handoff" "${sync_args[@]}" 2>"$work/sync.err" </dev/null)" || sync_status=$?
if [ "$sync_status" -ne 0 ]; then
  cat "$work/sync.err" >&2
  resume_local_agents
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
      rw_warn "rw handoff: transfer of '$root_rel' failed (exit $sync_status); no pane was moved."
      fail_event "sync_failed:$sync_status"
      exit 1
      ;;
  esac
fi

# Courtesy: give a git destination an `origin`, and the same upstream as the
# laptop branch, so push/pull work there as they do here.
if [ "$kind" = "git" ]; then
  wq="$(rw_shquote "$worker_root")"
  git_setup=""
  [ -n "$repo_remote" ] &&
    git_setup="git -C $wq remote get-url origin >/dev/null 2>&1 || git -C $wq remote add origin $(rw_shquote "$repo_remote"); "
  up_branch="$(git -C "$root_local" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ -n "$up_branch" ]; then
    up_remote="$(git -C "$root_local" config "branch.$up_branch.remote" 2>/dev/null || true)"
    up_merge="$(git -C "$root_local" config "branch.$up_branch.merge" 2>/dev/null || true)"
    up_url=""
    [ -n "$up_remote" ] && [ "$up_remote" != "." ] && up_url="$(git -C "$root_local" remote get-url "$up_remote" 2>/dev/null || true)"
    if [ -n "$up_url" ] && [ -n "$up_merge" ]; then
      git_setup="$git_setup git -C $wq remote get-url $(rw_shquote "$up_remote") >/dev/null 2>&1 || git -C $wq remote add $(rw_shquote "$up_remote") $(rw_shquote "$up_url"); git -C $wq config $(rw_shquote "branch.$up_branch.remote") $(rw_shquote "$up_remote") && git -C $wq config $(rw_shquote "branch.$up_branch.merge") $(rw_shquote "$up_merge"); "
    fi
  fi
  if [ -n "$git_setup" ]; then
    rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "$git_setup true" </dev/null >/dev/null 2>&1 || true
  fi
fi

mkdir -p "$work/mdir"
cp "$work/manifests/source.tsv" "$work/mdir/manifest.focus.tsv"
cp "$work/manifests/dest.tsv" "$work/mdir/manifest.worker.tsv"
base_record="$(rw_record_new "$root_id" "$root_rel" "$root_local" "$kind" "$worker" "$worker_root" |
  jq -c --argjson created "$root_created" '.worker_root_created = $created')"
rw_held_mark "$worker" "$root_id" "$root_rel" "$worker_root"

# ---------------------------------------------------------------------------
# 5. Remote sessions and agents, all verified before any pane moves.
# ---------------------------------------------------------------------------

p_endpoint=()
p_remote_path=()
p_resume=()
p_transcript=()
p_agent_dest=()
p_editor=()
created_sessions=()
failure=""

# Editors come back too, best effort (never a reason to roll back): the
# editor adapter captures how to reopen the pane's editor (its nvim session,
# or its argv), rewritten for the worker root, and the command is typed into
# the new remote pane's login shell like an agent resume, then verified.
ED_PATTERN='(^|/)(nvim|vim|vi)([[:space:]]|$)'
reopen_remote_editor() { # <index> <pane> <remote session> <remote path>
  local i="$1" pid="$2" sname="$3" rpath="$4" dir cmd
  case "$(pane_field "$i" 8)" in nvim | vim | vi) : ;; *) return 0 ;; esac
  [ "$pid" != "${TMUX_PANE:-}" ] && [ -x "$ADAPTERS_DIR/editor" ] || return 0
  dir="$(mktemp -d "$work/editor.XXXXXX")"
  if ! "$ADAPTERS_DIR/editor" export --pane "$pid" --out "$dir" </dev/null >/dev/null 2>"$dir.err" ||
    ! cmd="$("$ADAPTERS_DIR/editor" install --snapshot "$dir" --from-root "$root_local" --to-root "$worker_root" \
      --dest-dir "$rpath" --dest-file "$(rw_state_dir_at "$worker_home")/editor-sessions/${p_endpoint[$i]}.vim" \
      --worker "$worker" </dev/null 2>"$dir.err")"; then
    rw_warn "rw handoff: could not capture the editor of pane $pid, so it was not reopened on the remote; open it again there. $(head -c 300 "$dir.err")"
    return 0
  fi
  p_editor[i]="$cmd"
  if ! rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "tmux send-keys -t $(rw_shquote "$sname") $(rw_shquote "$cmd") Enter" </dev/null >/dev/null 2>&1 ||
    ! rw_wait_remote_provider_started "$worker" "$sname" "$ED_PATTERN" </dev/null; then
    rw_warn "rw handoff: could not confirm the editor of pane $pid reopened on the remote; in that pane run: $cmd"
  fi
}

for i in "${!pane_lines[@]}"; do
  pid="$(pane_field "$i" 1)"
  pcwd="$(pane_field "$i" 2)"
  endpoint_id="$(rw_new_short_id)"
  session_name="$(rw_session_name "$endpoint_id")"
  remote_path="$(rw_path_under_root "$pcwd" "$root_local" "$worker_root")"
  p_endpoint[i]="$endpoint_id"
  p_remote_path[i]="$remote_path"
  p_resume[i]=""
  p_transcript[i]=""
  p_agent_dest[i]=""
  p_editor[i]=""
  if ! rw_create_remote_session "$worker" "$session_name" "$remote_path" "$(rw_ssh_connect_timeout)" </dev/null >/dev/null 2>&1; then
    failure="could not create the remote session for pane $pid: $RW_WORKER_SERVER_ERROR"
    break
  fi
  created_sessions+=("$session_name")

  provider="${p_provider[$i]}"
  if [ -z "$provider" ]; then
    reopen_remote_editor "$i" "$pid" "$session_name" "$remote_path"
    continue
  fi
  adapter="$ADAPTERS_DIR/$provider"
  export_dir="$(mktemp -d "$work/agent.XXXXXX")"
  err="$work/agent-$i.err"
  project="${p_project[$i]:-$pcwd}"
  # The worker's PHYSICAL path: Claude slugs its project dir from it.
  agent_dest="$(rw_path_under_root "$(rw_physical_path "$project")" "$root_local" "$worker_root")"
  p_agent_dest[i]="$agent_dest"
  if ! "$adapter" export --session-id "${p_session[$i]}" --project-path "$project" --out "$export_dir" </dev/null >/dev/null 2>"$err"; then
    failure="$provider export failed for pane $pid: $(cat "$err")"
    break
  fi
  # The transcript's own id (pi: its header id) names exactly this session
  # on the other side.
  transcript_id="$(jq -r '.session_id // empty' "$export_dir/manifest.json" 2>/dev/null)"
  p_transcript[i]="${transcript_id:-${p_session[$i]}}"
  if ! "$adapter" install --snapshot "$export_dir" --dest-path "$agent_dest" --worker "$worker" </dev/null >/dev/null 2>"$err"; then
    failure="$provider install on the remote failed for pane $pid: $(cat "$err")"
    break
  fi
  rc_args=(resume-cmd --dest-path "$agent_dest" --session-id "${p_transcript[$i]}")
  [ -n "${p_mode[$i]}" ] && rc_args+=(--mode-flags "${p_mode[$i]}")
  if ! resume_cmd="$("$adapter" "${rc_args[@]}" 2>"$err")"; then
    failure="$provider resume-cmd failed for pane $pid: $(cat "$err")"
    break
  fi
  p_resume[i]="$resume_cmd"
  if ! rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "tmux send-keys -t $(rw_shquote "$session_name") $(rw_shquote "$resume_cmd") Enter" </dev/null >/dev/null 2>"$err"; then
    failure="could not start the $provider resume for pane $pid on the remote"
    break
  fi
  if ! rw_wait_remote_provider_started "$worker" "$session_name" "$provider" </dev/null; then
    failure="could not confirm the $provider agent of pane $pid started on the remote"
    break
  fi
done

if [ -n "$failure" ]; then
  # Roll back: no pane has moved yet. Kill what was started remotely, bring
  # the local agents back, and leave the root local. The worker copy is
  # already synced; its mirror records that (owner focus) so the next
  # handoff checks it.
  for s in ${created_sessions[@]+"${created_sessions[@]}"}; do
    rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "tmux kill-session -t $(rw_shquote "=$s")" </dev/null >/dev/null 2>&1 || true
  done
  resume_local_agents
  rw_mirror_push_json "$worker" "$worker_home" "$root_id" "$base_record" "$work/mdir" </dev/null || true
  fail_event "rolled_back: $failure"
  rw_die "rw handoff: $failure. Rolled back: '$root_rel' stays local and its agents were resumed here." 1
fi

# ---------------------------------------------------------------------------
# 6. Commit
# ---------------------------------------------------------------------------

record="$(printf '%s' "$base_record" | jq -c '.owner = "worker"')"
rw_owned_record_write "$root_id" "$record"
record_dir="$(rw_owned_record_dir "$root_id")"
cp "$work/mdir/manifest.focus.tsv" "$work/mdir/manifest.worker.tsv" "$record_dir/"

now="$(rw_now_iso)"
self_endpoint=""
moved=0
failed=0
for i in "${!pane_lines[@]}"; do
  IFS="$RW_TAB" read -r pid pcwd psession pwindex ppindex _ <<<"${pane_lines[$i]}"
  endpoint_id="${p_endpoint[$i]}"
  provider="${p_provider[$i]}"
  session_uuid="$(tmux show-option -t "$pid" -qv @session-uuid 2>/dev/null || true)"
  [ -n "$session_uuid" ] || session_uuid="$(rw_pane_get "$pid" @rw-session-uuid)"

  rw_write_json_atomic "$(rw_endpoint_file "$endpoint_id")" "$(jq -nc \
    --arg endpoint_id "$endpoint_id" \
    --arg worker "$worker" \
    --arg worker_identity "$worker_identity" \
    --arg focus_machine_id "$(rw_machine_id)" \
    --arg root_id "$root_id" \
    --arg root_rel "$root_rel" \
    --arg focus_session_uuid "$session_uuid" \
    --arg focus_session_name "$psession" \
    --argjson focus_window_index "${pwindex:-0}" \
    --argjson focus_pane_index "${ppindex:-0}" \
    --arg focus_pane_id "$pid" \
    --arg kind "$kind" \
    --arg focus_path "$pcwd" \
    --arg remote_path "${p_remote_path[$i]}" \
    --arg root_local "$root_local" \
    --arg worker_root "$worker_root" \
    --arg provider "$provider" \
    --arg session "${p_session[$i]}" \
    --arg transcript "${p_transcript[$i]}" \
    --arg project_focus "${p_project[$i]:-$pcwd}" \
    --arg project_worker "${p_agent_dest[$i]}" \
    --arg mode "${p_mode[$i]}" \
    --arg resume "${p_resume[$i]}" \
    --arg editor "${p_editor[$i]}" \
    --arg now "$now" \
    '{endpoint_id: $endpoint_id, worker: $worker, worker_identity: $worker_identity,
      focus_machine_id: $focus_machine_id, root_id: $root_id, root_rel: $root_rel,
      focus_session_uuid: $focus_session_uuid, focus_session_name: $focus_session_name,
      focus_window_index: $focus_window_index, focus_pane_index: $focus_pane_index,
      focus_pane_id: $focus_pane_id,
      workspace: {mode: $kind, identity: "", focus_path: $focus_path, remote_path: $remote_path,
        root_local: $root_local, worker_root: $worker_root},
      launch_intent: {worker: $worker, workspace_arg: "handoff"},
      agent: (if $provider == "" then {provider: null, session_id: null, resume_intent: null, state: null}
        else {provider: $provider, session_id: $session, transcript_id: $transcript, resume_intent: $resume,
          project_path_focus: $project_focus, project_path_worker: $project_worker,
          mode_flags: (if $mode == "" then null else $mode end), outcome: "resumed",
          divergence_risk: false, state: "handed-off"} end),
      editor: (if $editor == "" then null else {reopen_intent: $editor} end),
      created_at: $now, updated_at: $now, generation: 1}')"
  rw_record_add_endpoint "$root_id" "$endpoint_id"

  rw_pane_set "$pid" @rw-endpoint "$endpoint_id"
  rw_pane_set "$pid" @rw-worker "$worker"
  rw_pane_set "$pid" @rw-workspace "${p_remote_path[$i]}"
  rw_pane_set "$pid" @rw-root-id "$root_id"
  [ -n "$session_uuid" ] && rw_pane_set "$pid" @rw-session-uuid "$session_uuid"
  # The laptop pane no longer runs what it last ran; a stale command here
  # would be replayed by a restore and poison the verified save (C3).
  rw_pane_unset "$pid" @workspace-last-command

  if [ "$pid" = "${TMUX_PANE:-}" ]; then
    self_endpoint="$endpoint_id"
    moved=$((moved + 1))
    continue
  fi
  # Local agents are already stopped, so the pane runs its shell (or an
  # editor, already reopened on the remote from its saved files; unsaved
  # buffers stay behind, as the picker warned).
  printf -v loop_cmd '%q %q --fresh' "$SCRIPT_DIR/attach-loop.sh" "$endpoint_id"
  if tmux respawn-pane -k -t "$pid" -c "$pcwd" "$loop_cmd" 2>/dev/null; then
    moved=$((moved + 1))
  else
    failed=$((failed + 1))
    rw_warn "rw handoff: could not start the attach loop in pane $pid (endpoint $endpoint_id is registered; 'rw open --pane $pid' attaches it)."
  fi
done

# S8: visit panes already on this worker in this root become owned panes of
# it (listed in the record, so hand-back brings them back); their visit
# markers go once the mirror lists them (fix wave A, finding 5: never
# before -- with neither, the worker's post-restore would kill the session).
adopted=0
adopted_eps=()
for entry in ${adopt_panes[@]+"${adopt_panes[@]}"}; do
  IFS="$RW_TAB" read -r a_pane a_ep <<<"$entry"
  a_json="$(rw_read_endpoint "$a_ep" 2>/dev/null)" || continue
  rw_write_json_atomic "$(rw_endpoint_file "$a_ep")" "$(printf '%s' "$a_json" | jq -c \
    --arg root_id "$root_id" --arg root_rel "$root_rel" --arg kind "$kind" \
    --arg root_local "$root_local" --arg worker_root "$worker_root" --arg worker_home "$worker_home" \
    --arg now "$now" '
    .kind = "owned" | .root_id = $root_id | .root_rel = $root_rel | .worker_home = $worker_home
    | .workspace.mode = $kind | .workspace.root_local = $root_local | .workspace.worker_root = $worker_root
    | .updated_at = $now')"
  rw_record_add_endpoint "$root_id" "$a_ep"
  rw_pane_set "$a_pane" @rw-root-id "$root_id"
  adopted_eps+=("$a_ep")
  adopted=$((adopted + 1))
done

if rw_mirror_push_from_record "$worker" "$worker_home" "$root_id" </dev/null; then
  [ "${#adopted_eps[@]}" -eq 0 ] || rw_visit_marker_remove "$worker" "$worker_home" "${adopted_eps[@]}" ||
    rw_warn "rw handoff: could not remove the visit markers of the adopted pane(s) on '$worker' (harmless: closing a pane removes its marker)."
else
  rw_warn "rw handoff: could not write the ownership mirror on '$worker' (it is rewritten on the next ownership change)."
  [ "${#adopted_eps[@]}" -eq 0 ] ||
    rw_warn "rw handoff: the adopted pane(s) keep their visit markers there until then, so a restart of that remote keeps their sessions."
fi
# The worker's pane set just changed: a timer save that raced this refused
# its inconsistent capture; ask for a fresh one now (fire and forget).
rw_worker_request_save "$worker"

rw_log_event "handoff" "$self_endpoint" "$worker" "$(rw_elapsed_ms "$start_ts")" \
  "$([ "$failed" -eq 0 ] && echo success || echo partial)" \
  "root=$root_rel kind=$kind panes=$moved adopted=$adopted failed=$failed $(printf '%s' "$sync_out" | jq -r '"renamed=\(.renamed | length) overwritten=\(.overwritten)"' 2>/dev/null)"
printf 'rw: %s is now remote on %s (%d pane(s) moved).\n' "$root_rel" "$worker" "$moved"
# Every pane in the root changed host or owner (CS3). Best effort.
rw_refresh_indicators --root "$root_local"

if [ -n "$self_endpoint" ]; then
  rm -rf "$work"
  rw_root_unlock_all
  trap - EXIT
  exec "$SCRIPT_DIR/attach-loop.sh" "$self_endpoint" --fresh
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
