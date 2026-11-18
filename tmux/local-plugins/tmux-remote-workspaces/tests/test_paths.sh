#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Path mapping relative to $HOME (D9, C1): root_rel, root_id, kinds, and
# resolve-workspace.sh's focus -> worker placement.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

mkdir -p "$HOME/Developer/idol-app/scripts/work" "$SANDBOX/outside"
make_worktree "$HOME/Developer/content-engine"

eq "root_rel strips \$HOME" "$(rw_root_rel "$HOME/Developer/idol-app")" "Developer/idol-app"
eq "root_rel of a trailing-slash path" "$(rw_root_rel "$HOME/Developer/idol-app/")" "Developer/idol-app"
check "root_rel refuses \$HOME itself (exit 7)" bash -c "source '$RW_PLUGIN/scripts/common.sh'; rw_root_rel '$HOME'; [ \$? -eq 7 ]"
check "root_rel refuses a path outside \$HOME (exit 7)" bash -c "source '$RW_PLUGIN/scripts/common.sh'; rw_root_rel '$SANDBOX/outside'; [ \$? -eq 7 ]"
eq "root_rel against an explicit (worker) home" "$(rw_root_rel /x/someone/Developer/x /x/someone)" "Developer/x"

want_id="$(printf '%s' "Developer/idol-app" | cksum | awk '{print $1}')"
eq "root_id is the cksum of root_rel" "$(rw_root_id Developer/idol-app)" "$want_id"
eq "root_id does not depend on the user name" "$(rw_root_id "$(rw_root_rel /x/a/Developer/idol-app /x/a)")" \
  "$(rw_root_id "$(rw_root_rel /x/b/Developer/idol-app /x/b)")"

eq "kind: plain folder" "$(rw_root_kind "$HOME/Developer/idol-app")" "plain"
eq "kind: linked worktree toplevel" "$(rw_root_kind "$HOME/Developer/content-engine/wt")" "git"
eq "kind: inside a worktree" "$(rw_root_kind "$HOME/Developer/content-engine/wt/node_modules")" "inside-git"

resolve() { "$RW_PLUGIN/scripts/resolve-workspace.sh" "$@"; }

out="$(resolve --cwd "$HOME/Developer/idol-app/scripts/work" --worker-home /w/home)"
eq "plain cwd: root defaults to the cwd itself" "$(jq -r .root_local <<<"$out")" "$HOME/Developer/idol-app/scripts/work"

out="$(resolve --root "$HOME/Developer/idol-app" --cwd "$HOME/Developer/idol-app/scripts/work" --worker-home /w/home)"
eq "plain root: worker_root = worker home + root_rel" "$(jq -r .worker_root <<<"$out")" "/w/home/Developer/idol-app"
eq "plain root: pane cwd maps below the worker root" "$(jq -r .remote_path <<<"$out")" "/w/home/Developer/idol-app/scripts/work"
eq "plain root: kind" "$(jq -r .kind <<<"$out")" "plain"
eq "plain root: root_id" "$(jq -r .root_id <<<"$out")" "$want_id"

out="$(resolve --cwd "$HOME/Developer/content-engine/wt/pkgs/app" --worker-home /home/admin/)"
eq "git cwd: root is the worktree toplevel" "$(jq -r .root_rel <<<"$out")" "Developer/content-engine/wt"
eq "git cwd: worker path keeps the subdirectory" "$(jq -r .remote_path <<<"$out")" "/home/admin/Developer/content-engine/wt/pkgs/app"
eq "git cwd: kind" "$(jq -r .kind <<<"$out")" "git"

out="$(resolve --root "$HOME/Developer/idol-app" --cwd "$SANDBOX/outside" --worker-home /w/home)"
eq "cwd outside an explicit root falls back to the root" "$(jq -r .remote_path <<<"$out")" "/w/home/Developer/idol-app"

resolve --root "$SANDBOX/outside" --worker-home /w/home >/dev/null 2>&1
eq "a root outside \$HOME exits 7" "$?" "7"
resolve --root "$HOME/Developer/content-engine/wt/build" --worker-home /w/home >/dev/null 2>&1
eq "a root inside a worktree exits 7" "$?" "7"
resolve --root "$HOME" --worker-home /w/home >/dev/null 2>&1
eq "\$HOME as a root exits 7" "$?" "7"

eq "config.json has no workspace_root" "$(jq -r 'has("workspace_root")' "$RW_PLUGIN/config.json")" "false"
check "no script reads workspace_root any more" bash -c "! grep -rn 'workspace_root\|rw-workspaces' '$RW_PLUGIN/scripts' '$RW_PLUGIN/libexec'"

# C4: the focus override never leaks into the worker state dir.
eq "rw_state_dir_at honors the worker override" "$(rw_state_dir_at /w/home)" "$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR"
eq "rw_state_dir_at default ignores the focus override" \
  "$(env -u TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR bash -c "source '$RW_PLUGIN/scripts/common.sh'; rw_state_dir_at /w/home")" \
  "/w/home/.local/state/tmux-remote-workspaces"

finish
