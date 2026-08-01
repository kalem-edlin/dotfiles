#!/usr/bin/env bash
# Shared helpers for the Phase 5 provider agent adapters
# (libexec/adapters/{pi,claude,codex}). Sourced by each adapter; never
# executed directly.
#
# Deliberately self-contained -- adapters are called blind by rw-handoff.sh
# (owned elsewhere) and must not assume any tmux-remote-workspaces runtime
# state beyond this file. Conventions (state dirs, ssh transport, uuid/id
# helpers) intentionally mirror ../../scripts/common.sh and
# worktrees/.local/lib/worktrees/common.sh without sourcing either.
#
# Written bash-3.2-compatible (macOS system /bin/bash) as well as modern bash
# on Linux workers -- no associative arrays, no `mapfile`.

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

CA_PROG="$(basename "${0:-adapter}")"

ca_warn() { printf '%s: %s\n' "$CA_PROG" "$1" >&2; }
ca_die() {
  ca_warn "$1"
  exit "${2:-1}"
}

ca_need_jq() {
  command -v jq >/dev/null 2>&1 ||
    ca_die "jq is required but not installed (adapters never install anything themselves; brew install jq / apt install jq)." 1
}

ca_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ---------------------------------------------------------------------------
# SSH transport. Overridable for tests: CA_SSH_BIN (falls back to
# RW_SSH_BIN for parity with tmux-remote-workspaces' own test seam) points at
# a fake ssh executable.
# ---------------------------------------------------------------------------

ca_ssh_bin() { printf '%s\n' "${CA_SSH_BIN:-${RW_SSH_BIN:-ssh}}"; }
ca_ssh_connect_timeout() { printf '%s\n' "${CA_SSH_CONNECT_TIMEOUT:-8}"; }

# ca_ssh_run <worker> <remote command string>
# Non-interactive, batch-mode, bounded-timeout remote exec. Never used to
# install or mutate anything beyond an adapter's own managed transcript
# files (consume, never provision).
ca_ssh_run() {
  local worker="$1"
  shift
  "$(ca_ssh_bin)" -o BatchMode=yes -o ConnectTimeout="$(ca_ssh_connect_timeout)" "$worker" "$@"
}

# ---------------------------------------------------------------------------
# tmux-workspace-resurrect pane-agent-state: READ-ONLY consumer. That plugin
# (via scripts/record-agent-session.sh, wired through each provider's
# SessionStart hook/extension) owns the write path; adapters only read the
# per-pane JSON it deposits at session start. This is the "existing provider
# hooks/state" the plan asks detect to reuse rather than reinventing.
# ---------------------------------------------------------------------------

ca_workspace_state_dir() {
  printf '%s\n' "${TMUX_WORKSPACE_RESURRECT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-workspace-resurrect}"
}

ca_pane_agent_state_file() {
  local pane_id="${1#%}"
  printf '%s/agents/pane-%s.json\n' "$(ca_workspace_state_dir)" "$pane_id"
}

# Prints the recorded state JSON for a pane iff it exists and its "tool"
# field matches the given provider. Empty output (and failure) otherwise.
ca_read_pane_agent_state() {
  local pane_id="$1" provider="$2" file
  file="$(ca_pane_agent_state_file "$pane_id")"
  [ -f "$file" ] || return 1
  local json tool
  json="$(cat "$file" 2>/dev/null)" || return 1
  jq -e . >/dev/null 2>&1 <<<"$json" || return 1
  tool="$(jq -r '.tool // empty' <<<"$json" 2>/dev/null)"
  [ "$tool" = "$provider" ] || return 1
  printf '%s\n' "$json"
}

# ---------------------------------------------------------------------------
# Process-tree detection. Mirrors the case-based command matching used by
# tmux-workspace-resurrect's workspace_infer_agent() (see
# tmux/local-plugins/tmux-workspace-resurrect/scripts/common.sh), but walks
# the pane's actual descendant process tree instead of relying solely on
# tmux's own #{pane_current_command}, because npm-launched CLIs (codex, pi)
# commonly surface as "node" there and lose the distinguishing name.
# ---------------------------------------------------------------------------

ca_pane_pid() {
  local pane_id="$1"
  tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null || true
}

# All descendant pids of a root pid (root included), one per line. Bounded
# by both depth AND total visited-node count so a pathological process tree
# (e.g. a pane whose "root" turns out to be something process-heavy) can't
# hang detection -- each level does one `pgrep -P` per frontier pid, which
# is O(width) forks, so width also needs a hard ceiling.
ca_descendant_pids() {
  local root="$1" depth=0 next child
  local frontier="$root" all="$root"
  local visited=1 max_visited=300
  while [ -n "$frontier" ] && [ "$depth" -lt 12 ] && [ "$visited" -lt "$max_visited" ]; do
    next=""
    for p in $frontier; do
      child="$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"
      [ -n "$child" ] && next="$next $child"
    done
    next="$(printf '%s\n' "$next" | tr -s ' \n' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
    [ -n "$(printf '%s' "$next" | tr -d '[:space:]')" ] || break
    all="$all $next"
    frontier="$next"
    visited=$((visited + $(printf '%s\n' "$next" | wc -w)))
    depth=$((depth + 1))
  done
  printf '%s\n' "$all"
}

# ca_pane_has_process <pane_id> <extended-regex-pattern>...
# True (exit 0) if any descendant of the pane's root process has a `comm` or
# full command line matching one of the given patterns.
ca_pane_has_process() {
  local pane_id="$1"
  shift
  local root_pid
  root_pid="$(ca_pane_pid "$pane_id")"
  [ -n "$root_pid" ] || return 1

  local pids pid line pat
  pids="$(ca_descendant_pids "$root_pid")"
  for pid in $pids; do
    line="$(ps -o comm=,args= -p "$pid" 2>/dev/null)"
    [ -n "$line" ] || continue
    for pat in "$@"; do
      if printf '%s\n' "$line" | grep -Eiq "$pat"; then
        return 0
      fi
    done
  done
  return 1
}

# Per-provider process-match patterns (extended regex, case-insensitive).
# Bounded on both sides so short names ("pi") don't match unrelated
# commands ("pip", "print", ...).
ca_patterns_claude() { printf '%s\n' '(^|/)claude([[:space:]]|$)'; }
ca_patterns_codex() { printf '%s\n' '(^|/)codex([[:space:]]|$)' 'codex\.js' 'codex-darwin' 'codex-linux'; }
ca_patterns_pi() { printf '%s\n' '(^|/)pi([[:space:]]|$)' 'pi-coding-agent'; }

# ---------------------------------------------------------------------------
# Version comparison. `sort -V` is available on both modern macOS (Apple's
# BSD sort ships -V) and GNU coreutils on Linux workers.
# ---------------------------------------------------------------------------

# Prints -1, 0, or 1 for a<b, a==b, a>b.
ca_version_cmp() {
  local a="$1" b="$2" max
  if [ "$a" = "$b" ]; then
    printf '0\n'
    return
  fi
  max="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  if [ "$max" = "$a" ]; then printf '1\n'; else printf -- '-1\n'; fi
}

# ---------------------------------------------------------------------------
# Snapshot manifest helpers (export/install staging directories)
# ---------------------------------------------------------------------------

ca_write_manifest() {
  local dir="$1" json="$2"
  mkdir -p "$dir"
  printf '%s' "$json" >"$dir/manifest.json"
}

ca_manifest_field() {
  local dir="$1" field="$2"
  [ -f "$dir/manifest.json" ] || return 1
  jq -r --arg f "$field" '.[$f] // empty' "$dir/manifest.json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Common arg-parsing scaffold: adapters call this in a while-loop; unknown
# flags are the caller's problem (usage error).
# ---------------------------------------------------------------------------

ca_require() {
  local value="$1" flag="$2"
  [ -n "$value" ] || ca_die "missing required argument: $flag" 1
}
