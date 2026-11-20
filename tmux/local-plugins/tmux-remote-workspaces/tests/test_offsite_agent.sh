#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# The off-root agent guard (A5, docs/tasks/remote-owned-directories.md): a
# hand-off refuses when a local agent pane launched OUTSIDE the root has a
# transcript whose latest cwd is the root or inside it, because that pane is
# not moved (pane_current_path is the launch directory) and the agent would
# keep writing the root here while the worker owns it.
#
#   A  refused by `rw bg handoff` (exit 7, one `rw:` line, as the picker shows
#      it) and by `rw handoff` (exit 1, nothing moved), naming the pane
#   B  passes: agent cwd outside the root; agent launched inside the root
#      (it moves normally); dead agent pid; missing transcript; no recorded
#      session; remote pane; pi agent
#   C  null-cwd trailing lines are skipped; the newest cwd wins; the tail is
#      bounded; a symlinked cwd is resolved; several offenders are counted
#
# The claude adapter is a fake for `detect` only (it needs a process tree);
# `transcript-path` runs the REAL adapter, so the slug encoding is the one
# claude resume uses. No tmux server, no ssh.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/roots.sh
source "$RW_PLUGIN/scripts/roots.sh"

export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
export RW_ADAPTERS_DIR="$SANDBOX/adapters"
mkdir -p "$RW_ADAPTERS_DIR"
cat >"$RW_ADAPTERS_DIR/claude" <<'ADAPTER'
#!/usr/bin/env bash
# detect: the session recorded for a pane is $FAKE_SESSIONS/<pane>.json
# (absent: no recorded session, exit 1). Everything else is the real adapter.
if [ "$1" = detect ]; then
  f="$FAKE_SESSIONS/$3.json"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
exec "$RW_REAL_ADAPTERS/claude" "$@"
ADAPTER
chmod +x "$RW_ADAPTERS_DIR/claude"
ln -s "$RW_PLUGIN/libexec/adapters/common-adapter.sh" "$RW_ADAPTERS_DIR/"
export RW_REAL_ADAPTERS="$RW_PLUGIN/libexec/adapters"
export FAKE_SESSIONS="$SANDBOX/sessions"
mkdir -p "$FAKE_SESSIONS"

rw() { "$RW_PLUGIN/scripts/rw" "$@"; }

root="$HOME/Developer/proj"
other="$HOME/Developer/elsewhere"
make_plain "$root"
mkdir -p "$root/sub" "$other"
ln -s "$root" "$HOME/Developer/alias-of-proj"

# A live pid to stand in for the agent process (this shell), and a dead one.
live_pid=$$
true &
dead_pid=$!
wait "$dead_pid" 2>/dev/null

slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
# session <pane> <launch dir> <session id> -- the recorded session of a pane.
session() {
  jq -nc --arg s "$3" --arg p "$2" '{provider: "claude", session_id: $s, project_path: $p, mode_flags: ""}' >"$FAKE_SESSIONS/$1.json"
}
# transcript <launch dir> <session id> <cwd lines...> -- one entry per cwd
# ("null" = a null cwd, e.g. an api-request entry).
transcript() {
  local launch="$1" sid="$2" dir c
  shift 2
  dir="$HOME/.claude/projects/$(slug "$launch")"
  mkdir -p "$dir"
  : >"$dir/$sid.jsonl"
  for c in "$@"; do
    if [ "$c" = null ]; then
      printf '{"type":"api-request","cwd":null,"n":1}\n' >>"$dir/$sid.jsonl"
    else
      jq -nc --arg c "$c" '{type: "assistant", cwd: $c, message: "x"}' >>"$dir/$sid.jsonl"
    fi
  done
}
# pane <id> <cwd> <index> [kind] [pid] [endpoint]
pane() {
  printf 'pane_id=%s\tpane_current_path=%s\tsession_name=s1\twindow_index=2\tpane_index=%s\tpane_current_command=claude\tpane_pid=999990\t@agent_kind=%s\t@agent_pid=%s\t@rw-endpoint=%s\n' \
    "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}"
}
shell_pane() { printf 'pane_id=%s\tpane_current_path=%s\tsession_name=s1\twindow_index=2\tpane_index=%s\tpane_current_command=zsh\tpane_pid=999991\n' "$1" "$2" "$3"; }
offenders() { rw_root_offsite_agents "$root"; }

# The agent pane %1 started in ~/Developer/elsewhere (not in the root); a
# shell %2 sits in the root so `--pane` has somewhere to point.
{ pane %1 "$other" 0 claude "$live_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
session %1 "$other" sess-1
transcript "$other" sess-1 "$other" "$root/sub"

# --- A: refused ----------------------------------------------------------------
line="$(offenders)"
eq "A: the helper names the pane, kind, agent cwd and launch dir" "$line" \
  "$(printf '%%1\ts1:2.0\tclaude\t%s\t%s' "$root/sub" "$other")"

want="s1:2.0 runs claude working in ~/Developer/proj/sub (started in ~/Developer/elsewhere); it would keep writing ~/Developer/proj on this machine. Stop it or start it inside ~/Developer/proj, then hand off."
rw bg handoff --worker fakeworker --pane %2 --root "$root" >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "A: rw bg handoff refuses: exit 7" "$?" "7"
eq "A: rw bg handoff: the one-line refusal the picker shows" "$(grep '^rw' "$SANDBOX/err" | tail -n 1)" "rw: $want"
check "A: rw bg handoff started nothing (no job, no log)" test -z "$(ls "$(rw_bg_dir)" 2>/dev/null)"

rw handoff --worker fakeworker --root "$root" >"$SANDBOX/out" 2>"$SANDBOX/err"
eq "A: rw handoff refuses: exit 1" "$?" "1"
eq "A: rw handoff: the same refusal" "$(grep '^rw' "$SANDBOX/err" | tail -n 1)" "rw: $want"
check "A: rw handoff moved nothing (no worker copy, no ssh)" test ! -e "$FAKE_WORKER_HOME/Developer/proj" -a ! -s "$FAKE_SSH_LOG"
check "A: rw handoff left no ownership record" test ! -e "$(rw_owned_record_file "$(rw_root_id Developer/proj)")"
echo "     message: rw: $want"

# --- B: passes -----------------------------------------------------------------
transcript "$other" sess-1 "$other"
eq "B: agent cwd outside the root passes" "$(offenders)" ""
if rw_offsite_agents_refusal "$root" >/dev/null; then bad "B: ... and the refusal helper reports nothing"; else ok "B: ... and the refusal helper reports nothing"; fi

transcript "$other" sess-1 "$root/sub"
{ pane %1 "$root/sub" 0 claude "$live_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
session %1 "$root/sub" sess-1
transcript "$root/sub" sess-1 "$root/sub"
eq "B: agent launched inside the root passes (it moves normally)" "$(offenders)" ""

{ pane %1 "$other" 0 claude "$dead_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
session %1 "$other" sess-1
transcript "$other" sess-1 "$root/sub"
eq "B: a dead @agent_pid passes" "$(offenders)" ""

{ pane %1 "$other" 0 claude "$live_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
rm -f "$HOME/.claude/projects/$(slug "$other")/sess-1.jsonl"
eq "B: a missing transcript passes" "$(offenders)" ""

transcript "$other" sess-1 "$root/sub"
rm -f "$FAKE_SESSIONS/%1.json"
eq "B: no recorded session (adapter detect fails) passes" "$(offenders)" ""
session %1 "$other" sess-1
eq "B: control: with the session recorded again it is refused" "$(offenders | cut -f1)" "%1"

{ pane %1 "$other" 0 claude "$live_pid" rw-abc123; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
eq "B: a remote pane (has @rw-endpoint) passes" "$(offenders)" ""

{ pane %1 "$other" 0 pi "$live_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
eq "B: a pi agent is skipped (its session records no changing cwd)" "$(offenders)" ""

{ pane %1 "$other" 0 "" ""; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
eq "B: a pane with no agent options passes" "$(offenders)" ""

printf 'not json at all\n{"truncated":' >"$HOME/.claude/projects/$(slug "$other")/sess-1.jsonl"
{ pane %1 "$other" 0 claude "$live_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
eq "B: an unreadable transcript passes (never blocks a hand-off)" "$(offenders)" ""

# --- C: reading the transcript -------------------------------------------------
transcript "$other" sess-1 "$root/sub" null null "$root/data" null null null
eq "C: trailing null-cwd lines are skipped; the newest real cwd wins" "$(offenders | cut -f4)" "$root/data"

transcript "$other" sess-1 "$root/sub" null "$other" null
eq "C: the agent that cd'd back out of the root passes" "$(offenders)" ""

transcript "$other" sess-1 "$other" "$root"
eq "C: a cwd equal to the root is inside it" "$(offenders | cut -f4)" "$root"

transcript "$other" sess-1 "${root}-sibling"
eq "C: a sibling sharing the root's name as a prefix is not inside it" "$(offenders)" ""

transcript "$other" sess-1 "$HOME/Developer/alias-of-proj/sub"
eq "C: a cwd through a symlink is resolved to the root" "$(offenders | cut -f4)" "$root/sub"

# Only the tail is read: a cwd in the root older than the tail does
# not count: with a 3-line tail the three null lines hide it (fail open); the
# default 200-line tail reaches it.
transcript "$other" sess-1 "$root/sub" null null null
eq "C: bounded read: a cwd older than the tail is not looked at" "$(RW_OFFSITE_TAIL_LINES=3 offenders)" ""
eq "C: ... the default tail (200 lines) reaches it" "$(offenders | cut -f4)" "$root/sub"

# Several offenders: the first is named, the rest counted.
{ pane %1 "$other" 0 claude "$live_pid"; pane %3 "$other" 3 claude "$live_pid"; shell_pane %2 "$root" 1; } >"$FAKE_TMUX_PANES"
transcript "$other" sess-1 "$root/sub"
session %3 "$other" sess-1
eq "C: two offenders are listed" "$(offenders | wc -l | tr -d ' ')" "2"
rw handoff --worker fakeworker --root "$root" >/dev/null 2>"$SANDBOX/err"
eq "C: several offenders: exit 1" "$?" "1"
eq "C: several offenders: the first is named with 'and 1 more'" \
  "$(grep '^rw' "$SANDBOX/err" | tail -n 1 | cut -c1-48)" "rw: s1:2.0 (and 1 more) runs claude working in ~"

finish
