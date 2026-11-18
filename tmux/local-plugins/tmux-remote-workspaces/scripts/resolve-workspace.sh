#!/usr/bin/env bash
# Resolve a directory root and its placement on a worker (contract C1,
# decision D9). Pure resolution: no ssh, no filesystem mutation, so it is
# testable without a reachable worker. The caller supplies the worker's
# physical $HOME (preflight.sh's `.home`).
#
# Every synced path is expressed relative to $HOME: a root at
# $HOME/<root_rel> on the focus machine lives at <worker-home>/<root_rel> on
# the worker. Roots outside $HOME, and $HOME itself, are refused (exit 7).
#
# Usage:
#   resolve-workspace.sh --cwd <path> --worker-home <path> [--root <path>]
#                        [--worker <alias>]
#
#   --cwd    the pane's current directory (focus side)
#   --root   explicit root; default: the worker-owned root enclosing --cwd,
#            else its git toplevel, else --cwd itself
#
# Prints JSON:
#   {root_id, root_rel, root_local, kind, worker_root, focus_path, remote_path}
#   kind:        git | plain
#   focus_path:  --cwd when it lies inside the root, else root_local
#   remote_path: focus_path mapped onto the worker
#
# Exit 7: root outside $HOME, $HOME itself, or a subdirectory of a git
# worktree (hand off the worktree instead). A cwd outside an explicit root
# is not an error: focus_path/remote_path then fall back to the root.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

cwd=""
worker_home=""
root_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="${2:?}"; shift 2 ;;
    --worker-home) worker_home="${2:?}"; shift 2 ;;
    --root) root_arg="${2:?}"; shift 2 ;;
    --worker) shift 2 ;; # accepted for symmetry; placement no longer depends on it
    *) rw_die "resolve-workspace: unknown argument: $1" 64 ;;
  esac
done

[ -n "$cwd" ] || [ -n "$root_arg" ] || rw_die "resolve-workspace: --cwd or --root is required" 64
[ -n "$worker_home" ] || rw_die "resolve-workspace: --worker-home is required" 64

if [ -n "$root_arg" ]; then
  root_local="$(rw_physical_path "$root_arg")"
else
  root_local="$(rw_default_root_for_path "$cwd")"
fi
[ -n "$cwd" ] || cwd="$root_local"
cwd="$(rw_physical_path "$cwd")"

[ -d "$root_local" ] || rw_die "resolve-workspace: root '$root_local' is not a directory" 7

root_rel="$(rw_root_rel "$root_local")" ||
  rw_die "resolve-workspace: root '$root_local' is not inside \$HOME (or is \$HOME itself); only directories under ~ can be handed off" 7

kind="$(rw_root_kind "$root_local")"
if [ "$kind" = "inside-git" ]; then
  rw_die "resolve-workspace: '$root_local' is inside the git worktree '$(git -C "$root_local" rev-parse --show-toplevel)'; hand off the worktree root instead" 7
fi

root_id="$(rw_root_id "$root_rel")"
worker_home="${worker_home%/}"
worker_root="$worker_home/$root_rel"

case "$cwd" in
  "$root_local") focus_path="$root_local"; remote_path="$worker_root" ;;
  "$root_local"/*) focus_path="$cwd"; remote_path="$worker_root/${cwd#"$root_local"/}" ;;
  *) focus_path="$root_local"; remote_path="$worker_root" ;;
esac

jq -nc \
  --arg root_id "$root_id" \
  --arg root_rel "$root_rel" \
  --arg root_local "$root_local" \
  --arg kind "$kind" \
  --arg worker_root "$worker_root" \
  --arg focus_path "$focus_path" \
  --arg remote_path "$remote_path" \
  '{root_id: $root_id, root_rel: $root_rel, root_local: $root_local, kind: $kind,
    worker_root: $worker_root, focus_path: $focus_path, remote_path: $remote_path}'
