#!/usr/bin/env bash
# Resolve where an endpoint's remote directory should be, per docs/tmux-remote-workspaces.md
# "Workspace placement". Pure resolution logic -- no ssh, no filesystem
# mutation -- so it is testable without a reachable worker. The caller
# supplies the worker's $HOME (from preflight.sh) rather than this script
# ssh-ing for it, keeping this script a pure function of its inputs plus the
# local registry/config.
#
# Usage:
#   resolve-workspace.sh --cwd <path> --worker <alias> --worker-home <path> \
#     [--workspace auto|<path>]
#
# Prints JSON: {mode, identity, focus_path, remote_path, needs_clone, clone_url}
#   mode: adhoc | plain
#   needs_clone: true when an adhoc checkout must still be created by the
#                caller (via the worker's own git/ssh auth) before use.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

cwd=""
worker=""
worker_home=""
workspace_arg="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="${2:?}"; shift 2 ;;
    --worker) worker="${2:?}"; shift 2 ;;
    --worker-home) worker_home="${2:?}"; shift 2 ;;
    --workspace) workspace_arg="${2:?}"; shift 2 ;;
    *) rw_die "resolve-workspace: unknown argument: $1" 64 ;;
  esac
done

[ -n "$cwd" ] || rw_die "resolve-workspace: --cwd is required" 64
[ -n "$worker" ] || rw_die "resolve-workspace: --worker is required" 64
[ -n "$worker_home" ] || rw_die "resolve-workspace: --worker-home is required" 64

emit() {
  local mode="$1" identity="$2" focus_path="$3" remote_path="$4" needs_clone="$5" clone_url="$6"
  jq -nc \
    --arg mode "$mode" \
    --arg identity "$identity" \
    --arg focus_path "$focus_path" \
    --arg remote_path "$remote_path" \
    --argjson needs_clone "$needs_clone" \
    --arg clone_url "$clone_url" \
    '{mode: $mode, identity: $identity, focus_path: $focus_path, remote_path: $remote_path, needs_clone: $needs_clone, clone_url: $clone_url}'
}

# Explicit non-auto workspace: used verbatim as the remote path (with ~
# substituted for the worker's home). No automatic placement runs.
if [ "$workspace_arg" != "auto" ]; then
  remote_path="$workspace_arg"
  # shellcheck disable=SC2088  # literal "~" pattern match, not expansion
  case "$remote_path" in
    '~' | '~/'*) remote_path="${worker_home}${remote_path#\~}" ;;
  esac
  emit "plain" "" "$cwd" "$remote_path" false ""
  exit 0
fi

identity="$(rw_git_remote_identity "$cwd")"

if [ -z "$identity" ]; then
  # A git worktree WITHOUT an origin remote must not fall through to the
  # plain-$HOME mapping: a handoff would then apply the repo's contents
  # directly into the worker's real home directory (happened in three
  # separate smoke lanes before this guard). Plain mode remains for
  # genuinely non-repo directories.
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "rw: '$cwd' is a git worktree with no 'origin' remote -- auto workspace placement would land in the worker's home directory. Pass --workspace <path> explicitly." >&2
    exit 1
  fi
  # Not a repo: plain worker $HOME.
  emit "plain" "" "$cwd" "$worker_home" false ""
  exit 0
fi

# Canonicalize to the physical worktree root. Different worktrees for the same
# repository must remain different remote workspaces, regardless of their
# branch names or directory naming conventions.
focus_path="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"

# --- Ad hoc workspace: reuse an existing endpoint for this worktree --------
endpoints_dir="$(rw_endpoints_dir)"
if [ -d "$endpoints_dir" ]; then
  existing_path="$(
    for f in "$endpoints_dir"/*.json; do
      [ -f "$f" ] || continue
      jq -r --arg identity "$identity" --arg worker "$worker" --arg focus_path "$focus_path" \
        'select(.workspace.mode == "adhoc" and .workspace.identity == $identity and .workspace.focus_path == $focus_path and .worker == $worker) | .workspace.remote_path' \
        "$f" 2>/dev/null
    done | head -n1
  )"
  if [ -n "$existing_path" ]; then
    emit "adhoc" "$identity" "$focus_path" "$existing_path" false ""
    exit 0
  fi
fi

# --- Ad hoc workspace: stable checkout for this physical worktree ----------
root="$(rw_workspace_root)"
root="${root/#\~/$worker_home}"
repo_slug="$(printf '%s' "$identity" | tr '/:' '--')"
worktree_name="$(printf '%s' "$(basename "$focus_path")" | tr -c '[:alnum:]._-' '-')"
worktree_fingerprint="$(printf '%s' "$focus_path" | cksum | awk '{print $1}')"
remote_path="${root}/${repo_slug}/${worktree_name}-${worktree_fingerprint}"

clone_url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
emit "adhoc" "$identity" "$focus_path" "$remote_path" true "$clone_url"
