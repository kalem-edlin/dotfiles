#!/usr/bin/env bash
# End-to-end test for the picker's one list (worktree-native tmux V5-V8):
# real git repos in a temp Developer-like tree, an isolated tmux server, and
# `agent-picker --list`, which prints the rows as the picker opens them.
#
# Never touches the live tmux server: every tmux call goes through a shim
# first in PATH that pins `-S <temp socket> -f /dev/null`, TMUX and TMUX_PANE
# are unset, TMUX_TMPDIR points into the scratch dir, and the harness aborts
# unless `command -v tmux` resolves to the shim. Cleanup kills only the
# temp socket's server.
#
# Run: bash tmux/local-plugins/tmux-agent-sessions/tests/worktree-list-test.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"

real_tmux="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
real_git="$(command -v git)" || { echo "SKIP: git not installed"; exit 0; }
command -v go >/dev/null || { echo "SKIP: go not installed"; exit 0; }

# The socket path must stay under the 104-byte sun_path limit, so the
# scratch dir lives in /tmp rather than the long per-user TMPDIR.
scratch="$(mktemp -d /tmp/wt-list-test.XXXXXX)" || exit 1
scratch="$(cd "$scratch" && pwd -P)"
sock="$scratch/tmux.sock"
cleanup() {
  if [ -S "$sock" ]; then
    "$real_tmux" -S "$sock" kill-server 2>/dev/null
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

# --- tmux safety harness ----------------------------------------------------
shim_dir="$scratch/shim"
mkdir -p "$shim_dir" "$scratch/tmux-tmpdir"
cat >"$shim_dir/tmux" <<SHIM
#!/bin/sh
# Isolated tmux: every call is pinned to the test socket and logged.
printf '%s\n' "\$*" >>'$scratch/tmux.log'
exec '$real_tmux' -S '$sock' -f /dev/null "\$@"
SHIM
chmod +x "$shim_dir/tmux"
PATH="$shim_dir:$PATH"
export PATH
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$scratch/tmux-tmpdir"
if [ "$(command -v tmux)" != "$shim_dir/tmux" ]; then
  echo "ABORT: tmux does not resolve to the shim" >&2
  exit 2
fi

# --- tiny assertion helpers -------------------------------------------------
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok; else bad "$1"; printf '  expected: %s\n  actual:   %s\n' "$2" "$3"; fi
}
has() { # name needle haystack
  case "$3" in *"$2"*) ok ;; *) bad "$1"; printf '  missing %s in:\n%s\n' "$2" "$3" ;; esac
}

# --- fixture tree -----------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
g() { "$real_git" -C "$1" "${@:2}" >/dev/null 2>&1 || { echo "ABORT: git ${*:2} in $1" >&2; exit 2; }; }
repo() { # dir: main checkout on main with one commit
  mkdir -p "$1"
  g "$1" init -q -b main
  echo x >"$1/f"
  g "$1" add f
  g "$1" commit -q -m init
}
big() { # path bytes
  mkdir -p "$(dirname "$1")"
  head -c "$2" /dev/zero >"$1"
}

dev="$scratch/Developer"
app="$dev/app"
tools="$dev/org/tools"
repo "$app"
g "$app" worktree add -q -b feat "$dev/app-feat"
g "$app" worktree add -q -b locked-br "$dev/app-locked"
g "$app" worktree lock --reason heavy "$dev/app-locked"
g "$app" worktree add -q -b gone-br "$dev/app-gone"
rm -rf "$dev/app-gone"
g "$app" worktree add -q -b eph "$dev/.eph/app-eph"   # hidden: found through the repo only
repo "$tools"                                          # depth 2, under an org dir
g "$tools" worktree add -q -b slot "$dev/org/tools-slot" # depth 2 and linked: listed once
mkdir -p "$dev/notes" "$dev/deep/a/b"                  # not repos
repo "$dev/deep/a/b"                                   # depth 3: not scanned
echo notes >"$dev/readme.md"

# Heavy: Pods and a 2 KB model in app-feat; only an LFS pointer in app-locked.
mkdir -p "$dev/app-feat/apps/expo/ios/Pods"
big "$dev/app-feat/packages/native-tools/ios/Models/m/model.bin" 2048
big "$dev/app-locked/packages/native-tools/ios/Models/model.bin" 130
mkdir -p "$dev/app/node_modules/x"                     # never a symbol

# Last activity without a session is the HEAD or index mtime.
stamp() { # stamp gitdir...
  local t="$1" d
  shift
  for d in "$@"; do
    touch -t "$t" "$d/HEAD"
    [ -f "$d/index" ] && touch -t "$t" "$d/index"
  done
}
wts="$app/.git/worktrees"
stamp 202001010000 "$wts/app-gone"
stamp 202101010000 "$tools/.git/worktrees/tools-slot"
stamp 202201010000 "$wts/app-locked"
stamp 202301010000 "$tools/.git"
stamp 202401010000 "$wts/app-eph"
stamp 202501010000 "$app/.git"
stamp 202501010000 "$wts/app-feat"

# --- isolated server: one session named after a worktree, one plain ---------
tmux new-session -d -s app-feat -c "$dev/app-feat" || { echo "ABORT: tmux server" >&2; exit 2; }
tmux new-session -d -s home -c "$scratch"
tmux set-option -p -t '=app-feat:' @pane_focus_at 1767225600 # 2026-01-01
tmux set-option -p -t '=home:' @pane_focus_at 1656633600     # 2022-07-01
eq "isolated server sessions" "app-feat home" "$(tmux list-sessions -F '#{session_name}' | sort | tr '\n' ' ' | sed 's/ $//')"

# --- build and list ---------------------------------------------------------
plugin="$scratch/plugin"
mkdir -p "$plugin/bin" "$plugin/scripts"
printf '#!/bin/sh\nexit 0\n' >"$plugin/scripts/pane-mem" # memory is not under test
chmod +x "$plugin/scripts/pane-mem"
if ! go -C "$PLUGIN_DIR/picker" build -o "$plugin/bin/agent-picker" . 2>"$scratch/build.log"; then
  echo "ABORT: build failed" >&2
  cat "$scratch/build.log" >&2
  exit 2
fi

out="$(AGENT_SESSIONS_DEV_ROOT="$dev" "$plugin/bin/agent-picker" --list 2>&1)"
status=$?
eq "--list exits 0" 0 "$status"

tab=$'\t'
expected="$(cat <<EOF | tr '|' "$tab"
wt|app|gone-br|app-gone|-|missing
wt|tools|slot|tools-slot|-|-
wt|app|locked-br|app-locked|-|locked
sess|home
wt|tools|main|tools|-|-
wt|app|eph|app-eph|-|-
wt|app|main|app|-|-
wt|app|feat|app-feat|app-feat|ios,lfs
tabs|All|app|tools
EOF
)"
eq "rows, order, markers and tab order" "$expected" "$out"

# The same facts one at a time, so a failure says which one broke.
has "every worktree of every repo, sessions or not" "wt${tab}app${tab}eph${tab}app-eph${tab}-" "$out"
has "the session joins its worktree by name" "app-feat${tab}app-feat${tab}ios,lfs" "$out"
has "a plain session stays a plain row" "sess${tab}home" "$out"
has "lock marker" "app-locked${tab}-${tab}locked" "$out"
has "missing marker" "app-gone${tab}-${tab}missing" "$out"
eq "a pointer-size model is not lfs" 0 "$(printf '%s\n' "$out" | grep -c 'app-locked.*lfs')"
eq "a slot found twice is one row" 1 "$(printf '%s\n' "$out" | grep -c "${tab}tools-slot${tab}")"
eq "non-repos and depth 3 skipped" 0 "$(printf '%s\n' "$out" | grep -Ec "${tab}(notes|b|readme.md)${tab}")"
eq "rows without a session (dim)" 6 "$(printf '%s\n' "$out" | awk -F"$tab" '$1 == "wt" && $5 == "-"' | wc -l | tr -d ' ')"
eq "repos ordered by most recent worktree" "tabs${tab}All${tab}app${tab}tools" "$(printf '%s\n' "$out" | tail -n 1)"

# A worktree whose session goes away turns dim; the session-less one
# whose session appears joins it.
tmux kill-session -t '=app-feat'
tmux new-session -d -s tools -c "$tools"
tmux set-option -p -t '=tools:' @pane_focus_at 1767225600
out="$(AGENT_SESSIONS_DEV_ROOT="$dev" "$plugin/bin/agent-picker" --list 2>&1)"
has "killed session leaves a dim row" "wt${tab}app${tab}feat${tab}app-feat${tab}-${tab}ios,lfs" "$out"
eq "new session joins its worktree, newest last" "wt${tab}tools${tab}main${tab}tools${tab}tools${tab}-" "$(printf '%s\n' "$out" | sed -n '8p')"
eq "tab order follows" "tabs${tab}All${tab}tools${tab}app" "$(printf '%s\n' "$out" | tail -n 1)"

# Every tmux call went through the shim: the picker's list-panes is in its
# log, and no server ever started on a default socket.
has "picker called list-panes through the shim" "list-panes -a -F" "$(cat "$scratch/tmux.log")"
eq "no default-socket server" 0 "$(find "$scratch/tmux-tmpdir" -type s | wc -l | tr -d ' ')"

printf 'worktree-list tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
