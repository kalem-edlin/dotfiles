#!/usr/bin/env bash
# End-to-end test for the picker's worktree lifecycle keys (worktree-native
# tmux B3, keys per D103 and D104: C-a c, C-a C, ctrl-x, C-a D, C-a e, C-a E (D109); D102's
# main-checkout delete and missing-row prune; D105's one short confirm,
# every delete to the Trash, repurpose stashing on its own). A temp Developer-like tree with a
# real git repo, an isolated tmux server, the picker running in one of its
# panes and driven with send-keys, a control-mode client for switch-client
# to move, and the REAL wt script (git/.local/bin/wt, WT_PORT_PROBE=0).
#
# Never touches the live tmux server: every tmux call goes through a shim
# first in PATH that pins `-S <temp socket> -f /dev/null`, TMUX and TMUX_PANE
# are unset, TMUX_TMPDIR points into the scratch dir, and the harness aborts
# unless `command -v tmux` resolves to the shim. The picker's background
# resurrect save and rw-close.sh are logging shims (a real save would write
# the live resurrect directory). HOME is a temp dir for the picker and wt, so
# a trashed main checkout lands in a temp ~/.Trash, never the real one.
# Cleanup kills only the temp socket's server.
#
# Run: bash tmux/local-plugins/tmux-agent-sessions/tests/worktree-keys-test.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"
WT="$(cd "$PLUGIN_DIR/../../.." && pwd)/git/.local/bin/wt"

real_tmux="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
real_git="$(command -v git)" || { echo "SKIP: git not installed"; exit 0; }
command -v go >/dev/null || { echo "SKIP: go not installed"; exit 0; }
[ -x "$WT" ] || { echo "ABORT: wt not found at $WT" >&2; exit 2; }

# The socket path must stay under the 104-byte sun_path limit, so the
# scratch dir lives in /tmp rather than the long per-user TMPDIR.
scratch="$(mktemp -d /tmp/wt-keys-test.XXXXXX)" || exit 1
scratch="$(cd "$scratch" && pwd -P)"
sock="$scratch/tmux.sock"
cleanup() {
  exec 3>&- 2>/dev/null # ends the control client
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
for s in save rw-close; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\nexit 0\n' "$scratch" "$s" >"$shim_dir/$s.sh"
done
chmod +x "$shim_dir/tmux" "$shim_dir/save.sh" "$shim_dir/rw-close.sh"
PATH="$shim_dir:$PATH"
export PATH
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$scratch/tmux-tmpdir"
if [ "$(command -v tmux)" != "$shim_dir/tmux" ]; then
  echo "ABORT: tmux does not resolve to the shim" >&2
  exit 2
fi
# Panes run /bin/sh, so no user zsh startup file can change PATH under them.
export SHELL=/bin/sh

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
lacks() { # name needle haystack
  case "$3" in *"$2"*) bad "$1"; printf '  unexpected %s in:\n%s\n' "$2" "$3" ;; *) ok ;; esac
}

# --- fixture tree -----------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export WT_PORT_PROBE=0
unset GIT_DIR GIT_WORK_TREE
g() { "$real_git" -C "$1" "${@:2}" >/dev/null 2>&1 || { echo "ABORT: git ${*:2} in $1" >&2; exit 2; }; }
gout() { "$real_git" -C "$1" "${@:2}" 2>/dev/null; }

dev="$scratch/Developer"
app="$dev/app"
mkdir -p "$app"
g "$app" init -q -b main
echo x >"$app/f"
printf '.env.ports\n.env.local\n' >"$app/.gitignore" # wt new writes the first, as content-engine ignores both
printf 'FAKE=1\nNEXT_PORT=3000\n' >"$app/.env.local" # fake values only; wt new copies it, C-a e refreshes it
g "$app" add f .gitignore
g "$app" commit -q -m init

# --- isolated server, a control client, the picker --------------------------
tmux new-session -d -s home -x 160 -y 40 -c "$scratch" || { echo "ABORT: tmux server" >&2; exit 2; }
tmux set-option -g window-size manual
tmux set-option -g default-size 160x40
tmux set-option -g remain-on-exit off
mkfifo "$scratch/ctl.in"
tmux -C attach-session -t '=home:' <"$scratch/ctl.in" >"$scratch/ctl.out" 2>&1 &
exec 3>"$scratch/ctl.in"
client=""
for _ in $(seq 50); do
  client="$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -n 1)"
  [ -n "$client" ] && break
  sleep 0.1
done
[ -n "$client" ] || { echo "ABORT: no control client" >&2; exit 2; }
client_session() { tmux list-clients -F '#{client_session}' | head -n 1; }

plugin="$scratch/plugin"
mkdir -p "$plugin/bin" "$plugin/scripts"
printf '#!/bin/sh\nexit 0\n' >"$plugin/scripts/pane-mem" # memory is not under test
chmod +x "$plugin/scripts/pane-mem"
if ! go -C "$PLUGIN_DIR/picker" build -o "$plugin/bin/agent-picker" . 2>"$scratch/build.log"; then
  echo "ABORT: build failed" >&2
  cat "$scratch/build.log" >&2
  exit 2
fi
home="$scratch/home"
mkdir -p "$home"
penv="HOME='$home' AGENT_SESSIONS_DEV_ROOT='$dev' AGENT_SESSIONS_WT='$WT' AGENT_SESSIONS_RESURRECT_SAVE='$shim_dir/save.sh' AGENT_SESSIONS_RW_CLOSE='$shim_dir/rw-close.sh' WT_PORT_PROBE=0"

pane="" # the picker's pane
open_picker() {
  pane="$(tmux new-window -d -P -F '#{pane_id}' -t '=home:' "env $penv '$plugin/bin/agent-picker' '$client'")"
  wait_for "All" || { bad "picker opened"; tmux capture-pane -p -t "$pane"; }
}
screen() { tmux capture-pane -p -t "$pane" 2>/dev/null; }
wait_for() { # needle: poll the picker's screen for up to 15 s
  local i=0
  while [ "$i" -lt 150 ]; do
    case "$(screen)" in *"$1"*) return 0 ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
expect_screen() { # name needle
  if wait_for "$2"; then ok; else bad "$1"; printf '  missing %s on screen:\n%s\n' "$2" "$(screen)"; fi
}
pane_gone() {
  local i=0
  while [ "$i" -lt 150 ]; do
    tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$pane" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
keys() { tmux send-keys -t "$pane" "$@"; }
typed() { tmux send-keys -t "$pane" -l "$1"; }
query() { # clear the query, then type one
  keys BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace
  typed "$1"
  sleep 0.2
}
list() { AGENT_SESSIONS_DEV_ROOT="$dev" "$plugin/bin/agent-picker" --list 2>&1; }
has_session() { tmux has-session -t "=$1" 2>/dev/null && echo yes || echo no; }
tab=$'\t'

# --- C-a c: new worktree from main, its session, and the switch ---------------
open_picker
query main
keys C-a c
expect_screen "C-a c prompt" "new worktree from main: "
typed b3-keys
keys Enter
if pane_gone; then ok; else bad "picker exits after C-a c"; screen; fi
nk="$dev/b3-keys"
eq "wt new made the sibling worktree" "b3-keys" "$(gout "$nk" symbolic-ref --short HEAD)"
eq "cut from main" "$(gout "$app" rev-parse main)" "$(gout "$nk" rev-parse HEAD)"
eq "session named after the directory" yes "$(has_session b3-keys)"
eq "session rooted there" "$nk" "$(tmux display-message -p -t '=b3-keys:' '#{pane_current_path}')"
eq "client switched to it" b3-keys "$(client_session)"
eq "nothing installed" no "$([ -e "$nk/node_modules" ] && echo yes || echo no)"
has "listed on rediscovery" "wt${tab}app${tab}b3-keys${tab}b3-keys${tab}b3-keys" "$(list)"

# --- C-a C: new worktree from the row's branch --------------------------------
echo y >"$nk/g"
g "$nk" add g
g "$nk" commit -q -m second
open_picker
query b3-keys
keys C-a C
expect_screen "C-a C prompt" "new worktree from b3-keys: "
typed b3-child
keys Enter
if pane_gone; then ok; else bad "picker exits after C-a C"; screen; fi
nc="$dev/b3-child"
eq "C-a C based on the row's branch" "$(gout "$nk" rev-parse HEAD)" "$(gout "$nc" rev-parse HEAD)"
eq "C-a C session" yes "$(has_session b3-child)"
eq "client switched to the child" b3-child "$(client_session)"

# --- ctrl-x: repurpose a dirty worktree, stashed without asking ---------------
# ctrl-x is C-a x without the prefix (D104); the branch prompt is the only
# question and the dirt is stashed (D105).
echo dirt >"$nk/untracked.txt"
windows_before="$(tmux list-windows -t '=b3-keys:' | wc -l | tr -d ' ')"
open_picker
query b3-keys
keys C-x
expect_screen "ctrl-x prompt" "repurpose b3-keys to branch: "
typed b3-other
keys Enter
expect_screen "repurpose result line" "repurposed b3-keys to b3-other, 1 change stashed"
lacks "no stash confirm" "[y/N]" "$(screen)"
eq "repurposed in place" b3-other "$(gout "$nk" symbolic-ref --short HEAD)"
eq "cut from main, not the old branch" "$(gout "$app" rev-parse main)" "$(gout "$nk" rev-parse HEAD)"
has "tagged stash kept" "wt repurpose b3-keys" "$(gout "$app" stash list)"
eq "session keeps its name" yes "$(has_session b3-keys)"
eq "session keeps its windows" "$windows_before" "$(tmux list-windows -t '=b3-keys:' | wc -l | tr -d ' ')"
has "picker stays open, row relabelled" "b3-other" "$(screen)"

# --- C-a n/p move rows, nothing types; ctrl-s reaches the picker; main ------
query main
for k in n N p C-n C-p; do
  keys C-a "$k"
  sleep 0.3
  lacks "C-a $k starts no worktree prompt" "new worktree from" "$(screen)"
  lacks "C-a $k prompts nothing" "repurpose app" "$(screen)"
done
# The query is still "main" (1 of 4 rows, the home session included): nothing was typed.
expect_screen "query untouched by C-a n/N/p" "1/4"
# Bubble Tea's raw mode clears IXON, so ctrl-s is a key, not XOFF (D104).
keys C-s
expect_screen "ctrl-s opens the new session prompt" "new session: "
keys Escape
sleep 0.3
lacks "esc cancels the ctrl-s prompt" "new session: " "$(screen)"
keys C-a D
expect_screen "C-a D on main with linked worktrees" "app still has 2 linked worktrees: delete them first"
lacks "no confirm for main with linked worktrees" "[y/N]" "$(screen)"
# The list narrows to app (main, b3-keys, b3-child) and the query clears.
expect_screen "filter on app, query cleared" "3/3"
has "linked worktree shown" "b3-other" "$(screen)"
has "linked worktree shown" "b3-child" "$(screen)"
eq "main kept" main "$(gout "$app" symbolic-ref --short HEAD)"
keys C-a x
expect_screen "C-a x refuses main" "refusing to repurpose the main worktree: app"

# --- C-a e: every app worktree takes main's env files, own ports kept (D109) --
printf 'FAKE=2\nNEXT_PORT=3000\n' >"$app/.env.local"
query b3-child
keys C-a e
expect_screen "C-a e confirm" "refresh env of every app worktree from main? [y/N]"
keys y
expect_screen "C-a e result" "env refreshed in 2 app worktrees from app, copied only"
eq "child took main's .env.local" FAKE=2 "$(grep '^FAKE=' "$nc/.env.local")"
eq "child kept its own port" "$(grep '^NEXT_PORT=' "$nc/.env.ports")" "$(grep '^NEXT_PORT=' "$nc/.env.local")"
eq "other worktree refreshed too" FAKE=2 "$(grep '^FAKE=' "$nk/.env.local")"
eq "main's .env.local untouched" "$(printf 'FAKE=2\nNEXT_PORT=3000')" "$(cat "$app/.env.local")"

# --- C-a E: the row's own env files spread to every other worktree ------------
printf 'FAKE=3\n%s\n' "$(grep '^NEXT_PORT=' "$nc/.env.ports")" >"$nc/.env.local"
keys C-a E
expect_screen "C-a E confirm" "refresh env of every app worktree from b3-child? [y/N]"
keys y
expect_screen "C-a E result" "env refreshed in 2 app worktrees from b3-child, copied only"
eq "main took the child's .env.local" FAKE=3 "$(grep '^FAKE=' "$app/.env.local")"
eq "main's port back to the default" NEXT_PORT=3000 "$(grep '^NEXT_PORT=' "$app/.env.local")"
eq "other worktree took it with its own port" "$(grep '^NEXT_PORT=' "$nk/.env.ports")" "$(grep '^NEXT_PORT=' "$nk/.env.local")"
eq "other worktree took the child's key" FAKE=3 "$(grep '^FAKE=' "$nk/.env.local")"

# --- C-a D: a dirty worktree with its session goes to the Trash ----------------
echo dirt >"$nk/untracked2.txt"
stashes_before="$(gout "$app" stash list | wc -l | tr -d ' ')"
query b3-keys
keys C-a D
expect_screen "one short delete confirm" "delete b3-keys to Trash? [y/N]"
keys y
expect_screen "delete result line" "deleted b3-keys"
lacks "no second confirm" "[y/N]" "$(screen)"
eq "directory removed" no "$([ -e "$nk" ] && echo yes || echo no)"
eq "in the temp Trash with its dirt" yes "$([ -f "$home/.Trash/b3-keys/untracked2.txt" ] && echo yes || echo no)"
eq "session killed" no "$(has_session b3-keys)"
eq "branch kept" b3-other "$(gout "$app" rev-parse --abbrev-ref b3-other)"
eq "no stash made by the delete" "$stashes_before" "$(gout "$app" stash list | wc -l | tr -d ' ')"
lacks "gone on rediscovery" "${tab}b3-keys${tab}" "$(list)"
i=0
while [ ! -s "$scratch/save.log" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
eq "background save ran" quiet "$(cat "$scratch/save.log" 2>/dev/null)"

# --- C-a D: a clean worktree with a session -----------------------------------
# The own-session switch (D108) is Go-tested only: here the picker runs in
# a pane of home, which tmux takes as its current session, so no row is
# ever the client's own; the client is moved to home by hand so the kill
# does not detach it.
tmux switch-client -c "$client" -t '=home:'
query b3-child
keys C-a D
expect_screen "clean delete confirm" "delete b3-child to Trash? [y/N]"
keys y
expect_screen "clean delete result" "deleted b3-child"
eq "clean directory removed" no "$([ -e "$nc" ] && echo yes || echo no)"
eq "clean worktree in the temp Trash" yes "$([ -d "$home/.Trash/b3-child" ] && echo yes || echo no)"
eq "its session killed" no "$(has_session b3-child)"
keys Escape
if pane_gone; then ok; else bad "esc closes the picker"; fi

out="$(list)"
eq "only the main worktree is left" "wt${tab}app${tab}main${tab}app${tab}-${tab}-" "$(printf '%s\n' "$out" | grep '^wt')"
eq "wt registrations pruned" 1 "$(gout "$app" worktree list --porcelain | grep -c '^worktree ')"
eq "two saves, one per delete" 2 "$(wc -l <"$scratch/save.log" | tr -d ' ')"

# --- C-a D on a missing row prunes it ----------------------------------------
g "$app" worktree add -q "$dev/b3-gone" -b b3-gone
rm -rf "$dev/b3-gone"
open_picker
query b3-gone
keys C-a D
expect_screen "missing row pruned" "pruned b3-gone"
eq "registration pruned" 1 "$(gout "$app" worktree list --porcelain | grep -c '^worktree ')"
eq "pruned branch kept" b3-gone "$(gout "$app" rev-parse --abbrev-ref b3-gone)"
lacks "pruned row gone on rediscovery" "b3-gone" "$(list)"

# --- C-a D on main with no linked worktrees: the whole repo to the Trash ------
app_head="$(gout "$app" rev-parse HEAD)"
query main
keys C-a D
expect_screen "main delete confirm" "delete repo app to Trash? [y/N]"
keys y
expect_screen "main delete result" "deleted repo app"
eq "main checkout gone" no "$([ -e "$app" ] && echo yes || echo no)"
eq "recoverable from the temp Trash" "$app_head" "$(gout "$home/.Trash/app" rev-parse HEAD)"
has "stashes ride along" "wt repurpose b3-keys" "$(gout "$home/.Trash/app" stash list)"
lacks "no worktree rows left" "wt${tab}" "$(list)"
i=0
while [ "$(wc -l <"$scratch/save.log" | tr -d ' ')" -lt 3 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
eq "a save after the repo delete, none after the prune" 3 "$(wc -l <"$scratch/save.log" | tr -d ' ')"
keys Escape
if pane_gone; then ok; else bad "esc closes the picker after the repo delete"; fi

# Every tmux call went through the shim, and no server ever started on a
# default socket.
has "picker called new-session through the shim" "new-session -d -s b3-keys -c $nk" "$(cat "$scratch/tmux.log")"
eq "no default-socket server" 0 "$(find "$scratch/tmux-tmpdir" -type s | wc -l | tr -d ' ')"

printf 'worktree-keys tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
