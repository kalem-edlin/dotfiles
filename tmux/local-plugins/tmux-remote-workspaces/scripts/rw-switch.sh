#!/usr/bin/env bash
# `rw switch` -- soft switch of ONE pane between this machine and a remote
# (docs/tasks/remote-owned-directories.md, "Pane host switching": S3-S5,
# contract CS1). Only the pane changes host, in the same directory: no file
# moves and no ownership changes.
#
#   To the remote that owns the directory's root: an owned endpoint, made as
#   `rw open` makes it (rw_endpoint_open in roots.sh; listed in the record).
#   To any other remote (a root this machine owns, no root, or a remote that
#   does not own it): a visit endpoint (CS2) -- the same hidden worker
#   session and attach loop, never listed in a record. Its directory is the
#   path mapped through the home directory (C1), or the nearest existing
#   parent there, with one line saying so.
#   To this machine (`local`) from a remote pane: the attach loop becomes a
#   local shell in the same pane, window and layout, in the mapped directory
#   (nearest existing parent); the endpoint's worker session is closed and
#   the endpoint unregistered (and removed from its record when owned).
#
# What runs in the pane moves with it:
#   - a shell: nothing to move;
#   - a claudef / pif agent: exported, installed and resumed on the
#     destination with the adapters (no directory sync), confirmed there,
#     and only THEN stopped at the source: never two writers, never none.
#     Refused while it is working, and when its directory does not exist on
#     the destination (Claude finds its transcript by path);
#   - an editor (nvim, vim, vi): reopened on the destination through the
#     editor adapter, best effort (unsaved buffers travel in its session);
#   - anything else: refused (quit it first).
#
# Run inside the pane itself (TMUX_PANE equals --pane, as rw-split.sh and
# rw-new-window.sh do for a fresh pane), nothing is moved and the pane
# becomes the attach loop by exec.
#
# Usage: rw-switch.sh [--pane <pane-id>] --to <worker-alias|local>
#                     [--dir <abs-path> | --dir-of <pane-id>] [--force]
#   --pane defaults to $TMUX_PANE; --dir (a path on THIS machine) defaults to
#   the pane's directory (rw_pane_dir --live: a remote pane's live remote
#   cwd, mapped back). --dir-of takes that live directory from another pane
#   instead: a split or prefix c creates its pane at once and the `rw
#   switch` running in it asks the source pane's remote (no key binding
#   ever waits on ssh).
#   --force (only with --to local): a remote pane whose remote cannot be
#   reached, or is no longer in config.json, is released to a local shell
#   anyway; its endpoint stays registered with a pending close that the next
#   contact with that remote performs (rw_reconcile_pending).
#
# The roots involved are locked (rw_root_lock) for the whole switch, and a
# root with a background transfer in flight (rw bg) is refused. Whether the
# destination owns the directory is decided under the lock, after pending
# actions for that remote ran.
#
# Exit: 0 done; 1 failure, the pane left as it was (also: the pane's remote
#       is restoring its sessions, or its session there is missing while
#       the endpoint records an agent); 3 agent CLI version gate; 6 the
#       destination remote (or, for a remote pane, its own remote) is
#       unreachable; 7 refused (already there, an unsupported program, an
#       agent that is working or whose directory is missing on the
#       destination, a background transfer of the root), one `rw: <reason>`
#       line; 64 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RW_ADAPTERS_DIR: test seam (tests fake the agent adapters).
ADAPTERS_DIR="${RW_ADAPTERS_DIR:-$SCRIPT_DIR/../libexec/adapters}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"

rw_need_jq
rw_config_valid || rw_die "config.json ($RW_CONFIG_FILE) is invalid"

usage() {
  printf 'usage: rw switch [--pane <pane-id>] --to <remote-alias|local> [--dir <abs-path> | --dir-of <pane-id>] [--force]\n'
}

# Worker-side guard: an rw endpoint session is named rw-<8hex>-<8hex>; a
# shell inside one is on the remote, where this pane's endpoint is unknown.
if [ -n "${TMUX:-}" ]; then
  case "$(tmux display-message -p '#{session_name}' 2>/dev/null || true)" in
    rw-????????-????????)
      rw_die "this shell is the remote side of a pane; press prefix e on that pane instead." 7
      ;;
  esac
fi

pane_id="${TMUX_PANE:-}"
dest=""
dir_arg=""
dir_of=""
force="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --pane) pane_id="${2:?}"; shift 2 ;;
    --to) dest="${2:?}"; shift 2 ;;
    --dir) dir_arg="${2:?}"; shift 2 ;;
    --dir-of) dir_of="${2:?}"; shift 2 ;;
    --force) force="true"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[ -n "$pane_id" ] || { usage >&2; exit 64; }
[ -n "$dest" ] || { usage >&2; exit 64; }
case "$dir_arg" in '' | /*) : ;; *) rw_die "switch: --dir takes an absolute path" 64 ;; esac
[ -z "$dir_arg" ] || [ -z "$dir_of" ] || rw_die "switch: --dir and --dir-of exclude each other" 64
[ "$force" != "true" ] || [ "$dest" = "local" ] || rw_die "switch: --force only releases a pane to this machine (--to local)" 64
if [ "$dest" != "local" ] && ! rw_worker_known "$dest"; then
  rw_die "switch: '$dest' is not a configured remote (config.json)" 64
fi
[ -n "$(tmux display-message -pt "$pane_id" -F '#{pane_id}' 2>/dev/null || true)" ] ||
  rw_die "there is no pane $pane_id on this tmux server." 1

self="false"
[ "$pane_id" = "${TMUX_PANE:-}" ] && self="true"
start_ts="$(rw_now_epoch)"
work="$(mktemp -d "${TMPDIR:-/tmp}/rw-switch.XXXXXX")"
trap 'rm -rf "$work"; rw_root_unlock_all' EXIT

ED_PATTERN='(^|/)(nvim|vim|vi)([[:space:]]|$)'
HOME_LOCAL="$(rw_physical_path "$HOME")"

# --- Source: where the pane runs now -----------------------------------------
src_ep="$(rw_pane_get "$pane_id" @rw-endpoint)"
src_worker="$(rw_pane_get "$pane_id" @remote-host)"
src_json=""
if [ -n "$src_ep" ] && src_json="$(rw_read_endpoint "$src_ep" 2>/dev/null)"; then
  [ -n "$src_worker" ] || src_worker="$(printf '%s' "$src_json" | jq -r '.worker // empty')"
else
  src_ep="" src_json="" src_worker=""
fi
src_host="${src_worker:-local}"
src_kind="local"
[ -z "$src_worker" ] || src_kind="remote"

log_fail() { rw_log_event "switch" "$src_ep" "${dest#local}" "$(rw_elapsed_ms "$start_ts")" "fail" "from=$src_kind $1"; }
refuse() {
  log_fail "refused: $1"
  rw_die "$1" 7
}
where() { if [ "$1" = "local" ]; then printf 'on this machine'; else printf 'on that remote'; fi; }
# tilde <path> <home> -- the path as ~/... when it is under <home>.
tilde() {
  # shellcheck disable=SC2088 # a literal ~ for display
  case "$1" in
    "${2%/}") printf '~' ;;
    "${2%/}"/*) printf '~/%s' "${1#"${2%/}"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
is_shell() {
  case "$1" in zsh | bash | sh | fish | dash | ksh | -zsh | -bash | -sh) return 0 ;; esac
  return 1
}

[ "$dest" != "$src_host" ] || refuse "this pane already runs $(where "$dest")."
case "$(printf '%s' "$src_json" | jq -r '.role // empty' 2>/dev/null)" in
  tree | tree-editor) refuse "a remote file tree pane cannot switch; close it with prefix Tab." ;;
esac

# --- Directory and its owner ---------------------------------------------------
# A source remote that is gone from config.json is never asked.
src_known="true"
[ "$src_kind" = "local" ] || rw_worker_known "$src_worker" || src_known="false"
if [ -n "$dir_arg" ]; then
  dir="$dir_arg"
elif [ -n "$dir_of" ]; then
  # A pane made by a split or prefix c: the source pane's live directory,
  # else (the source pane is gone) this pane's own starting directory.
  dir="$(rw_pane_dir "$dir_of" --live)"
  [ -n "$dir" ] || dir="$(rw_pane_dir "$pane_id")"
elif [ "$src_known" = "false" ]; then
  dir="$(rw_pane_dir "$pane_id")"
else
  dir="$(rw_pane_dir "$pane_id" --live)"
fi
[ -n "$dir" ] || dir="$HOME_LOCAL"
dir="$(rw_physical_path "$dir")"

# resolve_owner -- the directory's owner and root, from the records as they
# are NOW (fix wave A, finding 4): run again under the lock and after the
# destination's pending actions, so `owned` is never decided from a record
# that changed meanwhile. A record with a pending forget, or a worker's own
# mirror, does not make a remote the owner (rw_owner_for_path, I2).
resolve_owner() {
  local line record
  owned_id="" owner_worker="" root_local="" root_rel="" root_id="" root_kind="plain" rec_worker_root=""
  if line="$(rw_owner_for_path "$dir")"; then
    IFS="$RW_TAB" read -r owned_id owner_worker root_local <<<"$line"
    record="$(rw_owned_record_read "$owned_id" 2>/dev/null)"
    root_rel="$(printf '%s' "$record" | jq -r '.root_rel // empty')"
    root_kind="$(printf '%s' "$record" | jq -r '.kind // "plain"')"
    rec_worker_root="$(printf '%s' "$record" | jq -r '.worker_root // empty')"
    root_id="$owned_id"
  else
    root_local="$(rw_default_root_for_path "$dir")"
    if root_rel="$(rw_root_rel "$root_local" 2>/dev/null)"; then
      root_id="$(rw_root_id "$root_rel")"
      [ -d "$root_local" ] && root_kind="$(rw_root_kind "$root_local")"
      [ "$root_kind" = "git" ] || root_kind="plain"
    else
      root_rel="" root_local=""
    fi
  fi
  # The pane's own endpoint's root, when that endpoint is listed in a record.
  src_root_id=""
  if [ -n "$src_json" ]; then
    local v
    v="$(printf '%s' "$src_json" | jq -r '.root_id // empty')"
    if [ -n "$v" ] && rw_owned_record_read "$v" 2>/dev/null | jq -e --arg e "$src_ep" '(.endpoints // []) | index($e)' >/dev/null 2>&1; then
      src_root_id="$v"
    fi
  fi
}
resolve_owner

# --- What the pane runs ---------------------------------------------------------
# prog: self | shell | agent | editor. For an agent: provider, a_session,
# a_project (its directory on THIS machine), a_project_src (on the source
# machine), a_mode.
prog="shell" provider="" a_session="" a_project="" a_project_src="" a_mode=""
src_session=""
[ -z "$src_ep" ] || src_session="$(rw_session_name "$src_ep")"
if [ "$self" = "true" ]; then
  prog="self"
elif [ "$src_kind" = "local" ]; then
  pcmd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
  for candidate in pi claude; do
    adapter="$ADAPTERS_DIR/$candidate"
    [ -x "$adapter" ] || continue
    detect_out="$("$adapter" detect --pane "$pane_id" 2>/dev/null </dev/null)" || continue
    provider="$(printf '%s' "$detect_out" | jq -r '.provider // empty' 2>/dev/null)"
    a_session="$(printf '%s' "$detect_out" | jq -r '.session_id // empty' 2>/dev/null)"
    a_project="$(printf '%s' "$detect_out" | jq -r '.project_path // empty' 2>/dev/null)"
    a_mode="$(printf '%s' "$detect_out" | jq -r '.mode_flags // empty' 2>/dev/null)"
    [ -n "$provider" ] && [ -n "$a_session" ] && break
    provider="" a_session="" a_project="" a_mode=""
  done
  if [ -n "$provider" ]; then
    prog="agent"
    a_project="$(rw_physical_path "${a_project:-$dir}")"
    a_project_src="$a_project"
    [ "$(rw_pane_get "$pane_id" @agent_state)" != "working" ] ||
      refuse "the $provider agent in this pane is working; switch it when it is idle."
  else
    case "$pcmd" in
      nvim | vim | vi) prog="editor" ;;
      *)
        is_shell "$pcmd" ||
          refuse "this pane runs '${pcmd:-unknown}', which is neither a shell, an editor, nor a recognized agent session; quit it first."
        ;;
    esac
  fi
else
  probe_status=0
  if [ "$src_known" = "true" ]; then
    rw_worker_agent_probe "$src_worker" "$src_session" >"$work/probe" || probe_status=$?
  else
    probe_status=6
  fi
  if [ "$probe_status" -ne 0 ]; then
    # I4: only a release to this machine with --force goes on (below,
    # under the lock); nothing in the pane can move.
    if [ "$force" != "true" ]; then
      log_fail "source_unreachable"
      rw_die "the remote this pane runs on cannot be reached, so nothing in it can move; nothing changed ('rw switch --to local --force' releases the pane anyway)." 6
    fi
    prog="forced"
  fi
fi
if [ "$src_kind" = "remote" ] && [ "$prog" != "forced" ] && [ "$self" != "true" ]; then
  sed '1,/^---$/d' "$work/probe" >"$work/probe.ps"
  pline="$(sed '/^---$/,$d' "$work/probe" | head -n 1)"
  rpane="$(printf '%s' "$pline" | cut -f2)"
  rppid="$(printf '%s' "$pline" | cut -f3)"
  rastate="$(printf '%s' "$pline" | cut -f4)"
  rrec="$(printf '%s' "$pline" | cut -f5)"
  rpcmd="$(printf '%s' "$pline" | cut -f6)"
  if [ -z "$rpane" ]; then
    # Fix wave A, finding 2: the endpoint's session is not on its remote.
    # During that remote's boot restore it is simply not back yet, and
    # whatever ran in it (an agent the restore brings back) must not be
    # mistaken for a bare shell and have its endpoint closed under it.
    src_provider="$(printf '%s' "$src_json" | jq -r 'if .agent.state == "handed-off" then (.agent.provider // "coding") else (.agent.provider // empty) end' 2>/dev/null)"
    if [ -n "$src_provider" ]; then
      log_fail "source_session_missing_agent"
      rw_die "this pane's session is missing on its remote, but it ran a $src_provider agent there; nothing changed. Wait for that remote to restore it and try again, or close the pane (prefix q) once its work is rescued." 1
    fi
    rstate_status=0
    rstate="$(rw_worker_restore_state "$src_worker")" || rstate_status=$?
    if [ "$rstate_status" -ne 0 ]; then
      log_fail "source_unreachable"
      rw_die "the remote this pane runs on cannot be reached, so nothing in it can move; nothing changed ('rw switch --to local --force' releases the pane anyway)." 6
    fi
    case "$rstate" in
      ready) : ;;
      "incomplete "*)
        log_fail "source_restore_incomplete"
        rw_die "this pane's session is missing on its remote, and $(rw_worker_server_explain "$src_worker" "$rstate"); nothing changed." 1
        ;;
      *)
        log_fail "source_restoring"
        rw_die "the remote this pane runs on is restoring its sessions (this pane's is not back yet); try again when it finishes. Nothing changed." 1
        ;;
    esac
  fi
  live="$(rw_live_provider "$work/probe.ps" "$rppid")"
  if [ -n "$live" ]; then
    tool="$(printf '%s' "$rrec" | jq -r '.tool // empty' 2>/dev/null)"
    a_session="$(printf '%s' "$rrec" | jq -r '.session_id // empty' 2>/dev/null)"
    if [ "$tool" != "$live" ] || [ -z "$a_session" ]; then
      refuse "a $live agent runs in this pane on the remote, but its session cannot be identified (no session record there); quit it or let it record its session, then retry."
    fi
    [ "$rastate" != "working" ] || refuse "the $live agent in this pane is working; switch it when it is idle."
    prog="agent"
    provider="$live"
    a_project_src="$(printf '%s' "$rrec" | jq -r '.cwd // empty' 2>/dev/null)"
    [ -n "$a_project_src" ] || a_project_src="$(printf '%s' "$src_json" | jq -r '.workspace.remote_path // empty')"
    a_project="$(rw_endpoint_local_path "$src_json" "$a_project_src")"
    rec_session="$(printf '%s' "$src_json" | jq -r '.agent.transcript_id // .agent.session_id // empty')"
    if [ "$(printf '%s' "$src_json" | jq -r '.agent.provider // empty')" = "$live" ] && [ "$rec_session" = "$a_session" ]; then
      a_mode="$(printf '%s' "$src_json" | jq -r '.agent.mode_flags // empty')"
    fi
  else
    case "$rpcmd" in
      nvim | vim | vi) prog="editor" ;;
      *)
        if [ -z "$rpane" ] || is_shell "$rpcmd"; then
          prog="shell"
        elif [ -n "$rppid" ] && rw_ps_tree_matches "$ED_PATTERN" "$rppid" <"$work/probe.ps"; then
          prog="editor"
        else
          refuse "this pane runs '$rpcmd' on the remote, which is neither a shell, an editor, nor a recognized agent session; quit it first."
        fi
        ;;
    esac
  fi
fi
if [ "$prog" = "agent" ] && [ ! -x "$ADAPTERS_DIR/$provider" ]; then
  refuse "there is no $provider adapter here, so its session cannot move."
fi

# The worker's home as the source endpoint knows it (asks the remote only
# when the endpoint does not say).
src_home=""
source_home() {
  [ -z "$src_home" ] || return 0
  src_home="$(rw_endpoint_worker_home "$src_json")"
  if [ -z "$src_home" ]; then
    src_home="$("$SCRIPT_DIR/preflight.sh" --worker "$src_worker" 2>/dev/null | jq -r '.home // empty' 2>/dev/null)"
  fi
  [ -n "$src_home" ]
}

# --- Agent CLI version policy -----------------------------------------------------
# Toward a remote: its CLI must not be older than this machine's (exit 3).
gate_to() { # <worker>
  local out status=0
  out="$("$ADAPTERS_DIR/$provider" versions --worker "$1" 2>"$work/versions.err" </dev/null)" || status=$?
  if [ "$status" -eq 3 ]; then
    log_fail "agent_version_blocked:$provider"
    rw_warn "the remote $provider CLI is older than this machine's, so its session cannot be resumed there; nothing changed:"
    rw_warn "$(cat "$work/versions.err")"
    exit 3
  elif [ "$status" -ne 0 ]; then
    log_fail "agent_version_check_failed:$provider"
    rw_die "the $provider version check failed (exit $status): $(cat "$work/versions.err"); nothing changed." 1
  fi
  [ "$(printf '%s' "$out" | jq -r '.policy // empty' 2>/dev/null)" != "newer_worker" ] ||
    rw_warn "notice: the remote $provider CLI is newer than this machine's; proceeding."
}
# Away from a remote: a CLI there newer than this machine's wrote the session.
gate_from() { # <worker>
  local out status=0 lcli wcli
  out="$("$ADAPTERS_DIR/$provider" versions --worker "$1" 2>"$work/versions.err" </dev/null)" || status=$?
  if [ "$status" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r '.policy // empty')" = "newer_worker" ]; then
    lcli="$(printf '%s' "$out" | jq -r 'if (.local | type) == "object" then .local.cli // empty else .local // empty end')"
    wcli="$(printf '%s' "$out" | jq -r 'if (.worker | type) == "object" then .worker.cli // empty else .worker // empty end')"
    if [ -z "$lcli" ] || [ "$lcli" != "$wcli" ]; then
      log_fail "agent_version_blocked:$provider"
      rw_warn "this machine's $provider CLI ($lcli) is older than the remote one ($wcli) that wrote this session; update it and retry. Nothing changed."
      exit 3
    fi
  elif [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    rw_warn "$provider version check failed (exit $status); continuing. $(cat "$work/versions.err")"
  fi
}
# Remote to another remote (fix wave A, finding 8): the session moves from
# <src> to <dest>, so <dest>'s CLI is compared with <src>'s, not with this
# machine's: it must not be older than the one that wrote the session. Each
# `versions --worker` reports that remote's CLI (exit 3 only means it is
# older than this machine's, which does not matter here).
cli_of() { # <versions JSON> -- the remote CLI version in it
  printf '%s' "$1" | jq -r 'if (.worker | type) == "object" then .worker.cli // empty else .worker // empty end' 2>/dev/null
}
gate_between() { # <src> <dest>
  local out status=0 scli dcli
  out="$("$ADAPTERS_DIR/$provider" versions --worker "$2" 2>"$work/versions.err" </dev/null)" || status=$?
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    log_fail "agent_version_check_failed:$provider"
    rw_die "the $provider version check on the destination remote failed (exit $status): $(cat "$work/versions.err"); nothing changed." 1
  fi
  dcli="$(cli_of "$out")"
  status=0
  out="$("$ADAPTERS_DIR/$provider" versions --worker "$1" 2>"$work/versions.err" </dev/null)" || status=$?
  scli=""
  [ "$status" -ne 0 ] && [ "$status" -ne 3 ] || scli="$(cli_of "$out")"
  if [ -z "$dcli" ] || [ -z "$scli" ]; then
    rw_warn "could not read the $provider CLI version on both remotes; continuing."
    return 0
  fi
  if [ "$dcli" != "$scli" ] && [ "$(printf '%s\n%s\n' "$dcli" "$scli" | sort -V | tail -n 1)" = "$scli" ]; then
    log_fail "agent_version_blocked:$provider"
    rw_warn "the destination remote's $provider CLI ($dcli) is older than the one ($scli) on the remote that wrote this session; update it there and retry. Nothing changed."
    exit 3
  fi
  [ "$dcli" = "$scli" ] || rw_warn "notice: the destination remote's $provider CLI ($dcli) is newer than the source's ($scli); proceeding."
}

local_agent_alive() { # <pane>
  local ppid
  ppid="$(tmux display-message -pt "$1" -F '#{pane_pid}' 2>/dev/null || true)"
  [ -n "$ppid" ] && ps axo pid=,ppid=,command= 2>/dev/null | rw_ps_tree_matches "$(rw_provider_pattern "$provider")" "$ppid"
}

# The source endpoint goes once the pane no longer runs its attach loop: its
# worker session is closed, and an owned one leaves its record and mirror.
close_source_endpoint() {
  rw_close_endpoint_core "$src_ep" "switch" </dev/null
  if [ -n "$src_root_id" ] && rw_owned_record_read "$src_root_id" >/dev/null 2>&1; then
    rw_record_remove_endpoint "$src_root_id" "$src_ep"
    source_home && rw_mirror_push_from_record "$src_worker" "$src_home" "$src_root_id" </dev/null
  fi
  rw_worker_request_save "$src_worker"
}

# lock_roots -- every root this switch touches is locked for the rest of
# the run (rw open, handoff, hand-back, forget and reclaim take the same
# lock), visit switches included, and a root with a background transfer in
# flight is refused: the transfer's runner waits for idle agents WITHOUT the
# lock, and a switch then could put a second writer on the same transcript
# or leave an endpoint the transfer never sees (fix wave A, finding 3).
lock_roots() {
  local id
  for id in "$root_id" "$src_root_id"; do
    [ -n "$id" ] || continue
    rw_root_lock_or_die "$id" "rw switch"
    if rw_bg_job_live "$id"; then
      refuse "a background transfer of $(tilde "$(jq -r '.root_local // empty' "$(rw_bg_dir)/$id/job.json" 2>/dev/null || true)" "$HOME_LOCAL") is running; switch this pane when it has finished."
    fi
  done
}
lock_roots
# Under the lock: the records as they are now.
resolve_owner
lock_roots

prog_label="$prog"
[ "$prog" != "agent" ] || prog_label="agent:$provider"

# =============================================================================
# Release to this machine while the pane's remote is unreachable (I4)
# =============================================================================
if [ "$prog" = "forced" ]; then
  local_dir="$(rw_local_existing_dir "$dir")"
  if ! rw_release_pane "$pane_id" "$local_dir"; then
    log_fail "release_failed"
    rw_die "could not give this pane a local shell; nothing changed." 1
  fi
  # The endpoint stays registered with a pending close: the next contact
  # with that remote (rw_reconcile_pending) closes its session and whatever
  # still runs in it. It leaves its record now, so a hand-back or reclaim
  # never looks for it.
  rw_write_json_atomic "$(rw_endpoint_file "$src_ep")" "$(printf '%s' "$src_json" | jq -c --arg now "$(rw_now_iso)" '
    .pending = {action: "close", reason: "released to this machine while the remote was unreachable", at: $now}
    | .updated_at = $now')"
  [ -z "$src_root_id" ] || rw_record_remove_endpoint "$src_root_id" "$src_ep"
  rw_refresh_indicators --pane "$pane_id"
  rw_log_event "switch" "$src_ep" "" "$(rw_elapsed_ms "$start_ts")" "success" "from=remote to=local program=forced dir=$dir pending_close=1"
  printf 'rw: this pane runs on this machine again, in %s; its remote could not be reached, so anything still running there is stopped when that remote is next reached.\n' \
    "$(tilde "$local_dir" "$HOME_LOCAL")"
  exit 0
fi

# =============================================================================
# To this machine
# =============================================================================
if [ "$dest" = "local" ]; then
  local_dir="$(rw_local_existing_dir "$dir")"
  if [ "$prog" = "agent" ]; then
    [ -d "$a_project" ] ||
      refuse "the agent's directory $(tilde "$a_project" "$HOME_LOCAL") does not exist on this machine; nothing changed."
    gate_from "$src_worker"
    adapter="$ADAPTERS_DIR/$provider"
    mkdir -p "$work/agent"
    "$adapter" export --session-id "$a_session" --project-path "$a_project_src" --out "$work/agent" --worker "$src_worker" \
      </dev/null >/dev/null 2>"$work/agent.err" || {
      log_fail "agent_export"
      rw_die "$provider export from the remote failed: $(cat "$work/agent.err"); nothing changed." 1
    }
    tid="$(jq -r '.session_id // empty' "$work/agent/manifest.json" 2>/dev/null)"
    "$adapter" install --snapshot "$work/agent" --dest-path "$a_project" </dev/null >/dev/null 2>"$work/agent.err" || {
      log_fail "agent_install"
      rw_die "$provider install here failed: $(cat "$work/agent.err"); nothing changed." 1
    }
    rc_args=(resume-cmd --dest-path "$a_project" --session-id "${tid:-$a_session}")
    [ -n "$a_mode" ] && rc_args+=(--mode-flags "$a_mode")
    local_resume="$("$adapter" "${rc_args[@]}" 2>"$work/agent.err" </dev/null)" || {
      log_fail "agent_resume_cmd"
      rw_die "$provider resume-cmd failed: $(cat "$work/agent.err"); nothing changed." 1
    }
  fi
  editor_cmd=""
  if [ "$prog" = "editor" ] && [ -x "$ADAPTERS_DIR/editor" ]; then
    mkdir -p "$work/editor"
    if ! source_home ||
      ! "$ADAPTERS_DIR/editor" export --pane "$src_session" --worker "$src_worker" --out "$work/editor" </dev/null >/dev/null 2>"$work/editor.err" ||
      ! editor_cmd="$("$ADAPTERS_DIR/editor" install --snapshot "$work/editor" --from-root "$src_home" --to-root "$HOME_LOCAL" \
        --dest-dir "$local_dir" --dest-file "$(rw_state_dir)/editor-sessions/$src_ep.vim" </dev/null 2>"$work/editor.err")"; then
      editor_cmd=""
      rw_warn "could not capture the editor in this pane, so it will not be reopened here; open it again. $(head -c 300 "$work/editor.err" 2>/dev/null)"
    fi
  fi

  [ "$local_dir" = "$dir" ] ||
    printf 'rw: %s does not exist on this machine; the pane opens in %s.\n' "$(tilde "$dir" "$HOME_LOCAL")" "$(tilde "$local_dir" "$HOME_LOCAL")"

  # reattach_source -- roll back: the pane runs its attach loop again
  # (options first, so the loop never reads itself as released).
  reattach_source() {
    local cmd
    rw_bind_pane "$pane_id" "$src_ep"
    printf -v cmd '%q %q' "$SCRIPT_DIR/attach-loop.sh" "$src_ep"
    tmux respawn-pane -k -t "$pane_id" -c "$(rw_local_existing_dir "$(printf '%s' "$src_json" | jq -r '.workspace.focus_path // empty')")" "$cmd" 2>/dev/null
  }

  if ! rw_release_pane "$pane_id" "$local_dir"; then
    log_fail "release_failed"
    rw_die "could not give this pane a local shell; nothing changed." 1
  fi
  rw_wait_local_shell "$pane_id" || rw_warn "pane $pane_id did not show a local shell yet."
  if [ "$prog" = "agent" ]; then
    if ! tmux send-keys -t "$pane_id" "$local_resume" Enter 2>/dev/null ||
      ! rw_wait_local_provider_started "$pane_id" "$provider"; then
      rw_stop_local_agent "$pane_id" "$provider" >/dev/null 2>&1
      reattach_source || rw_warn "could not reattach pane $pane_id; 'rw open --pane $pane_id' does."
      log_fail "local_resume_unconfirmed"
      rw_die "could not confirm the $provider agent started here; the pane is back on the remote, its agent untouched." 1
    fi
  fi
  if [ -n "$editor_cmd" ]; then
    if ! tmux send-keys -t "$pane_id" "$editor_cmd" Enter 2>/dev/null ||
      ! rw_wait_local_provider_started "$pane_id" "$ED_PATTERN"; then
      rw_warn "could not confirm the editor reopened in this pane; run: $editor_cmd"
    fi
  fi
  # Confirmed here: the remote copy of the agent stops now (closing its
  # session would stop it anyway; this lets it exit cleanly first).
  if [ "$prog" = "agent" ]; then
    rw_stop_remote_agent "$src_worker" "$src_session" "$provider" ||
      rw_warn "could not stop the $provider agent on the remote cleanly; closing its session ends it."
  fi
  close_source_endpoint
  rw_refresh_indicators --pane "$pane_id"
  rw_log_event "switch" "$src_ep" "" "$(rw_elapsed_ms "$start_ts")" "success" "from=remote to=local program=$prog_label dir=$dir"
  printf 'rw: this pane runs on this machine again, in %s.\n' "$(tilde "$local_dir" "$HOME_LOCAL")"
  exit 0
fi

# =============================================================================
# To a remote
# =============================================================================
preflight_status=0
preflight_json="$("$SCRIPT_DIR/preflight.sh" --worker "$dest")" || preflight_status=$?
if [ "$preflight_status" -ne 0 ]; then
  log_fail "preflight_failed"
  exit "$(rw_preflight_exit "$preflight_json")"
fi
worker_home="$(printf '%s' "$preflight_json" | jq -r '.home')"
identity="$(printf '%s' "$preflight_json" | jq -r '.hostname // empty')"
[ -n "$worker_home" ] && [ "$worker_home" != "null" ] || rw_die "preflight did not report the remote home directory; nothing changed." 1

# Pending actions for that remote run first (a forget or reclaim recorded
# while it was unreachable may remove the very record that would make this
# pane owned); then the owner is decided from what is left (finding 4).
rw_reconcile_pending "$dest" "$worker_home"
resolve_owner
lock_roots

if [ -n "$owned_id" ] && [ "$owner_worker" = "$dest" ]; then
  kind="owned"
  worker_root="${rec_worker_root:-${worker_home%/}/$root_rel}"
  ws_root_local="$root_local"
  remote_path="$(rw_path_under_root "$dir" "$root_local" "$worker_root")"
else
  kind="visit"
  if [ -n "$root_rel" ]; then
    ws_root_local="$root_local"
    worker_root="${worker_home%/}/$root_rel"
  else
    ws_root_local="$HOME_LOCAL"
    worker_root="$worker_home"
  fi
  remote_path="$(rw_map_home_path "$dir" "$HOME_LOCAL" "$worker_home")"
fi
# dest_path <path on this machine> -- the same path on the destination.
dest_path() {
  if [ "$kind" = "owned" ]; then
    case "$1" in
      "$root_local" | "$root_local"/*)
        rw_path_under_root "$1" "$root_local" "$worker_root"
        return 0
        ;;
    esac
  fi
  rw_map_home_path "$1" "$HOME_LOCAL" "$worker_home"
}

unreachable() {
  log_fail "unreachable"
  rw_die "that remote cannot be reached; nothing changed." 6
}
if [ "$prog" = "agent" ]; then
  a_dest="$(dest_path "$a_project")"
  a_exist="$(rw_worker_existing_dir "$dest" "$a_dest")" || unreachable
  [ "$a_exist" = "$a_dest" ] ||
    refuse "the agent's directory $(tilde "$a_dest" "$worker_home") does not exist on that remote; nothing changed."
  if [ "$src_kind" = "local" ]; then gate_to "$dest"; else gate_between "$src_worker" "$dest"; fi
fi
existing="$(rw_worker_existing_dir "$dest" "$remote_path")" || unreachable
if [ "$existing" != "$remote_path" ]; then
  printf 'rw: %s does not exist on that remote; the pane opens in %s there.\n' \
    "$(tilde "$remote_path" "$worker_home")" "$(tilde "$existing" "$worker_home")"
  remote_path="$existing"
fi

status=0
rw_endpoint_open "$kind" "$dest" "$worker_home" "$identity" "$pane_id" "$root_id" "$root_rel" "$root_kind" \
  "$ws_root_local" "$worker_root" "$dir" "$remote_path" switch || status=$?
if [ "$status" -ne 0 ]; then
  log_fail "remote_session: $RW_WORKER_SERVER_ERROR"
  rw_die "could not create the remote session for this pane: $RW_WORKER_SERVER_ERROR; nothing changed." "$([ "$status" -eq 6 ] && echo 6 || echo 1)"
fi
new_ep="$RW_ENDPOINT_ID"
new_session="$(rw_session_name "$new_ep")"

# fail_new <reason> -- nothing at the source was stopped yet: undo the new
# endpoint (its session, and any agent started in it, goes with it).
fail_new() {
  rw_endpoint_discard "$new_ep" "switch-failed"
  log_fail "$1"
  rw_die "$1; nothing changed." 1
}

resume_cmd="" tid=""
if [ "$prog" = "agent" ]; then
  adapter="$ADAPTERS_DIR/$provider"
  mkdir -p "$work/agent"
  export_args=(export --session-id "$a_session" --project-path "$a_project_src" --out "$work/agent")
  [ "$src_kind" = "local" ] || export_args+=(--worker "$src_worker")
  "$adapter" "${export_args[@]}" </dev/null >/dev/null 2>"$work/agent.err" ||
    fail_new "$provider export failed: $(cat "$work/agent.err")"
  tid="$(jq -r '.session_id // empty' "$work/agent/manifest.json" 2>/dev/null)"
  tid="${tid:-$a_session}"
  "$adapter" install --snapshot "$work/agent" --dest-path "$a_dest" --worker "$dest" </dev/null >/dev/null 2>"$work/agent.err" ||
    fail_new "$provider install on the remote failed: $(cat "$work/agent.err")"
  rc_args=(resume-cmd --dest-path "$a_dest" --session-id "$tid")
  [ -n "$a_mode" ] && rc_args+=(--mode-flags "$a_mode")
  resume_cmd="$("$adapter" "${rc_args[@]}" 2>"$work/agent.err" </dev/null)" ||
    fail_new "$provider resume-cmd failed: $(cat "$work/agent.err")"
  rw_ssh_batch "$dest" "$(rw_ssh_status_timeout)" \
    "tmux send-keys -t $(rw_shquote "$new_session") $(rw_shquote "$resume_cmd") Enter" </dev/null >/dev/null 2>&1 ||
    fail_new "could not start the $provider resume on the remote"
  rw_wait_remote_provider_started "$dest" "$new_session" "$provider" </dev/null ||
    fail_new "could not confirm the $provider agent started on the remote"
fi

editor_cmd=""
if [ "$prog" = "editor" ] && [ -x "$ADAPTERS_DIR/editor" ]; then
  mkdir -p "$work/editor"
  if [ "$src_kind" = "local" ]; then
    ed_args=(export --pane "$pane_id" --out "$work/editor")
    from_home="$HOME_LOCAL"
  else
    ed_args=(export --pane "$src_session" --worker "$src_worker" --out "$work/editor")
    source_home
    from_home="$src_home"
  fi
  if [ -z "$from_home" ] ||
    ! "$ADAPTERS_DIR/editor" "${ed_args[@]}" </dev/null >/dev/null 2>"$work/editor.err" ||
    ! editor_cmd="$("$ADAPTERS_DIR/editor" install --snapshot "$work/editor" --from-root "$from_home" --to-root "$worker_home" \
      --dest-dir "$remote_path" --dest-file "$(rw_state_dir_at "$worker_home")/editor-sessions/$new_ep.vim" \
      --worker "$dest" </dev/null 2>"$work/editor.err")"; then
    editor_cmd=""
    rw_warn "could not capture the editor in this pane, so it was not reopened on the remote; open it again there. $(head -c 300 "$work/editor.err" 2>/dev/null)"
  elif ! rw_ssh_batch "$dest" "$(rw_ssh_status_timeout)" \
    "tmux send-keys -t $(rw_shquote "$new_session") $(rw_shquote "$editor_cmd") Enter" </dev/null >/dev/null 2>&1 ||
    ! rw_wait_remote_provider_started "$dest" "$new_session" "$ED_PATTERN" </dev/null; then
    rw_warn "could not confirm the editor reopened on the remote; in this pane run: $editor_cmd"
  fi
fi

# Confirmed on the remote: only now does the source agent stop.
if [ "$prog" = "agent" ]; then
  stopped="true"
  if [ "$src_kind" = "local" ]; then
    rw_stop_local_agent "$pane_id" "$provider" || { local_agent_alive "$pane_id" && stopped="false"; }
  else
    rw_stop_remote_agent "$src_worker" "$src_session" "$provider" || stopped="false"
  fi
  if [ "$stopped" != "true" ]; then
    rw_stop_remote_agent "$dest" "$new_session" "$provider" >/dev/null 2>&1
    fail_new "the $provider agent at the source did not stop, so the copy started on the remote was stopped again"
  fi
fi

# --- Commit -----------------------------------------------------------------------
if [ "$prog" = "agent" ] || [ -n "$editor_cmd" ]; then
  ej="$(rw_read_endpoint "$new_ep")"
  rw_write_json_atomic "$(rw_endpoint_file "$new_ep")" "$(printf '%s' "$ej" | jq -c \
    --arg provider "$provider" --arg session "$a_session" --arg transcript "$tid" --arg resume "$resume_cmd" \
    --arg pfocus "$a_project" --arg pworker "${a_dest:-}" --arg mode "$a_mode" --arg editor "$editor_cmd" \
    --arg now "$(rw_now_iso)" '
    (if $provider == "" then . else .agent = {provider: $provider, session_id: $session, transcript_id: $transcript,
      resume_intent: $resume, project_path_focus: $pfocus, project_path_worker: $pworker,
      mode_flags: (if $mode == "" then null else $mode end), outcome: "resumed",
      divergence_risk: false, state: "handed-off"} end)
    | (if $editor == "" then . else .editor = {reopen_intent: $editor} end)
    | .updated_at = $now')"
fi
rw_bind_pane "$pane_id" "$new_ep"
rw_log_event "switch" "$new_ep" "$dest" "$(rw_elapsed_ms "$start_ts")" "success" \
  "from=$src_kind to=remote kind=$kind program=$prog_label dir=$dir"
# New session on the worker: refresh its snapshot (fire and forget).
rw_worker_request_save "$dest"

if [ "$self" = "true" ]; then
  rm -rf "$work"
  rw_root_unlock_all # exec skips the EXIT trap
  trap - EXIT
  exec "$SCRIPT_DIR/attach-loop.sh" "$new_ep" --fresh
fi

printf -v loop_cmd '%q %q --fresh' "$SCRIPT_DIR/attach-loop.sh" "$new_ep"
if ! tmux respawn-pane -k -t "$pane_id" -c "$(rw_local_existing_dir "$dir")" "$loop_cmd" 2>/dev/null; then
  if [ "$prog" = "agent" ]; then
    # The agent already runs on the remote and the source copy is stopped:
    # the new endpoint stays registered and the pane stays bound to it (rw
    # open --pane attaches it). A remote source endpoint is closed now --
    # nothing runs in it any more, and nothing else would ever close it
    # (fix wave A, finding 7); its old attach loop sees the pane rebound and
    # gives way to a local shell.
    [ "$src_kind" = "local" ] || close_source_endpoint
    log_fail "respawn_failed_after_move"
    rw_die "the $provider agent now runs on the remote, but the attach loop did not start in pane $pane_id; 'rw open --pane $pane_id' attaches it." 1
  fi
  if [ -n "$src_ep" ]; then rw_bind_pane "$pane_id" "$src_ep"; else
    for o in @rw-endpoint @rw-worker @rw-workspace @rw-root-id; do rw_pane_unset "$pane_id" "$o"; done
  fi
  fail_new "could not start the attach loop in pane $pane_id"
fi
[ "$src_kind" = "local" ] || close_source_endpoint
rw_refresh_indicators --pane "$pane_id"
printf 'rw: this pane now runs on the remote, in %s.\n' "$(tilde "$remote_path" "$worker_home")"
exit 0
