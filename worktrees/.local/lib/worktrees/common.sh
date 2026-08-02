#!/usr/bin/env bash
# Shared helpers for the worktrees package (worktree-slot, worktree-claim).
# Sourced by both executables; never executed directly.
#
# This package is the personal, dotfiles-owned worktree slot + claim system
# described in docs/worktree-slots.md and
# docs/tasks/tmux-remote-workspaces/initial-plan.md. It is installed globally
# by the `worktrees` stow package; opted-in repositories are consumers, never
# owners, of this logic.
#
# Identity conventions (machine id, uuid generation, git remote
# normalization) intentionally mirror
# tmux/local-plugins/tmux-remote-workspaces/scripts/common.sh so both systems
# agree on the same focus-machine identity and the same normalized repo
# identity. They read/write the *same* machine-id file.

# Written to be bash 3.2 compatible (macOS system /bin/bash) as well as
# modern bash on Linux workers -- no associative arrays, no `mapfile`.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

wt_config_home() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
wt_state_home() { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

wt_config_file() {
  printf '%s\n' "${WORKTREES_CONFIG:-$(wt_config_home)/worktrees/config.json}"
}

# Shared with tmux-remote-workspaces: one focus-machine identity for both.
wt_machine_state_dir() {
  printf '%s\n' "${TMUX_REMOTE_WORKSPACES_STATE_DIR:-$(wt_state_home)/tmux-remote-workspaces}"
}
wt_machine_id_file() { printf '%s/machine-id\n' "$(wt_machine_state_dir)"; }

wt_claims_state_dir() {
  printf '%s\n' "${WORKTREES_CLAIMS_STATE_DIR:-$(wt_state_home)/worktrees/claims}"
}

wt_ensure_private_dir() {
  local dir="$1"
  mkdir -p "$dir"
  chmod 0700 "$dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

WT_PROG="$(basename "${0:-worktrees}")"

wt_warn() { printf '%s: %s\n' "$WT_PROG" "$1" >&2; }
wt_die() {
  wt_warn "$1"
  exit "${2:-20}"
}

wt_need_jq() {
  command -v jq >/dev/null 2>&1 || wt_die "jq is required but not installed (this package never installs anything itself; brew install jq / apt install jq)." 20
}

# ---------------------------------------------------------------------------
# Identity: machine id, uuids
# ---------------------------------------------------------------------------

wt_new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
  else
    jq -nr '[range(32)] | map("0123456789abcdef"[now*1000000+.|floor % 16:][:1]) | join("")'
  fi
}

# Lazily create the single-line focus-machine identity UUID. Identical logic
# to tmux-remote-workspaces' rw_machine_id() and the same file, so both
# systems agree on "this machine".
wt_machine_id() {
  local file
  file="$(wt_machine_id_file)"
  if [ ! -s "$file" ]; then
    wt_ensure_private_dir "$(dirname "$file")"
    local tmp
    tmp="$(mktemp "$(dirname "$file")/.machine-id.XXXXXX")"
    wt_new_uuid >"$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
  fi
  cat "$file"
}

wt_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

wt_hostname() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

# Stable tmux session UUID for the *current* caller (not an arbitrary
# session). Empty if outside tmux or the session predates the
# session-created hook backfill. Callers that mutate claim state must treat
# an empty result as "no stable session identity" and degrade explicitly
# (never fabricate one) -- see wt_require_session_identity below.
wt_session_uuid() {
  [ -n "${TMUX:-}" ] || return 0
  tmux display-message -p '#{@session-uuid}' 2>/dev/null || true
}

wt_session_name() {
  [ -n "${TMUX:-}" ] || return 0
  tmux display-message -p '#S' 2>/dev/null || true
}

# Exits with a clear, specific error (exit 12) when claim-mutating or
# verify-writer operations need a caller responsibility but none is
# available. Never invented -- this is the explicit degrade path required by
# the plan.
wt_require_session_identity() {
  local uuid
  uuid="$(wt_session_uuid)"
  if [ -z "$uuid" ]; then
    if [ -z "${TMUX:-}" ]; then
      wt_die "no stable session identity: not running inside tmux." 12
    else
      wt_die "no stable session identity: tmux session option @session-uuid is unset (session predates tmux-remote-workspaces' session-created hook; reattach or reload the plugin)." 12
    fi
  fi
  printf '%s\n' "$uuid"
}

# ---------------------------------------------------------------------------
# Git remote identity normalization (must match
# tmux-remote-workspaces/scripts/common.sh::rw_normalize_git_remote exactly)
# ---------------------------------------------------------------------------

# git@github.com:owner/repo.git      -> github.com/owner/repo
# https://github.com/owner/repo.git  -> github.com/owner/repo
# ssh://git@host:2222/owner/repo.git -> host/owner/repo
wt_normalize_git_remote() {
  local url="$1" rest
  rest="$url"
  rest="${rest#ssh://}"
  rest="${rest#git://}"
  rest="${rest#https://}"
  rest="${rest#http://}"
  rest="${rest#*@}"    # strip user@ if present
  rest="${rest/://}"   # scp-like host:path -> host/path
  rest="${rest%.git}"
  rest="$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$rest"
}

# Normalized identity for the git repo containing $1 (empty if not a repo or
# no `origin` remote configured).
wt_git_remote_identity() {
  # Deliberately not named "path" -- zsh binds a special $path array to
  # $PATH, and this file is occasionally sourced interactively for
  # debugging; a local var named "path" would shadow PATH resolution for
  # the rest of the function in that shell (bash itself is unaffected).
  local repo_dir="$1" url
  url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$url" ] || return 0
  wt_normalize_git_remote "$url"
}

wt_git_toplevel() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

# True (exit 0) iff the worktree at $1 has uncommitted changes to TRACKED
# files. Shared by worktree-claim's claim-time checkout guard and
# release-time dirty-tree guard.
#
# --untracked-files=no is deliberate, not an oversight. git checkout only
# refuses when an untracked file would actually be overwritten, and reports
# which one; blocking on any untracked file at all is stricter than git
# itself for no safety gain. Measured against the live content-engine
# collection 2026-08-02: 5 of 15 slots (2, 3, 6, 7, 11) have zero tracked
# modifications but nonzero untracked entries, so an untracked-sensitive
# check would have refused claim/release on a third of the collection while
# git would have completed the checkout cleanly.
wt_worktree_dirty() {
  local worktree_path="$1" status
  status="$(git -C "$worktree_path" status --porcelain --untracked-files=no 2>/dev/null)"
  [ -n "$status" ]
}

# ---------------------------------------------------------------------------
# Atomic JSON writes
# ---------------------------------------------------------------------------

wt_write_json_atomic() {
  local file="$1" json="$2" dir tmp
  dir="$(dirname "$file")"
  wt_ensure_private_dir "$dir"
  tmp="$(mktemp "$dir/.$(basename "$file").XXXXXX")"
  printf '%s' "$json" >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}

# Writes a marker file into a *worktree* (not private state). 0644, visible,
# globally gitignored via git/.gitignore_global.
wt_write_marker_atomic() {
  local file="$1" json="$2" dir tmp
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/.$(basename "$file").XXXXXX")"
  printf '%s' "$json" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$file"
}

# Portable stable hash of a string -> lowercase hex (first 16 chars used for
# claim registry filenames). Tries sha256sum, then shasum, then cksum.
wt_hash() {
  local input="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$input" | cksum | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# config.json accessors
# ---------------------------------------------------------------------------

wt_config_valid() {
  local file
  file="$(wt_config_file)"
  [ -f "$file" ] || return 1
  jq -e . "$file" >/dev/null 2>&1
}

wt_config_require() {
  local file
  file="$(wt_config_file)"
  [ -f "$file" ] || wt_die "config not found: $file (expected the worktrees stow package to be installed)." 20
  jq -e . "$file" >/dev/null 2>&1 || wt_die "config is not valid JSON: $file" 20
}

# Repo config object (or empty string) for a normalized identity.
wt_repo_config() {
  local identity="$1"
  jq -c --arg id "$identity" '.repositories[$id] // empty' "$(wt_config_file)"
}

# shellcheck disable=SC2088 # the "~/"* case pattern below matches a literal
# "~/" prefix to strip; it is not asking the shell to tilde-expand it.
wt_expand_tilde() {
  local raw="$1" rest
  case "$raw" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      rest="${raw#\~/}"
      printf '%s\n' "$HOME/$rest"
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Claims registry: one JSON file per worktree path, keyed by a stable hash of
# the path. This is the authoritative registry on *this* host (hybrid model:
# see wt_sync_claim_from_marker for the marker/registry reconciliation rule).
# ---------------------------------------------------------------------------

wt_claim_registry_file() {
  local worktree_path="$1" key
  key="$(wt_hash "$worktree_path")"
  printf '%s/%s.json\n' "$(wt_claims_state_dir)" "${key:0:16}"
}

wt_marker_path() { printf '%s/.worktree-claim\n' "$1"; }

wt_read_claim_registry() {
  local worktree_path="$1" file
  file="$(wt_claim_registry_file "$worktree_path")"
  [ -f "$file" ] || return 1
  cat "$file"
}

wt_read_marker() {
  local worktree_path="$1" file
  file="$(wt_marker_path "$worktree_path")"
  [ -f "$file" ] || return 1
  cat "$file"
}

# True (exit 0) iff a .worktree-claim marker exists at $1 and is NOT valid
# JSON -- i.e. a pre-migration content-engine marker (either the
# key=value form, e.g. "holder=...\nbranch=...\ntmux_session=...\ndate=...",
# or the older colon form). wt_sync_claim_from_marker already silently
# no-ops on such a file (jq -e . fails, so it never gets adopted into the
# registry); this predicate lets callers surface that case explicitly
# instead of it reading as plain "unclaimed".
wt_marker_is_legacy() {
  local worktree_path="$1" file
  file="$(wt_marker_path "$worktree_path")"
  [ -f "$file" ] || return 1
  jq -e . "$file" >/dev/null 2>&1 && return 1
  return 0
}

wt_legacy_claim_label() { printf 'legacy claim marker (unmigrated -- see content-engine extraction PR)\n'; }

# Hybrid reconciliation: "an older-generation marker NEVER overwrites a newer
# registry entry." Read as an if-and-only-if: adopt the marker into this
# host's local registry only when the marker's generation is strictly newer
# than (or the registry has no entry at all). This is how claim state crosses
# hosts -- a handoff/return copies the worktree (including the marker); the
# first claim-aware operation on the new host adopts it.
wt_sync_claim_from_marker() {
  local worktree_path="$1"
  local marker_json reg_file reg_json marker_gen reg_gen
  marker_json="$(wt_read_marker "$worktree_path")" || return 0
  jq -e . >/dev/null 2>&1 <<<"$marker_json" || return 0
  reg_file="$(wt_claim_registry_file "$worktree_path")"
  marker_gen="$(jq -r '.handoff_generation // 0' <<<"$marker_json" 2>/dev/null)"
  case "$marker_gen" in '' | *[!0-9]*) marker_gen=0 ;; esac
  if [ -f "$reg_file" ]; then
    reg_json="$(cat "$reg_file")"
    reg_gen="$(jq -r '.handoff_generation // 0' <<<"$reg_json" 2>/dev/null)"
    case "$reg_gen" in '' | *[!0-9]*) reg_gen=0 ;; esac
  else
    reg_gen=-1
  fi
  if [ "$marker_gen" -gt "$reg_gen" ]; then
    wt_write_json_atomic "$reg_file" "$marker_json"
  fi
}

# Writes both the authoritative registry entry and the visible marker,
# keeping them byte-identical (the marker is a hybrid visibility copy of the
# same record, not a separate schema).
wt_write_claim() {
  local worktree_path="$1" claim_json="$2"
  wt_write_json_atomic "$(wt_claim_registry_file "$worktree_path")" "$claim_json"
  wt_write_marker_atomic "$(wt_marker_path "$worktree_path")" "$claim_json"
}

# Removes the visible marker (worktree reads as unclaimed) while keeping a
# tombstone (state=released) in the authoritative registry for generation
# continuity and audit.
wt_remove_marker() {
  local worktree_path="$1" file
  file="$(wt_marker_path "$worktree_path")"
  rm -f "$file"
}

# One-line human summary of a claim's state, for `worktree-slot ensure`'s
# summary line. Always succeeds; prints "unclaimed" if none, or the legacy
# label (never "unclaimed") if a pre-migration marker is present.
#
# $2 (dry_run, default 0): when 1, skips wt_sync_claim_from_marker's
# registry write entirely (worktree-slot ensure --dry-run must not change
# anything on disk -- see initial-plan.md's "--dry-run performs resolution,
# derivation, validation, and summary without creating or changing
# anything"). The summary may then reflect a not-yet-adopted newer marker
# generation; that staleness is the accepted cost of dry-run purity.
wt_claim_summary_for_path() {
  local worktree_path="$1" dry_run="${2:-0}" claim_json
  [ "$dry_run" -eq 1 ] || wt_sync_claim_from_marker "$worktree_path"
  claim_json="$(wt_read_claim_registry "$worktree_path")" || {
    if wt_marker_is_legacy "$worktree_path"; then
      wt_legacy_claim_label
      return 0
    fi
    printf 'unclaimed\n'
    return 0
  }
  local state
  state="$(jq -r '.state // "unknown"' <<<"$claim_json")"
  if [ "$state" = "released" ]; then
    if wt_marker_is_legacy "$worktree_path"; then
      wt_legacy_claim_label
      return 0
    fi
    printf 'unclaimed\n'
    return 0
  fi
  jq -r '"\(.state) by \(.session_name // "unknown-session") (\(.owning_user // "unknown")) -- writer: \(.active_writer_host // "unknown")"' <<<"$claim_json"
}

# ---------------------------------------------------------------------------
# Caller identity resolution (used by worktree-claim's mutating/verifying
# subcommands)
# ---------------------------------------------------------------------------

# caller_responsibility = focus-machine-id + stable tmux-session-id
# caller_execution_host  = current machine identity (short hostname)
wt_caller_focus_machine_id() { wt_machine_id; }
wt_caller_host() { wt_hostname; }
