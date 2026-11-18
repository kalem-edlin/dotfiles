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
# The state root on a WORKER, from preflight's queried `.home` (never this
# process's own $HOME/$XDG_STATE_HOME, which describe the focus machine).
# TMUX_REMOTE_WORKSPACES_STATE_DIR is deliberately NOT consulted here: it
# redirects the focus-side state dir only (contract C4). A same-host
# fake-ssh harness sets TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR as well, so
# both sides land in separate sandboxes; a real-worker smoke test sets only
# the focus-side override.
rw_state_dir_at() {
  local home="$1"
  printf '%s\n' "${TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR:-$home/.local/state/tmux-remote-workspaces}"
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

# POSIX single-quote escaping for embedding a value in a command string run
# by a remote (or local) shell.
rw_shquote() {
  local s="$1" q="'\\''"
  printf "'%s'" "${s//\'/$q}"
}

rw_die() {
  rw_warn "$1"
  exit "${2:-1}"
}

# rw_dialog <message> [pane-id] [title]
# Interactive warnings belong in a popup, never tmux's status/message row.
# The shared renderer falls back to stderr when no attached client exists,
# preserving useful diagnostics for headless hooks and direct CLI calls.
rw_dialog() {
  local message="$1" pane_id="${2:-${TMUX_PANE:-}}" title="${3:-Remote workspace}"
  local dialog="$RW_PLUGIN_DIR/../../scripts/dialog.sh"
  if [ -n "$pane_id" ]; then
    "$dialog" --pane "$pane_id" --title "$title" -- "$message" || true
  else
    "$dialog" --title "$title" -- "$message" || true
  fi
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
# docs/tmux-remote-workspaces.md, "Intentional close is different from a
# disconnect"):
#   1. Write the tombstone FIRST, so a crash mid-cleanup can never let an
#      older resurrect snapshot revive a deliberately closed endpoint.
#   2. Release/remove the registry entry.
#   3. Best-effort remote teardown (an unreachable/already-gone worker
#      session is expected/fine -- the tombstone is what makes this
#      reconcilable, not a successful kill).
# Never touches a local pane -- callers that own a bound pane (rw-close.sh)
# still clear their own @rw-* cache options and close the pane themselves
# afterward. Shared by rw-close.sh (pane-driven, interactive/keybinding
# path), libexec/reconcile (id-driven orphan disposal, no local pane),
# libexec/reconcile-worker (worker-scoped zombie sweep), and
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
  # The attach loop's per-endpoint "last seen on server" marker.
  rm -f "$(rw_state_dir)/attach-seen/$endpoint_id"

  remote_outcome="skipped"
  if [ -n "$worker" ]; then
    if rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
      "tmux kill-session -t '=$session_name'" >/dev/null 2>&1; then
      remote_outcome="killed"
    else
      remote_outcome="unreachable_or_absent"
    fi
  fi

  duration_ms="$(rw_elapsed_ms "$start_ts")"
  rw_log_event "close" "$endpoint_id" "$worker" "$duration_ms" "success" "remote=$remote_outcome reason=$reason"
  return 0
}

# rw_hidden_session_options_cmd <session_name>
# The tmux command string that turns <session_name> into a hidden endpoint
# session: no prefix (the laptop's prefix stays the only one), no status
# line, no mouse, and the session dies with its last client-visible window.
# Shared by rw_create_remote_session (sent over ssh) and
# rw_apply_hidden_session_options (run on the machine that hosts the
# session, e.g. the worker-side post-restore).
rw_hidden_session_options_cmd() {
  local t
  t="$(rw_shquote "${1:?session name required}")"
  printf '%s' "tmux set-option -t $t prefix None &&
    tmux set-option -t $t prefix2 None &&
    tmux set-option -t $t detach-on-destroy on &&
    tmux set-option -t $t mouse off &&
    tmux set-option -t $t escape-time 10 &&
    tmux set-option -t $t status off &&
    tmux set-option -t $t set-titles on &&
    tmux set-option -t $t set-titles-string '#{pane_current_path}'"
}

# rw_apply_hidden_session_options <session_name>
# Re-applies the hidden endpoint options to a session on THIS machine's tmux
# server (contract C6). tmux-resurrect does not save session options, so a
# restored rw-* session comes back with a live prefix and status line until
# this runs.
rw_apply_hidden_session_options() {
  bash -c "$(rw_hidden_session_options_cmd "${1:?session name required}")"
}

# rw_create_remote_session <worker> <session_name> <remote_path> <timeout>
# Create the durable endpoint session on <worker> with the hidden endpoint
# session options (docs/tmux-remote-workspaces.md, "Persistence and
# reconciliation").
# Shared by rw-open.sh, rw-handoff.sh, and attach-loop.sh (case d:
# rebuilding a session lost to worker infrastructure loss, "as if being
# established again"). Exit status is the ssh command's own exit status.
rw_create_remote_session() {
  local worker="$1" session_name="$2" remote_path="$3" timeout="$4"
  rw_ssh_batch "$worker" "$timeout" "
    tmux new-session -d -s $(rw_shquote "$session_name") -c $(rw_shquote "$remote_path") &&
    $(rw_hidden_session_options_cmd "$session_name")
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
# Provider-process start verification (docs/tmux-remote-workspaces.md,
# "Handoff and return": never stop one side's agent until the other
# side's resume has verifiably started). Local and remote variants share the
# same per-provider match patterns as libexec/adapters/common-adapter.sh's
# ca_patterns_* -- kept in sync deliberately rather than sourced, mirroring
# that file's own documented convention of not cross-sourcing scripts/ and
# libexec/adapters/.
# ---------------------------------------------------------------------------

rw_provider_pattern() {
  case "$1" in
    # Keep in sync with ca_patterns_claude: bare claude, the versioned
    # native install, and claudef's patched build in ~/.cache/claudef/bin.
    claude) printf '%s\n' '(^|/)claude([[:space:]]|$)|/claudef/bin/[^/[:space:]]+([[:space:]]|$)|/claude/versions/[^/[:space:]]+([[:space:]]|$)' ;;
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

# rw_ps_tree_match_pids <pattern> <root-pid>... ; stdin: `ps axo pid=,ppid=,command=`
#
# Same scoping as rw_ps_tree_matches, but prints the PIDs of the matching
# processes (one per line) instead of a boolean -- for callers that must
# signal exactly the provider's own processes and nothing else
# (rw-handoff.sh, stopping the local agent). The pattern is tested against the command line
# alone (never the pid column), so anchored patterns like '(^|/)claude'
# keep working.
rw_ps_tree_match_pids() {
  local pattern="$1" pid cmdline
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
        if (q in rootset) printf "%s\t%s\n", p, cmd[p]
      }
    }
  ' | while IFS=$'\t' read -r pid cmdline; do
    printf '%s\n' "$cmdline" | grep -Eiq "$pattern" && printf '%s\n' "$pid"
  done
  return 0
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
    # shellcheck disable=SC2086 # pane PID list intentionally expands into roots
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
# Local mirror of the above, used by rw-handback.sh to verify a local resume
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

# rw_git_remote_is_network <url>
# True for a remote reached over the network (ssh://, https://, git://,
# scp-like host:path); false for a local path or file:// URL, which has no
# host to authenticate against.
rw_git_remote_is_network() {
  case "$1" in
    file://*) return 1 ;;
    *://*) return 0 ;;
    /* | ./* | ../* | '~'* | '') return 1 ;;
  esac
  case "${1%%/*}" in *:*) return 0 ;; esac
  return 1
}

rw_git_toplevel() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Directory roots and ownership records (docs/tasks/mini-remote-sessions.md,
# contract C1). The unit of handoff is a directory root: the git toplevel of
# a worktree, or a plain folder. Paths travel relative to $HOME (`root_rel`)
# so the two machines never need the same user name.
#
#   owned/<root_id>/record.json         root_id, root_rel, root_local, kind,
#                                       worker, worker_root, owner, since,
#                                       endpoints[], pending?, stale_worker?,
#                                       focus_machine_id
#   owned/<root_id>/manifest.focus.tsv  rsync-channel manifest of the focus copy
#   owned/<root_id>/manifest.worker.tsv rsync-channel manifest of the worker copy
#   held/<worker>/<root_id>.json        index of worker copies this focus
#                                       machine created (kept after hand-back,
#                                       so `rw forget` knows where copies live)
#
# A focus record exists only while a root is worker-owned or has a pending
# action. The worker keeps a mirror (same layout, root_local = the worker's
# own path) under its own state dir; it survives hand-back with owner=focus
# so the next handoff can check the worker copy against its manifest.
# ---------------------------------------------------------------------------

rw_owned_dir() { printf '%s/owned\n' "$(rw_state_dir)"; }
rw_owned_record_dir() { printf '%s/%s\n' "$(rw_owned_dir)" "${1:?root id required}"; }
rw_owned_record_file() { printf '%s/record.json\n' "$(rw_owned_record_dir "$1")"; }
rw_held_dir() { printf '%s/held\n' "$(rw_state_dir)"; }
rw_held_file() { printf '%s/%s/%s.json\n' "$(rw_held_dir)" "${1:?worker required}" "${2:?root id required}"; }

# rw_physical_path <path>
# Physical absolute path of an existing directory (symlinks resolved, the
# form tmux reports as pane_current_path); a non-directory is printed as
# given, minus any trailing slash.
rw_physical_path() {
  local p="${1:?path required}"
  if [ -d "$p" ]; then
    (cd -P "$p" 2>/dev/null && pwd -P) && return 0
  fi
  [ "$p" = "/" ] || p="${p%/}"
  printf '%s\n' "$p"
}

# rw_root_rel <abs-path> [home]
# Prints <abs-path> relative to <home> (default: this machine's $HOME).
# Exit 7 when the path is $HOME itself or lies outside it -- such roots are
# refused (contract C1). Never prints a leading "/" or "~".
rw_root_rel() {
  local path home rel
  path="$(rw_physical_path "${1:?path required}")"
  home="$(rw_physical_path "${2:-$HOME}")"
  case "$path" in
    "$home"/?*) rel="${path#"$home"/}" ;;
    *) return 7 ;;
  esac
  case "/$rel/" in
    */../* | */./*) return 7 ;;
  esac
  printf '%s\n' "$rel"
}

# rw_root_id <root_rel> -- first cksum field; identical on every machine.
rw_root_id() {
  printf '%s' "${1:?root_rel required}" | cksum | awk '{print $1}'
}

# rw_root_kind <abs-path> -- "git" when the path is a git worktree's
# toplevel, "inside-git" when it is a subdirectory of one, else "plain".
rw_root_kind() {
  local path="$1" top
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$top" ]; then
    printf 'plain\n'
  elif [ "$(rw_physical_path "$top")" = "$(rw_physical_path "$path")" ]; then
    printf 'git\n'
  else
    printf 'inside-git\n'
  fi
}

# rw_default_root_for_path <abs-path>
# The root a pane at <abs-path> belongs to when no --root is given: the
# worker-owned root enclosing it if there is one, else its git toplevel,
# else the directory itself.
rw_default_root_for_path() {
  local path id top
  path="$(rw_physical_path "${1:?path required}")"
  if id="$(rw_owned_root_for_path "$path")"; then
    jq -r '.root_local' "$(rw_owned_record_file "$id")"
    return 0
  fi
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ]; then
    rw_physical_path "$top"
  else
    printf '%s\n' "$path"
  fi
}

rw_owned_record_read() {
  local file
  file="$(rw_owned_record_file "${1:?root id required}")"
  [ -f "$file" ] || return 1
  cat "$file"
}

rw_owned_record_write() {
  local root_id="${1:?root id required}" json="${2:?json required}"
  rw_ensure_private_dir "$(rw_owned_dir)"
  rw_write_json_atomic "$(rw_owned_record_file "$root_id")" "$json"
}

# rw_owned_record_remove <root_id> -- deletes the whole record directory.
rw_owned_record_remove() {
  local dir
  dir="$(rw_owned_record_dir "${1:?root id required}")"
  [ -d "$dir" ] || return 0
  rm -f "$dir"/record.json "$dir"/manifest.focus.tsv "$dir"/manifest.worker.tsv
  rm -f "$dir"/.record.json.* 2>/dev/null
  rmdir "$dir" 2>/dev/null || true
}

# rw_owned_records_json -- every record as one JSON array (one jq process).
rw_owned_records_json() {
  local dir
  dir="$(rw_owned_dir)"
  if [ -d "$dir" ] && compgen -G "$dir/*/record.json" >/dev/null; then
    jq -s 'sort_by(.root_rel)' "$dir"/*/record.json 2>/dev/null || printf '[]\n'
  else
    printf '[]\n'
  fi
}

# rw_owned_root_for_path <abs-path>
# Prints the root_id of the worker-owned record whose root_local is <path>
# or an ancestor of it (longest match wins); exit 1 when there is none.
rw_owned_root_for_path() {
  local path id
  path="$(rw_physical_path "${1:?path required}")"
  id="$(rw_owned_records_json | jq -r --arg p "$path" '
    [ .[] | select(.owner == "worker")
      | select(.root_local as $r | $p == $r or ($p | startswith($r + "/"))) ]
    | sort_by(.root_local | length) | last | .root_id // empty' 2>/dev/null)"
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# rw_owned_overlap <abs-root>
# Prints the root_local of a worker-owned record that encloses <abs-root> or
# lies inside it (roots never nest across an ownership boundary); exit 1
# when there is none.
rw_owned_overlap() {
  local path hit
  path="$(rw_physical_path "${1:?path required}")"
  hit="$(rw_owned_records_json | jq -r --arg p "$path" '
    [ .[] | select(.owner == "worker") | .root_local
      | select(. as $r | $p == $r or ($p | startswith($r + "/")) or ($r | startswith($p + "/"))) ]
    | first // empty' 2>/dev/null)"
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# rw_record_new <root_id> <root_rel> <root_local> <kind> <worker> <worker_root>
# Prints a fresh record object (owner focus, no endpoints).
rw_record_new() {
  jq -nc \
    --arg root_id "$1" --arg root_rel "$2" --arg root_local "$3" --arg kind "$4" \
    --arg worker "$5" --arg worker_root "$6" --arg since "$(rw_now_iso)" \
    --arg focus_machine_id "$(rw_machine_id)" \
    '{root_id: $root_id, root_rel: $root_rel, root_local: $root_local, kind: $kind,
      worker: $worker, worker_root: $worker_root, owner: "focus", since: $since,
      endpoints: [], focus_machine_id: $focus_machine_id}'
}

# rw_record_add_endpoint <root_id> <endpoint_id> / rw_record_remove_endpoint
rw_record_add_endpoint() {
  local json
  json="$(rw_owned_record_read "$1")" || return 1
  json="$(printf '%s' "$json" | jq -c --arg e "$2" '.endpoints = ((.endpoints // []) + [$e] | unique)')"
  rw_owned_record_write "$1" "$json"
}

rw_record_remove_endpoint() {
  local json
  json="$(rw_owned_record_read "$1")" || return 0
  json="$(printf '%s' "$json" | jq -c --arg e "$2" '.endpoints = ((.endpoints // []) - [$e])')"
  rw_owned_record_write "$1" "$json"
}

# rw_held_mark <worker> <root_id> <root_rel> <worker_root>
rw_held_mark() {
  rw_write_json_atomic "$(rw_held_file "$1" "$2")" "$(jq -nc \
    --arg worker "$1" --arg root_id "$2" --arg root_rel "$3" --arg worker_root "$4" \
    --arg since "$(rw_now_iso)" \
    '{worker: $worker, root_id: $root_id, root_rel: $root_rel, worker_root: $worker_root, since: $since}')"
}

rw_held_unmark() { rm -f "$(rw_held_file "$1" "$2")"; }

# rw_held_workers <root_id> -- workers known to hold a copy of the root.
rw_held_workers() {
  local dir f
  dir="$(rw_held_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*/"$1".json; do
    [ -f "$f" ] || continue
    basename "$(dirname "$f")"
  done
}

# rw_worker_mirror_dir <worker_home> <root_id>
rw_worker_mirror_dir() {
  printf '%s/owned/%s\n' "$(rw_state_dir_at "${1:?worker home required}")" "${2:?root id required}"
}

# rw_worker_mirror_push <worker> <worker_home> <root_id> <local-dir>
# Writes record.json and manifest.*.tsv from <local-dir> into the worker's
# mirror record dir, over the ssh exec wrapper. Atomic per file (tar into a
# temp dir, then rename).
rw_worker_mirror_push() {
  local worker="$1" worker_home="$2" root_id="$3" src="$4" dest q
  dest="$(rw_worker_mirror_dir "$worker_home" "$root_id")"
  q="$(rw_shquote "$dest")"
  tar -C "$src" -cf - . 2>/dev/null | rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" "
    set -e
    mkdir -p $q
    chmod 0700 $q 2>/dev/null || true
    tmp=\$(mktemp -d $q/.incoming.XXXXXX)
    tar -xf - -C \"\$tmp\"
    for f in \"\$tmp\"/*; do [ -e \"\$f\" ] && mv -f \"\$f\" $q/; done
    rmdir \"\$tmp\"
  " >/dev/null 2>&1
}

# rw_worker_mirror_fetch <worker> <worker_home> <root_id> <file> <out>
# Copies one file from the worker's mirror dir to <out>; an absent file
# leaves <out> absent. Returns 6 when the worker cannot be reached.
rw_worker_mirror_fetch() {
  local worker="$1" worker_home="$2" root_id="$3" name="$4" out="$5" path status=0
  path="$(rw_worker_mirror_dir "$worker_home" "$root_id")/$name"
  rm -f "$out"
  rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" \
    "if [ -f $(rw_shquote "$path") ]; then printf 'present\n'; cat $(rw_shquote "$path"); else printf 'absent\n'; fi" \
    </dev/null >"$out.raw" 2>/dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    rm -f "$out.raw"
    return 6
  fi
  if [ "$(head -n1 "$out.raw")" = "present" ]; then
    tail -n +2 "$out.raw" >"$out"
  fi
  rm -f "$out.raw"
  return 0
}

# rw_preflight_exit <preflight-json>
# Maps a failed preflight to the rw exit code: 6 when the worker could not
# be reached at all, 1 when it was reached but is missing something.
rw_preflight_exit() {
  if [ "$(printf '%s' "$1" | jq -r '.ssh_reachable // false' 2>/dev/null)" = "true" ]; then
    printf '1\n'
  else
    printf '6\n'
  fi
}

# ---------------------------------------------------------------------------
# Per-root lock: handoff, handback, open, forget and reclaim of one root are
# mutually exclusive (two hand-backs of the same root, or a forget during a
# handoff, would otherwise interleave). A lock dir holds the owner's pid; a
# dead owner's lock is reclaimed. Locks this process already holds are
# re-entrant. Released by rw_root_unlock_all (callers trap EXIT, and call it
# explicitly before `exec`, which skips EXIT traps).
# ---------------------------------------------------------------------------

RW_ROOT_LOCKS_HELD=" "

rw_root_lock_dir() { printf '%s/locks/root-%s\n' "$(rw_state_dir)" "${1:?root id required}"; }

# rw_root_lock <root_id> -- 0 when held (now or already), 1 when another
# live process holds it.
rw_root_lock() {
  local id="$1" dir pid
  case "$RW_ROOT_LOCKS_HELD" in *" $id "*) return 0 ;; esac
  dir="$(rw_root_lock_dir "$id")"
  rw_ensure_private_dir "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
      sleep 0.3
      pid="$(cat "$dir/pid" 2>/dev/null || true)"
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    [ -n "$pid" ] || return 1 # being created right now; never steal it
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$dir/pid"
  RW_ROOT_LOCKS_HELD="$RW_ROOT_LOCKS_HELD$id "
  return 0
}

# rw_root_lock_or_die <root_id> <command-name>
rw_root_lock_or_die() {
  rw_root_lock "$1" ||
    rw_die "$2: another rw operation on this root is running (pid $(cat "$(rw_root_lock_dir "$1")/pid" 2>/dev/null)); retry when it finishes." 1
}

rw_root_unlock_all() {
  local id
  for id in $RW_ROOT_LOCKS_HELD; do
    rm -rf "$(rw_root_lock_dir "$id")"
  done
  RW_ROOT_LOCKS_HELD=" "
}

# rw_worker_request_save <worker>
# After rw killed sessions on a worker: when sessions remain there, ask the
# worker for a verified tmux save (its own save agent: launchd on macOS,
# systemd on Linux), so the snapshot a later restore reads no longer lists
# the closed sessions. When none remain the server has exited; the worker's
# post-restore drops any closed session a later restore would revive.
# Asynchronous and best effort. RW_WORKER_SAVE_TRIGGER replaces the remote
# command (tests point it at a log file, never at this machine's agents).
rw_worker_request_save() {
  local worker="${1:?worker required}" trigger
  trigger="${RW_WORKER_SAVE_TRIGGER:-launchctl kickstart gui/\$(id -u)/com.kalem.tmux-resurrect-save >/dev/null 2>&1 || systemctl --user start --no-block tmux-resurrect-save.service >/dev/null 2>&1}"
  rw_ssh_batch "$worker" "$(rw_ssh_status_timeout)" \
    "if tmux list-sessions >/dev/null 2>&1; then $trigger; fi; true" </dev/null >/dev/null 2>&1 || true
}

# rw_worker_copy_root_for_path <abs-path>
# On a WORKER: prints the root_id of the worker-owned ownership mirror that
# encloses <path> (a copy this machine holds for another, focus, machine);
# exit 1 otherwise -- including on the focus machine itself, whose own
# records carry its own machine id. Never creates the machine-id file.
rw_worker_copy_root_for_path() {
  local id own rec
  id="$(rw_owned_root_for_path "${1:?path required}")" || return 1
  own="$(cat "$(rw_machine_id_file)" 2>/dev/null || true)"
  rec="$(jq -r '.focus_machine_id // empty' "$(rw_owned_record_file "$id")" 2>/dev/null)"
  [ -n "$rec" ] && [ "$rec" != "$own" ] || return 1
  printf '%s\n' "$id"
}

# rw_bg_dir -- background transfer jobs (libexec/rw-bg): bg/<root_id>/ holds
# job.json and the runner's pid while a transfer of that root is in flight.
rw_bg_dir() { printf '%s/bg\n' "$(rw_state_dir)"; }
