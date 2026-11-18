#!/usr/bin/env bash
# Shared harness for the tmux-remote-workspaces shell tests. Sourced only.
#
# Every test runs WITHOUT tmux and WITHOUT ssh (contract C8):
#   - `tmux` on PATH is a stub that logs its arguments and prints nothing,
#     so no command can ever reach a real tmux server;
#   - `ssh` on PATH (and RW_SSH_BIN) is a same-host fake that runs the
#     remote command with `bash -c` inside a separate fake worker $HOME,
#     so the exact ssh argv shapes (including rsync -e) are exercised;
#   - the focus side gets its own fake $HOME and state dir, the worker side
#     its own state dir (TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR, C4);
#   - git runs with an isolated config (no user/system excludes or hooks).

RW_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RW_PLUGIN="$(cd "$RW_TEST_DIR/.." && pwd)"
# shellcheck disable=SC2034 # used by the test files that source this
RW_SYNC="$RW_PLUGIN/libexec/sync/handoff"

T_PASS=0
T_FAIL=0

ok() {
  T_PASS=$((T_PASS + 1))
  printf 'ok   %s\n' "$1"
}

bad() {
  T_FAIL=$((T_FAIL + 1))
  printf 'FAIL %s\n' "$1"
}

# check <description> <command...> -- passes when the command succeeds.
check() {
  local desc="$1"
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# eq <description> <got> <want>
eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1"
    printf '     got:  %s\n     want: %s\n' "$2" "$3"
  fi
}

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

# trees_equal <a> <b> -- same files and contents, ignoring .git.
trees_equal() {
  diff -r -x .git "$1" "$2" >/dev/null 2>&1
}

rw_test_sandbox() {
  SANDBOX="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/rw-tests.XXXXXX")" && pwd -P)"
  # shellcheck disable=SC2064 # expand now: the path is fixed for this run
  trap "rm -rf '$SANDBOX'" EXIT

  export HOME="$SANDBOX/focus-home"
  export FAKE_WORKER_HOME="$SANDBOX/worker-home"
  mkdir -p "$HOME" "$FAKE_WORKER_HOME" "$SANDBOX/bin"
  export TMUX_REMOTE_WORKSPACES_STATE_DIR="$SANDBOX/focus-state"
  export TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR="$SANDBOX/worker-state"
  export XDG_STATE_HOME="$SANDBOX/xdg-state"
  export FAKE_TMUX_LOG="$SANDBOX/tmux.log"
  export FAKE_SSH_LOG="$SANDBOX/ssh.log"
  export FAKE_SSH_DOWN="$SANDBOX/ssh.down"
  unset TMUX TMUX_PANE

  cat >"$SANDBOX/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: never a real tmux server (contract C8). Logs every call. When
# $FAKE_TMUX_PANES names a pane table (one pane per line, TAB-separated
# key=value pairs: pane_id, pane_current_path, session_name, window_index,
# pane_index, pane_current_command, pane_pid, @options...), list-panes -a,
# display-message, show-option and set-option answer from it. Remote
# endpoint sessions (rw-*) report $FAKE_TMUX_REMOTE_CMD as their command.
# send-keys of a claudef/pif resume flips a pane's command to the agent when
# $FAKE_LOCAL_RESUME_OK=1; respawn-pane resets it to a shell.
# A fake agent "writes until stopped": reading the pane pid of
# $FAKE_AGENT_PANE (how rw stops a local agent) appends to
# $FAKE_AGENT_LASTWRITE; reading a remote session's pane pid appends to
# $FAKE_REMOTE_LASTWRITE. $FAKE_EVENTS gets one ordered line per call.
printf '%s\n' "$*" >>"${FAKE_TMUX_LOG:-/dev/null}"
printf 'tmux %s\n' "$*" >>"${FAKE_EVENTS:-/dev/null}"
table="${FAKE_TMUX_PANES:-}"
[ -n "$table" ] && [ ! -f "$table" ] && : >"$table"
expand() { # <fmt> <pane line>
  local fmt="$1" kv k v
  local -a kvs
  IFS=$'\t' read -ra kvs <<<"$2"
  for kv in "${kvs[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    fmt="${fmt//"#{$k}"/$v}"
  done
  printf '%s\n' "$fmt" | sed 's/#{[^}]*}//g'
}
line_of() { [ -n "$table" ] && grep -E "^pane_id=$1(\t|$)" "$table" | head -n1; }
get() { line_of "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | head -n1; }
put() { # <pane> <key> <value>
  [ -n "$table" ] || return 0
  awk -F '\t' -v OFS='\t' -v p="pane_id=$1" -v k="$2" -v v="$3" '
    $1 == p { found = 0; for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) { $i = k "=" v; found = 1 }
              if (!found) $(NF + 1) = k "=" v }
    { print }' "$table" >"$table.tmp" && mv "$table.tmp" "$table"
}
cmd="${1:-}"; shift
target="" fmt="" rest=() all=0 unset_opt=0
while [ $# -gt 0 ]; do
  case "$1" in
    -F) fmt="$2"; shift 2 ;;
    -*)
      case "$1" in *a*) all=1 ;; esac
      case "$1" in *u*) unset_opt=1 ;; esac
      if [ "${1: -1}" = "t" ]; then target="$2"; shift 2; else shift; fi
      ;;
    *) rest+=("$1"); shift ;;
  esac
done
target="${target#=}"
case "$cmd" in
  list-panes)
    if [ -n "$target" ] && [ "${target#rw-}" != "$target" ]; then
      case "$fmt" in *pane_pid*) [ -n "${FAKE_REMOTE_LASTWRITE:-}" ] && echo "last remote write" >>"$FAKE_REMOTE_LASTWRITE" ;; esac
      expand "$fmt" "pane_id=%90	pane_current_command=${FAKE_TMUX_REMOTE_CMD:-zsh}	pane_pid=999999"
    elif [ "$all" = 1 ] && [ -n "$table" ]; then
      while IFS= read -r l; do [ -n "$l" ] && expand "$fmt" "$l"; done <"$table"
    fi
    ;;
  display-message)
    [ -n "$fmt" ] || fmt="${rest[${#rest[@]}-1]:-}"
    if [ -z "$target" ]; then
      # The server itself: $FAKE_TMUX_SERVER is "<pid>:<start_time>".
      server="${FAKE_TMUX_SERVER:-4242:1700000000}"
      expand "$fmt" "pid=${server%%:*}	start_time=${server#*:}"
      exit 0
    fi
    if [ "$target" = "${FAKE_AGENT_PANE:-}" ] && [ -n "${FAKE_AGENT_LASTWRITE:-}" ]; then
      case "$fmt" in *pane_pid*) echo "last local write" >>"$FAKE_AGENT_LASTWRITE" ;; esac
    fi
    l="$(line_of "$target")"
    [ -n "$l" ] && expand "$fmt" "$l"
    ;;
  show-option | show-options)
    # %90 is the remote endpoint pane: its @agent_state comes from
    # $FAKE_REMOTE_AGENT_STATE.
    if [ "$target" = "%90" ]; then
      [ "${rest[${#rest[@]}-1]:-}" = "@agent_state" ] && printf '%s\n' "${FAKE_REMOTE_AGENT_STATE:-}"
      exit 0
    fi
    [ -n "$target" ] && get "$target" "${rest[${#rest[@]}-1]:-}"
    ;;
  set-option)
    if [ -n "$target" ] && [ -n "$(line_of "$target")" ]; then
      if [ "$unset_opt" = 1 ]; then put "$target" "${rest[0]}" ""; else put "$target" "${rest[0]}" "${rest[1]:-}"; fi
    fi
    ;;
  send-keys)
    if [ "${FAKE_LOCAL_RESUME_OK:-0}" = 1 ] && [ -n "$(line_of "$target")" ]; then
      case "${rest[*]}" in *claudef* | *pif*) put "$target" pane_current_command claude ;; esac
    fi
    ;;
  respawn-pane)
    # $FAKE_ON_RESPAWN: a command run at each respawn (tests observe state then).
    [ -n "${FAKE_ON_RESPAWN:-}" ] && bash -c "$FAKE_ON_RESPAWN" >/dev/null 2>&1
    [ -n "$(line_of "$target")" ] && put "$target" pane_current_command bash
    ;;
  list-sessions)
    # $FAKE_TMUX_SESSIONS: "name created-epoch attached" per line.
    if [ -n "${FAKE_TMUX_SESSIONS:-}" ] && [ -f "$FAKE_TMUX_SESSIONS" ]; then
      [ -n "$fmt" ] || fmt='#{session_name}'
      while read -r n c a; do
        [ -n "$n" ] && expand "$fmt" "session_name=$n	session_created=$c	session_attached=$a"
      done <"$FAKE_TMUX_SESSIONS"
    fi
    ;;
esac
exit 0
EOF

  cat >"$SANDBOX/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Same-host fake ssh: `ssh [-o opt]... host command...` runs the command
# with bash -c in the fake worker home. Touch $FAKE_SSH_DOWN to simulate an
# unreachable worker (exit 255, like ssh).
host=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -p | -l | -i | -F | -J) shift 2 ;;
    -*) shift ;;
    *) host="$1"; shift; break ;;
  esac
done
cmd="$*"
printf '%s\t%s\n' "$host" "${cmd//$'\n'/ }" >>"${FAKE_SSH_LOG:-/dev/null}"
printf 'ssh %s\n' "${cmd//$'\n'/ }" >>"${FAKE_EVENTS:-/dev/null}"
if [ -e "${FAKE_SSH_DOWN:-/nonexistent}" ]; then
  echo "ssh: connect to host $host port 22: Connection refused" >&2
  exit 255
fi
cd "$FAKE_WORKER_HOME" || exit 255
HOME="$FAKE_WORKER_HOME" exec bash -c "$*"
EOF
  cat >"$SANDBOX/bin/ps" <<'EOF'
#!/usr/bin/env bash
# The real ps, plus the synthetic process lines in $FAKE_PS_EXTRA (one
# "pid ppid command" per line) for the `ps axo pid=,ppid=,command=` form:
# a fake agent process under a fake pane pid.
/bin/ps "$@"
case "$*" in
  *pid=,ppid=,command=*) [ -n "${FAKE_PS_EXTRA:-}" ] && [ -f "$FAKE_PS_EXTRA" ] && cat "$FAKE_PS_EXTRA" ;;
esac
exit 0
EOF
  chmod +x "$SANDBOX/bin/tmux" "$SANDBOX/bin/ssh" "$SANDBOX/bin/ps"
  # Closing worker sessions asks the worker for a verified save; here that
  # only leaves a trace (never launchctl/systemctl against this machine).
  export RW_WORKER_SAVE_TRIGGER="echo save-requested >>'$SANDBOX/worker-saves.log'"
  export PATH="$SANDBOX/bin:$PATH"
  export RW_SSH_BIN="$SANDBOX/bin/ssh"

  cat >"$SANDBOX/config.json" <<'EOF'
{
  "workers": [{"alias": "fakeworker", "platform": "darwin", "notes": "test double"}],
  "ssh": {"connect_timeout_seconds": 3, "preflight_timeout_seconds": 3, "status_timeout_seconds": 2}
}
EOF
  export TMUX_REMOTE_WORKSPACES_CONFIG="$SANDBOX/config.json"

  printf '[user]\n\tname = rw test\n\temail = rw-test@example.invalid\n[init]\n\tdefaultBranch = main\n' >"$SANDBOX/gitconfig"
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
}

# make_worktree <dir> -- a main checkout at <dir>/main plus a linked
# worktree at <dir>/wt with tracked, untracked and gitignored content.
make_worktree() {
  local base="$1"
  mkdir -p "$base"
  git init -q "$base/main"
  printf 'node_modules/\n.env*\nbuild/\n' >"$base/main/.gitignore"
  echo tracked >"$base/main/t.txt"
  git -C "$base/main" add .
  git -C "$base/main" commit -qm init
  git -C "$base/main" worktree add -q "$base/wt" -b feat
  mkdir -p "$base/wt/node_modules/pkg" "$base/wt/build" "$base/wt/pkgs/app/node_modules/x"
  echo m >"$base/wt/node_modules/pkg/index.js"
  echo SECRET=1 >"$base/wt/.env.local"
  echo out >"$base/wt/build/out.bin"
  echo y >"$base/wt/pkgs/app/node_modules/x/y.js"
  echo untracked >"$base/wt/notes.txt"
  echo dirty >>"$base/wt/t.txt"
}

# make_plain <dir> -- a non-git folder with nesting and a symlink.
make_plain() {
  local dir="$1"
  mkdir -p "$dir/scripts/work" "$dir/data"
  echo run >"$dir/scripts/work/run.sh"
  echo 1 >"$dir/data/a.csv"
  echo 2 >"$dir/data/b.csv"
  echo note >"$dir/README"
  ln -s data/a.csv "$dir/latest"
}
