#!/usr/bin/env bash
# Shared helpers for tmux-remote-workspaces. Sourced by every script; never
# executed directly. Mirrors the conventions of the sibling
# tmux-workspace-resurrect/scripts/common.sh.

RW_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RW_CONFIG_FILE="${TMUX_REMOTE_WORKSPACES_CONFIG:-$RW_PLUGIN_DIR/config.json}"

# ---------------------------------------------------------------------------
# Paths (state root: ~/.local/state/tmux-remote-workspaces/)
# ---------------------------------------------------------------------------

rw_state_dir() {
  printf '%s\n' "${TMUX_REMOTE_WORKSPACES_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-remote-workspaces}"
}

# rw_state_dir_at <home>
# Same construction as rw_state_dir(), parameterized by an explicit $HOME --
# used for a REMOTE worker's default state root (from preflight's queried
# `.home`, not this process's own $HOME/$XDG_STATE_HOME, which describe the
# LOCAL machine and are meaningless for a path that must exist on the
# worker). Still honors TMUX_REMOTE_WORKSPACES_STATE_DIR so a test harness
# running a fake worker on the SAME machine (RW_SSH_BIN pointed at a
# same-host fake ssh) can redirect both sides into one isolated sandbox with
# a single override env var; in real production use (no override set) this
# is a fixed, non-configurable `$worker_home/.local/state/...` default,
# since a real ssh session never inherits this process's local env.
rw_state_dir_at() {
  local home="$1"
  printf '%s\n' "${TMUX_REMOTE_WORKSPACES_STATE_DIR:-${XDG_STATE_HOME:-$home/.local/state}/tmux-remote-workspaces}"
}

rw_machine_id_file() { printf '%s/machine-id\n' "$(rw_state_dir)"; }
rw_sessions_file() { printf '%s/sessions.jsonl\n' "$(rw_state_dir)"; }
rw_endpoints_dir() { printf '%s/endpoints\n' "$(rw_state_dir)"; }
rw_tombstones_dir() { printf '%s/tombstones\n' "$(rw_state_dir)"; }
rw_events_file() { printf '%s/events.jsonl\n' "$(rw_state_dir)"; }
rw_endpoint_file() { printf '%s/%s.json\n' "$(rw_endpoints_dir)" "$1"; }
rw_tombstone_file() { printf '%s/%s.json\n' "$(rw_tombstones_dir)" "$1"; }

rw_ensure_private_dir() {
  local dir="$1"
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

rw_log() {
  local message="$1"
  local state_dir
  state_dir="$(rw_state_dir)"
  rw_ensure_private_dir "$state_dir"
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" >>"$state_dir/rw.log"
  chmod 0600 "$state_dir/rw.log" 2>/dev/null || true
}

rw_warn() { printf 'rw: %s\n' "$1" >&2; }
rw_die() {
  rw_warn "$1"
  exit "${2:-1}"
}

rw_need_jq() {
  command -v jq >/dev/null 2>&1 || rw_die "jq is required but not installed (this plugin never installs anything itself)."
}

# Simple, portable mutex (mkdir is atomic on every POSIX filesystem, unlike
# `flock` which isn't universally available). Used to make check-then-act
# registry sequences race-safe against overlapping invocations -- observed in
# practice: tmux can invoke a freshly-`set-hook`'d session-created command
# once per already-existing session at registration time, racing the
# explicit backfill loop in tmux-remote-workspaces.tmux.
rw_with_lock() {
  local lock_name="$1"
  shift
  local lock_dir waited
  lock_dir="$(rw_state_dir)/locks/$lock_name"
  rw_ensure_private_dir "$(dirname "$lock_dir")"
  waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -gt 100 ] && break # ~5s stale-lock guard; never hang forever
  done
  "$@"
  local status=$?
  rmdir "$lock_dir" 2>/dev/null || true
  return "$status"
}

# ---------------------------------------------------------------------------
# Identity: machine id, uuids, short ids
# ---------------------------------------------------------------------------

rw_new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
  else
    jq -nr '[range(32)] | map("0123456789abcdef"[now*1000000+.|floor % 16:][:1]) | join("")'
  fi
}

# Short 8-hex-char id, used for endpoint ids and embedded in remote session
# names. Not required to be globally unique on its own -- the registry file
# it names is the source of truth, and a collision would simply overwrite a
# file that doctor/status can flag.
rw_new_short_id() { rw_new_uuid | tr -d '-' | cut -c1-8; }

# Lazily create the single-line focus-machine identity UUID.
rw_machine_id() {
  local file
  file="$(rw_machine_id_file)"
  if [ ! -s "$file" ]; then
    rw_ensure_private_dir "$(dirname "$file")"
    local tmp
    tmp="$(mktemp "$(dirname "$file")/.machine-id.XXXXXX")"
    rw_new_uuid >"$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
  fi
  cat "$file"
}

rw_machine_short_id() { rw_machine_id | tr -d '-' | cut -c1-8; }

# Canonical remote endpoint session name. Dash-separated: tmux (>= 3.x)
# silently rewrites "." in session names to "_" ("." is target syntax), so a
# dotted convention would never match on has-session/list-sessions. Both id
# components are 8 hex chars (no dashes), so the fixed "rw-<machine>-" prefix
# parses unambiguously.
rw_session_name() { printf 'rw-%s-%s' "$(rw_machine_short_id)" "${1:?endpoint id required}"; }
rw_session_prefix() { printf 'rw-%s-' "$(rw_machine_short_id)"; }

rw_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Float seconds via jq (portable across macOS/BSD and GNU date, both of which
# disagree on sub-second precision flags).
rw_now_epoch() { jq -n 'now'; }

rw_elapsed_ms() {
  local start="$1" end
  end="$(rw_now_epoch)"
  jq -n --argjson s "$start" --argjson e "$end" '(($e - $s) * 1000) | round'
}

# ---------------------------------------------------------------------------
# Event log: jsonl, append-only, local only
# ---------------------------------------------------------------------------

rw_log_event() {
  local event="$1" endpoint="${2:-}" worker="${3:-}" duration_ms="${4:-}" outcome="${5:-}" detail="${6:-}"
  local events_file
  rw_ensure_private_dir "$(rw_state_dir)"
  events_file="$(rw_events_file)"

  local duration_json="null"
  case "$duration_ms" in
    '' | *[!0-9]*) duration_json="null" ;;
    *) duration_json="$duration_ms" ;;
  esac

  jq -nc \
    --arg ts "$(rw_now_iso)" \
    --arg event "$event" \
    --arg endpoint "$endpoint" \
    --arg worker "$worker" \
    --argjson duration_ms "$duration_json" \
    --arg outcome "$outcome" \
    --arg detail "$detail" \
    '{ts: $ts, event: $event, endpoint: $endpoint, worker: $worker, duration_ms: $duration_ms, outcome: $outcome, detail: $detail}' \
    >>"$events_file"
  chmod 0600 "$events_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Session UUID registry (sessions.jsonl): append-only, latest line wins.
# ---------------------------------------------------------------------------

rw_register_session_uuid() {
  local uuid="$1" session_name="$2"
  rw_ensure_private_dir "$(rw_state_dir)"
  jq -nc \
    --arg uuid "$uuid" \
    --arg session_name "$session_name" \
    --arg ts "$(rw_now_iso)" \
    '{uuid: $uuid, session_name: $session_name, ts: $ts}' \
    >>"$(rw_sessions_file)"
  chmod 0600 "$(rw_sessions_file)" 2>/dev/null || true
}

# Latest known tmux session name for a stable session uuid.
rw_session_name_for_uuid() {
  local uuid="$1" file
  file="$(rw_sessions_file)"
  [ -f "$file" ] || return 0
  jq -rs --arg uuid "$uuid" \
    '[.[] | select(.uuid == $uuid)] | last | .session_name // empty' \
    "$file" 2>/dev/null
}

# Latest known stable uuid for a tmux session name (name is renameable, so
# this is best-effort and only used for backfill/diagnostics).
rw_session_uuid_for_name() {
  local name="$1" file
  file="$(rw_sessions_file)"
  [ -f "$file" ] || return 0
  jq -rs --arg name "$name" \
    '[.[] | select(.session_name == $name)] | last | .uuid // empty' \
    "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Pane options (cache only -- do not survive server restart)
# ---------------------------------------------------------------------------

rw_pane_get() {
  local pane_id="$1" option="$2"
  tmux show-option -pqvt "$pane_id" "$option" 2>/dev/null || true
}

rw_pane_set() {
  local pane_id="$1" option="$2" value="$3"
  tmux set-option -pqt "$pane_id" "$option" "$value" 2>/dev/null || true
}

rw_pane_unset() {
  local pane_id="$1" option="$2"
  tmux set-option -pqut "$pane_id" "$option" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Registry: endpoints/<id>.json and tombstones/<id>.json (atomic writes)
# ---------------------------------------------------------------------------

rw_write_json_atomic() {
  local file="$1" json="$2" dir tmp
  dir="$(dirname "$file")"
  rw_ensure_private_dir "$dir"
  tmp="$(mktemp "$dir/.$(basename "$file").XXXXXX")"
  printf '%s' "$json" >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}

rw_read_endpoint() {
  local endpoint_id="$1" file
  file="$(rw_endpoint_file "$endpoint_id")"
  [ -f "$file" ] || return 1
  cat "$file"
}

rw_endpoint_exists() { [ -f "$(rw_endpoint_file "$1")" ]; }
rw_tombstone_exists() { [ -f "$(rw_tombstone_file "$1")" ]; }

rw_write_tombstone() {
  local endpoint_id="$1" generation="$2" reason="$3"
  local json
  json="$(jq -nc \
    --arg ts "$(rw_now_iso)" \
    --arg endpoint_id "$endpoint_id" \
    --argjson generation "${generation:-0}" \
    --arg reason "$reason" \
    '{ts: $ts, "endpoint-id": $endpoint_id, generation: $generation, reason: $reason}')"
  rw_write_json_atomic "$(rw_tombstone_file "$endpoint_id")" "$json"
}

# rw_close_endpoint_core <endpoint_id> <reason> [worker_override]
# Tombstone-first teardown of a single endpoint's remote session and
# registry entry (steps 1-3 of intentional close; see
# initial-plan.md "Endpoint lifetime follows user intent"):
#   1. Write the tombstone FIRST, so a crash mid-cleanup can never let an
#      older resurrect snapshot revive a deliberately closed endpoint.
#   2. Release/remove the registry entry.
#   3. Best-effort remote teardown (an unreachable/already-gone worker
#      session is expected/fine -- the tombstone is what makes this
#      reconcilable, not a successful kill).
# Never touches a local pane -- callers that own a bound pane (rw-close.sh)
# still clear their own @rw-* cache options and close the pane themselves
# afterward. Shared by rw-close.sh (pane-driven, interactive/keybinding
# path), libexec/reconcile (id-driven orphan disposal, no local pane), and
# attach-loop.sh (id-driven, remote-intentional-close discrimination).
#
# [worker_override] is required for a PURE remote orphan: reconcile
# discovers such a session over ssh on a specific worker with no local
# registry entry at all (that absence is exactly what makes it orphaned),
# so there is nothing on disk to read the worker alias back from. When the
# registry entry exists (the ordinary rw-close.sh/attach-loop.sh case), its
# own `.worker` field always wins over the override, so passing the alias
# defensively there is harmless.
# Always returns 0; logs its own "close" event.
rw_close_endpoint_core() {
  local endpoint_id="$1" reason="$2" worker_override="${3:-}"
  local start_ts endpoint_json worker generation session_name remote_outcome duration_ms

  start_ts="$(rw_now_epoch)"
  endpoint_json="$(rw_read_endpoint "$endpoint_id" 2>/dev/null || true)"
  worker="$worker_override"
  generation=0
  if [ -n "$endpoint_json" ]; then
    worker="$(printf '%s' "$endpoint_json" | jq -r '.worker // empty')"
    [ -n "$worker" ] || worker="$worker_override"
    generation="$(printf '%s' "$endpoint_json" | jq -r '.generation // 0')"
  fi
  session_name="$(rw_session_name "$endpoint_id")"

  rw_write_tombstone "$endpoint_id" "$generation" "$reason"
  rm -f "$(rw_endpoint_file "$endpoint_id")"

  remote_outcome="skipped"
  if [ -n "$worker" ]; then
    if rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "tmux kill-session -t '$session_name'" >/dev/null 2>&1; then
      remote_outcome="killed"
    else
      remote_outcome="unreachable_or_absent"
    fi
  fi

  duration_ms="$(rw_elapsed_ms "$start_ts")"
  rw_log_event "close" "$endpoint_id" "$worker" "$duration_ms" "success" "remote=$remote_outcome reason=$reason"
  return 0
}

# rw_create_remote_session <worker> <session_name> <remote_path> <timeout>
# Create the durable endpoint session on <worker> with the recommended
# endpoint session config (initial-plan.md, "Remote-side tmux durability").
# Shared by rw-ensure.sh (first establishment) and attach-loop.sh (case d:
# rebuilding a session lost to worker infrastructure loss, "as if being
# established again"). Exit status is the ssh command's own exit status.
rw_create_remote_session() {
  local worker="$1" session_name="$2" remote_path="$3" timeout="$4"
  rw_ssh_batch "$worker" "$timeout" "
    tmux new-session -d -s '$session_name' -c '$remote_path' &&
    tmux set-option -t '$session_name' prefix None &&
    tmux set-option -t '$session_name' prefix2 None &&
    tmux set-option -t '$session_name' mouse off &&
    tmux set-option -t '$session_name' escape-time 10 &&
    tmux set-option -t '$session_name' status off &&
    tmux set-option -t '$session_name' set-titles on &&
    tmux set-option -t '$session_name' set-titles-string '#{pane_current_path}'
  "
}

# ---------------------------------------------------------------------------
# config.json accessors
# ---------------------------------------------------------------------------

rw_config_valid() { jq -e . "$RW_CONFIG_FILE" >/dev/null 2>&1; }

rw_config_query() {
  local filter="$1" default="${2:-}"
  local result
  result="$(jq -er "$filter" "$RW_CONFIG_FILE" 2>/dev/null)" || result="$default"
  printf '%s\n' "$result"
}

rw_worker_config() {
  local alias="$1"
  jq -c --arg alias "$alias" '.workers[]? | select(.alias == $alias)' "$RW_CONFIG_FILE" 2>/dev/null
}

rw_worker_known() {
  local alias="$1" found
  found="$(rw_worker_config "$alias")"
  [ -n "$found" ]
}

rw_workspace_root() {
  local raw
  # shellcheck disable=SC2088  # literal "~" is intentional; substituted for
  # the relevant host's $HOME by callers (e.g. resolve-workspace.sh), never
  # meant to expand here.
  raw="$(rw_config_query '.workspace_root' '~/rw-workspaces/<focus-machine-id>')"
  raw="${raw/<focus-machine-id>/$(rw_machine_id)}"
  printf '%s\n' "$raw"
}

# ---------------------------------------------------------------------------
# SSH transport (overridable for tests: RW_SSH_BIN points at a fake ssh)
# ---------------------------------------------------------------------------

rw_ssh_bin() { printf '%s\n' "${RW_SSH_BIN:-ssh}"; }

rw_ssh_connect_timeout() { rw_config_query '.ssh.connect_timeout_seconds' 8; }
rw_ssh_preflight_timeout() { rw_config_query '.ssh.preflight_timeout_seconds' 10; }
rw_ssh_status_timeout() { rw_config_query '.ssh.status_timeout_seconds' 3; }

# Run a remote command non-interactively with a bounded timeout. Never used
# for anything that installs or mutates worker state beyond this plugin's own
# managed endpoint session/workspace.
rw_ssh_batch() {
  local worker="$1" timeout="$2"
  shift 2
  "$(rw_ssh_bin)" -o BatchMode=yes -o ConnectTimeout="$timeout" "$worker" "$@"
}

# ---------------------------------------------------------------------------
# Provider-process start verification (initial-plan.md, "Local-first AI
# coding-agent handoff" step 4: never stop one side's agent until the OTHER
# side's resume has verifiably started). Local and remote variants share the
# same per-provider match patterns as libexec/adapters/common-adapter.sh's
# ca_patterns_* -- kept in sync deliberately rather than sourced, mirroring
# that file's own documented convention of not cross-sourcing scripts/ and
# libexec/adapters/.
# ---------------------------------------------------------------------------

rw_provider_pattern() {
  case "$1" in
    claude) printf '%s\n' '(^|/)claude([[:space:]]|$)' ;;
    codex) printf '%s\n' '(^|/)codex([[:space:]]|$)|codex\.js|codex-darwin|codex-linux' ;;
    pi) printf '%s\n' '(^|/)pi([[:space:]]|$)|pi-coding-agent' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# rw_ps_tree_matches <pattern> <root-pid>... ; stdin: `ps axo pid=,ppid=,command=`
#
# True when any process at-or-under one of the root PIDs matches the ERE.
# Scoped replacement for the old host-global `pgrep -f` fallback in the two
# wait functions below: that fallback could "verify" a provider start off
# any unrelated same-named process on the host (smoke lane w5 counted ~60
# candidates on a busy focus machine) and let a handoff/return proceed to
# stop the only real copy of the agent.
rw_ps_tree_matches() {
  local pattern="$1"
  shift
  awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) rootset[r[i]] = 1 }
    {
      pid = $1; ppid = $2
      line = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]*/, "", line)
      cmd[pid] = line; parent[pid] = ppid
    }
    END {
      for (p in cmd) {
        q = p
        while (q && !(q in rootset) && (q in parent) && parent[q] != q) q = parent[q]
        if (q in rootset) print cmd[p]
      }
    }
  ' | grep -Eiq "$pattern"
}

# rw_wait_remote_provider_started <worker> <session_name> <provider> [tries]
# Polls a few short retries for the provider process to show up in the
# remote endpoint session: first via tmux's own #{pane_current_command}
# (one ssh round trip), then a `pgrep -f` fallback on the worker (an
# npm-launched CLI such as codex/pi commonly surfaces as "node" in
# pane_current_command and loses its distinguishing name). Returns 1 if the
# provider never shows up within the polling budget.
rw_wait_remote_provider_started() {
  local worker="$1" session_name="$2" provider="$3" tries="${4:-7}"
  local pattern i pane_cmd remote_pane_pids stable=0
  pattern="$(rw_provider_pattern "$provider")"
  i=0
  while [ "$i" -lt "$tries" ]; do
    pane_cmd="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "tmux list-panes -t '$session_name' -F '#{pane_current_command}' 2>/dev/null" 2>/dev/null || true)"
    if printf '%s\n' "$pane_cmd" | grep -Eiq "$pattern"; then
      # Require the match to HOLD on a second probe: a provider that
      # starts and immediately crashes (bad resume args, missing
      # transcript) matched once and was recorded as resumed -- letting
      # the other side's only live agent be stopped (smoke lane w5r).
      stable=$((stable + 1))
      if [ "$stable" -ge 2 ]; then
        return 0
      fi
      sleep 1
      continue
    fi
    # Scoped fallback: only processes under the endpoint session's own
    # pane PIDs count (see rw_ps_tree_matches for why host-global pgrep
    # was a correctness bug, not a convenience).
    remote_pane_pids="$(rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "tmux list-panes -t '$session_name' -F '#{pane_pid}' 2>/dev/null" 2>/dev/null | tr '\n' ' ')"
    if [ -n "${remote_pane_pids// /}" ] &&
      rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" "ps axo pid=,ppid=,command=" 2>/dev/null |
      rw_ps_tree_matches "$pattern" $remote_pane_pids; then
      stable=$((stable + 1))
      if [ "$stable" -ge 2 ]; then
        return 0
      fi
      sleep 1
      continue
    fi
    stable=0
    i=$((i + 1))
    [ "$i" -lt "$tries" ] && sleep 0.5
  done
  return 1
}

# rw_wait_local_provider_started <pane_id> <provider> [tries]
# Local mirror of the above, used by rw-return.sh to verify a local resume
# actually started before stopping the remote agent.
rw_wait_local_provider_started() {
  local pane_id="$1" provider="$2" tries="${3:-7}"
  local pattern i pane_cmd pane_pid stable=0
  pattern="$(rw_provider_pattern "$provider")"
  i=0
  while [ "$i" -lt "$tries" ]; do
    pane_cmd="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
    if printf '%s\n' "$pane_cmd" | grep -Eiq "$pattern"; then
      # Same stability requirement as the remote variant: one transient
      # match (start-then-crash) must not verify a resume.
      stable=$((stable + 1))
      if [ "$stable" -ge 2 ]; then
        return 0
      fi
      sleep 1
      continue
    fi
    # Scoped fallback: only processes under this pane's own PID count (see
    # rw_ps_tree_matches for why host-global pgrep was a correctness bug).
    pane_pid="$(tmux display-message -pt "$pane_id" -F '#{pane_pid}' 2>/dev/null || true)"
    if [ -n "$pane_pid" ] &&
      ps axo pid=,ppid=,command= | rw_ps_tree_matches "$pattern" "$pane_pid"; then
      stable=$((stable + 1))
      if [ "$stable" -ge 2 ]; then
        return 0
      fi
      sleep 1
      continue
    fi
    stable=0
    i=$((i + 1))
    [ "$i" -lt "$tries" ] && sleep 0.5
  done
  return 1
}

# ---------------------------------------------------------------------------
# Git remote identity normalization
# ---------------------------------------------------------------------------

# git@github.com:owner/repo.git      -> github.com/owner/repo
# https://github.com/owner/repo.git  -> github.com/owner/repo
# ssh://git@host:2222/owner/repo.git -> host/owner/repo
rw_normalize_git_remote() {
  local url="$1" rest
  rest="$url"
  rest="${rest#ssh://}"
  rest="${rest#git://}"
  rest="${rest#https://}"
  rest="${rest#http://}"
  rest="${rest#*@}"          # strip user@ if present
  rest="${rest/://}"         # scp-like host:path -> host/path
  rest="${rest%.git}"
  rest="$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$rest"
}

# Normalized identity for the git repo containing $1 (empty if not a repo or
# no `origin` remote configured).
rw_git_remote_identity() {
  local path="$1" url
  url="$(git -C "$path" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$url" ] || return 0
  rw_normalize_git_remote "$url"
}

rw_git_toplevel() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}
