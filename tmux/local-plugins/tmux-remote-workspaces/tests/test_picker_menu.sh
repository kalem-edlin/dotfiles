#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2088 # expected headers and labels show a literal ~
# shellcheck disable=SC2016 # bash -c scripts take their arguments as $1, $2
# `prefix e` menu (docs/tasks/remote-owned-directories.md, "Pane host
# switching": S1, S9, D19, D20, D26, CS5), against lib.sh's pane-table tmux
# stub, a stub fzf and a stub rw:
#   - rows for every pane host x owner combination with one and two
#     workers: soft-switch rows first (the owner first), the full-transfer
#     rows last (one hand back for a worker-owned root, one hand off per
#     worker otherwise, named by worker, never by the root path)
#   - rows are short and unpadded; the reachability marker leads the row
#   - the agent note on soft switches to a non-owner destination
#   - the header (picker revision 2026-11-20): directory and root; the
#     hosts line only when pane host and owner differ or the remote is
#     unreachable; yellow warnings; the muted --color=header; the `moves:`
#     line naming the panes a hand-off moves; no unsaved-buffers line
#   - dispatch: the chosen row runs exactly `rw switch`, `rw bg handoff
#     --worker <alias>` or `rw bg handback`; no second chooser; esc runs
#     nothing; refusals and failures are shown inline
#   - probe-rows keeps the row order, fills in reachability once per worker

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

PICKER="$RW_PLUGIN/scripts/rw-picker.sh"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"

one_worker() {
  jq -n '{workers: [{alias: "fakeworker", platform: "darwin", notes: "test double"}],
          ssh: {connect_timeout_seconds: 3, preflight_timeout_seconds: 3, status_timeout_seconds: 2}}' \
    >"$SANDBOX/config.json"
}
two_workers() {
  jq -n '{workers: [{alias: "fakeworker", platform: "darwin", notes: "test double"},
                    {alias: "other", platform: "linux", notes: "second"}],
          ssh: {connect_timeout_seconds: 3, preflight_timeout_seconds: 3, status_timeout_seconds: 2}}' \
    >"$SANDBOX/config.json"
}

# --- Fixtures ------------------------------------------------------------------
app="$HOME/Developer/app"   # a git root this machine owns
owned="$HOME/Developer/owned" # a plain root fakeworker owns
mkdir -p "$app/src" "$owned/sub/deeper"
git init -q "$app"
app="$(rw_physical_path "$app")"
owned="$(rw_physical_path "$owned")"

rel="$(rw_root_rel "$owned")"
oid="$(rw_root_id "$rel")"
rw_owned_record_write "$oid" "$(rw_record_new "$oid" "$rel" "$owned" plain fakeworker "/w/$rel" |
  jq -c '.owner = "worker" | .endpoints = ["e0000001"]')"

endpoint() { # id focus_path root_local worker_root root_rel [worker_home]
  rw_write_json_atomic "$(rw_endpoint_file "$1")" "$(jq -nc --arg id "$1" --arg f "$2" --arg rl "$3" \
    --arg wr "$4" --arg rr "$5" --arg wh "${6:-}" \
    '{endpoint_id: $id, root_rel: $rr, workspace: {focus_path: $f, root_local: $rl, worker_root: $wr}}
      + (if $wh == "" then {} else {worker_home: $wh} end)')"
}
endpoint e0000001 "$owned/sub" "$owned" "/w/$rel" "$rel"
endpoint e0000002 "$app" "" "" "" "/w"
endpoint e0000003 "$owned" "$owned" "/o/$rel" "$rel"

T=$'\t'
{
  # %1 local, laptop-owned root
  echo "pane_id=%1${T}pane_current_path=$app/src${T}pane_current_command=zsh${T}session_name=dev${T}window_index=1${T}pane_index=0"
  # %2 local, frozen copy of the worker-owned root
  echo "pane_id=%2${T}pane_current_path=$owned/sub${T}pane_current_command=zsh"
  # %3 remote on the owner; its live worker cwd is deeper than the endpoint
  echo "pane_id=%3${T}pane_current_path=$owned/sub${T}pane_current_command=bash${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000001${T}@rw-root-id=$oid${T}pane_title=/w/$rel/sub/deeper"
  # %4 remote visit on fakeworker in the laptop-owned root (worker home /w)
  echo "pane_id=%4${T}pane_current_path=$app${T}pane_current_command=bash${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000002${T}pane_title=/w/Developer/app/src"
  # %5 remote visit on the non-owner worker, with an agent mirrored on it
  echo "pane_id=%5${T}pane_current_path=$owned${T}pane_current_command=bash${T}@remote-host=other${T}@rw-worker=other${T}@rw-endpoint=e0000003${T}pane_title=zsh${T}@agent_kind=claude"
  # %6 local agent in the frozen copy (its pid alive)
  echo "pane_id=%6${T}pane_current_path=$owned${T}pane_current_command=claude${T}@agent_kind=claude${T}@agent_pid=$$"
  # %7 local nvim in the laptop-owned root
  echo "pane_id=%7${T}pane_current_path=$app${T}pane_current_command=nvim${T}session_name=dev${T}window_index=2${T}pane_index=1"
} >"$FAKE_TMUX_PANES"

# --- Stand-ins for roots.sh's I2 / I3 (fix wave B) --------------------------------
# The picker sources this file after roots.sh (RW_PICKER_STUBS), so these
# tests pin the picker against the interfaces' contracts, not against one
# implementation of them. Output shapes are the pinned ones.
cat >"$SANDBOX/stubs.sh" <<'EOF'
# I2 rw_owner_for_path <abs-path>: root_id<TAB>worker<TAB>root_local of the
# longest enclosing worker-owned root, a pending forget and another
# machine's mirror not counting; exit 1 when none.
rw_owner_for_path() {
  local p own out
  p="$(rw_physical_path "$1")"
  own="$(cat "$(rw_machine_id_file)" 2>/dev/null || true)"
  out="$(rw_owned_records_json | jq -r --arg p "$p" --arg own "$own" '
    [ .[] | select(.owner == "worker") | select((.pending.action // "") != "forget")
      | select((.focus_machine_id // "") == "" or .focus_machine_id == $own)
      | select(.root_local as $r | $p == $r or ($p | startswith($r + "/"))) ]
    | sort_by(.root_local | length) | last
    | if . == null then empty else [.root_id, .worker, .root_local] | @tsv end')"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
# I3 rw_pane_remote_probe <pane-id>: <dir mapped here><TAB><command>, one
# ssh killed at a HARD deadline (the status timeout): 6 on timeout or
# unreachable, 1 when not a remote pane.
rw_pane_remote_probe() {
  local pane="$1" ep host ej s out pid i=0 limit dir cmd
  ep="$(rw_pane_get "$pane" @rw-endpoint)"
  host="$(rw_pane_get "$pane" @remote-host)"
  [ -n "$ep" ] && [ -n "$host" ] && ej="$(rw_read_endpoint "$ep" 2>/dev/null)" || return 1
  printf '%s\n' "$pane" >>"${FAKE_PROBE_LOG:-/dev/null}"
  s="$(rw_session_name "$ep")"
  out="$(mktemp "${TMPDIR:-/tmp}/rw-probe.XXXXXX")"
  rw_ssh_batch "$host" "$(rw_ssh_status_timeout)" \
    "printf 'dir:%s\n' \"\$(tmux display-message -p -t '=$s:' '#{pane_current_path}')\"; printf 'cmd:%s\n' \"\$(tmux list-panes -t '=$s:' -F '#{pane_current_command}')\"" \
    </dev/null >"$out" 2>/dev/null &
  pid=$!
  limit=$(($(rw_ssh_status_timeout) * 10))
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt "$limit" ]; then
      pkill -P "$pid" 2>/dev/null
      kill "$pid" 2>/dev/null
      rm -f "$out"
      return 6
    fi
    sleep 0.1
  done
  wait "$pid" || { rm -f "$out"; return 6; }
  dir="$(sed -n 's/^dir://p' "$out")"
  cmd="$(sed -n 's/^cmd://p' "$out")"
  rm -f "$out"
  case "$dir" in /*) dir="$(rw_endpoint_local_path "$ej" "${dir%/}")" ;; *) dir="" ;; esac
  printf '%s\t%s\n' "$dir" "$cmd"
}
EOF
export RW_PICKER_STUBS="$SANDBOX/stubs.sh"
# lib.sh's fake ssh, except that the host named in $FAKE_SSH_HANG_HOST
# never answers (a connection that stalls after connecting).
cat >"$SANDBOX/bin/ssh-maybe-hang" <<'EOF'
#!/usr/bin/env bash
args=("$@")
host=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -p | -l | -i | -F | -J) shift 2 ;;
    -*) shift ;;
    *) host="$1"; break ;;
  esac
done
if [ -n "${FAKE_SSH_HANG_HOST:-}" ] && [ "$host" = "$FAKE_SSH_HANG_HOST" ]; then
  exec sleep 8
fi
exec "$(dirname "$0")/ssh" "${args[@]}"
EOF
chmod +x "$SANDBOX/bin/ssh-maybe-hang"
export RW_SSH_BIN="$SANDBOX/bin/ssh-maybe-hang"

# Machine rows: key<TAB>status<TAB>label<TAB>note.
keys() { bash "$PICKER" rows "$1" | cut -f1 | paste -sd, -; }
row() { bash "$PICKER" rows "$1" | awk -F '\t' -v k="$2" '$1 == k'; }
label() { row "$1" "$2" | cut -f3; }
status() { row "$1" "$2" | cut -f2; }
note() { row "$1" "$2" | cut -f4; }
# The ANSI colors out of what the picker prints (the stub fzf's input too).
strip() { sed $'s/\033\\[[0-9;]*m//g'; }
# The popup width the picker folds to (rw_pick_cols subtracts 4 for margins).
export RW_PICKER_COLS=80

# --- Rows: one worker ----------------------------------------------------------
one_worker
eq "1w local pane, laptop-owned: switch, then hand off to it" "$(keys %1)" "switch:fakeworker,handoff:fakeworker"
eq "1w local pane in a worker-owned root: owner, then hand back" "$(keys %2)" "switch:fakeworker,handback"
eq "1w remote pane on the owner: this machine, then hand back" "$(keys %3)" "switch:local,handback"
eq "1w remote visit pane, laptop-owned: this machine (owner), then hand off" "$(keys %4)" "switch:local,handoff:fakeworker"
eq "owner row is marked" "$(label %2 switch:fakeworker)" "switch this pane to fakeworker (owner)"
eq "this machine as owner is marked" "$(label %4 switch:local)" "switch this pane to this machine (owner)"
eq "this machine, not owner, unmarked" "$(label %3 switch:local)" "switch this pane to this machine"
eq "hand back names this machine, not the root" "$(label %3 handback)" "hand back to this machine"
eq "hand off names the worker and the pane count" "$(label %1 handoff:fakeworker)" "hand off to fakeworker (2 panes)"
eq "worker rows start pending" "$(status %1 switch:fakeworker)" "pending"
eq "hand-off rows start pending" "$(status %1 handoff:fakeworker)" "pending"
eq "this machine row has no status" "$(status %3 switch:local)" "none"
eq "hand back row has no status" "$(status %3 handback)" "none"
all_labels() { for p in %1 %2 %3 %4 %5 %6 %7; do bash "$PICKER" rows "$p" | cut -f3; done; }
labels_all="$(all_labels)"
check "no label embeds the root path" bash -c '! grep -q / <<<"$1"' _ "$labels_all"
check "no label is padded" bash -c '! grep -Eq "(^ | \$|  )" <<<"$1"' _ "$labels_all"

# --- Rows: two workers ---------------------------------------------------------
two_workers
eq "2w local pane, laptop-owned: both workers, then a hand-off row per worker" "$(keys %1)" "switch:fakeworker,switch:other,handoff:fakeworker,handoff:other"
eq "2w each hand-off row names its worker" "$(label %1 handoff:other)" "hand off to other (2 panes)"
eq "2w local pane in a worker-owned root: owner first" "$(keys %2)" "switch:fakeworker,switch:other,handback"
eq "2w remote pane on the owner: this machine, the other worker, hand back" "$(keys %3)" "switch:local,switch:other,handback"
eq "2w remote visit pane, laptop-owned: this machine first; its own worker's hand-off first" "$(keys %4)" "switch:local,switch:other,handoff:fakeworker,handoff:other"
eq "2w off-owner remote pane: owner first, then this machine, hand back" "$(keys %5)" "switch:fakeworker,switch:local,handback"

# --- Agent warning ---------------------------------------------------------------
W="⚠ agent would work on a non-owner copy"
eq "agent, switch to the owner: no warning" "$(note %5 switch:fakeworker)" ""
eq "agent, switch to a non-owner: warning" "$(note %5 switch:local)" "$W"
eq "local agent in a worker-owned root, to the owner: no warning" "$(note %6 switch:fakeworker)" ""
eq "local agent, to a non-owner worker: warning" "$(note %6 switch:other)" "$W"
eq "no agent, no warning" "$(note %2 switch:other)" ""
sed -i.bak "s/@agent_pid=$$/@agent_pid=999999/" "$FAKE_TMUX_PANES"
eq "a dead local agent pid is no agent" "$(note %6 switch:other)" ""

# --- Header ------------------------------------------------------------------------
hdr() { bash "$PICKER" header "$1" | strip; }
eq "header: local pane, subdirectory and root" "$(hdr %1 | head -n1)" "~/Developer/app/src  ·  root ~/Developer/app"
check "header: hosts line absent when pane host and owner are the same machine" bash -c "! bash '$PICKER' header %1 | grep -q 'pane on'"
eq "header: hosts line when a local pane is in a worker-owned root" "$(hdr %2 | sed -n 2p)" "pane on this machine  ·  owned by remote (fakeworker)"
eq "header: remote pane's live worker cwd mapped back" "$(hdr %3 | head -n1)" "~/Developer/owned/sub/deeper  ·  root ~/Developer/owned"
check "header: hosts line absent for a remote pane on its owner" bash -c "! bash '$PICKER' header %3 | grep -q 'pane on'"
eq "header: worker home mapping (visit endpoint)" "$(hdr %4 | head -n1)" "~/Developer/app/src  ·  root ~/Developer/app"
eq "header: hosts line, visit pane" "$(hdr %4 | sed -n 2p)" "pane on remote (fakeworker)  ·  owned by this machine"
eq "header: a non-path title falls back to the endpoint focus path" "$(hdr %5 | head -n1)" "~/Developer/owned (root)"
eq "header: hosts line, off-owner pane" "$(hdr %5 | sed -n 2p)" "pane on remote (other)  ·  owned by remote (fakeworker)"
check "header never says unsaved buffers or save first (local nvim)" bash -c "! bash '$PICKER' header %7 | grep -qi 'unsaved\|save first'"
check "header never names this machine's host name" bash -c "! bash '$PICKER' header %1 | grep -qi '$(hostname -s)'"

# The moves line: a hand-off row is offered and more than one pane moves.
eq "header: moves line names the panes a hand-off moves" "$(hdr %1 | sed -n 2p)" "moves: dev:1.0 zsh, dev:2.1 nvim"
check "header: no moves line for a hand-back" bash -c "! bash '$PICKER' header %3 | grep -q 'moves:'"

# Outside ~: soft switches only, with the reason in the header.
mkdir -p "$SANDBOX/outside"
echo "pane_id=%8${T}pane_current_path=$SANDBOX/outside${T}pane_current_command=zsh" >>"$FAKE_TMUX_PANES"
eq "outside ~: no hand off row" "$(keys %8)" "switch:fakeworker,switch:other"
check "outside ~: header says why" bash -c "bash '$PICKER' header %8 | grep -q 'cannot be handed off'"
YELLOW=$'\033[38;2;249;226;175m'
check "outside ~: the warning is yellow" bash -c "bash '$PICKER' header %8 | grep 'cannot be handed off' | grep -qF '$YELLOW'"
check "header: no unsaved-buffers wording outside ~ either" bash -c "! bash '$PICKER' header %8 | grep -qi 'unsaved\|save first'"

# --- Dispatch ---------------------------------------------------------------------
FZF_LOG="$SANDBOX/fzf.log"
RW_LOG="$SANDBOX/rw.log"
cat >"$SANDBOX/bin/fake-fzf" <<'EOF'
#!/usr/bin/env bash
# Picks the stdin line whose first field is $FAKE_FZF_KEY; exit 130 (esc)
# when that is empty. Logs its arguments and its input.
in="$(cat)"
{ printf 'ARGS'; printf ' %s' "$@"; printf '\n'; printf '%s\n' "$in" | sed 's/^/IN /'; } >>"$FAKE_FZF_LOG"
want="${FAKE_FZF_KEY:-}"
[ -n "$want" ] || exit 130
printf '%s\n' "$in" | awk -F '\t' -v k="$want" '$1 == k' | head -n1
EOF
cat >"$SANDBOX/bin/fake-rw" <<'EOF'
#!/usr/bin/env bash
printf '%s|TMUX_PANE=%s\n' "$*" "${TMUX_PANE:-}" >>"$FAKE_RW_LOG"
[ -n "${FAKE_RW_OUT:-}" ] && printf '%s\n' "$FAKE_RW_OUT"
exit "${FAKE_RW_EXIT:-0}"
EOF
chmod +x "$SANDBOX/bin/fake-fzf" "$SANDBOX/bin/fake-rw"
export RW_PICKER_FZF="$SANDBOX/bin/fake-fzf" RW_PICKER_RW_BIN="$SANDBOX/bin/fake-rw"
export FAKE_FZF_LOG="$FZF_LOG" FAKE_RW_LOG="$RW_LOG"

pick() { # pane key
  : >"$FZF_LOG"
  : >"$RW_LOG"
  FAKE_FZF_KEY="$2" TMUX_PANE=%99 bash "$PICKER" pick "$1" </dev/null >"$SANDBOX/pick.out" 2>&1
}
menus() { grep -c '^ARGS' "$FZF_LOG"; }

one_worker
pick %1 switch:fakeworker
eq "switch row runs rw switch with the resolved directory" "$(cat "$RW_LOG")" "switch --pane %1 --to fakeworker --dir $app/src|TMUX_PANE="
check "menu reloads in place with probe-rows" grep -q 'start:reload-sync:.*probe-rows' "$FZF_LOG"
check "menu shows from the label column on" grep -q -- '--with-nth=2..' "$FZF_LOG"
check "menu renders ANSI (the markers and warnings carry colors)" grep -q -- '--ansi' "$FZF_LOG"
check "menu header is the muted overlay grey, not the inherited red" grep -q -- '--color=header:#9399b2' "$FZF_LOG"
strip <"$FZF_LOG" >"$SANDBOX/fzf.stripped"
check "the popup's fzf input is the rendered rows (pending marker, label)" grep -q $'^IN switch:fakeworker\t… switch this pane to fakeworker$' "$SANDBOX/fzf.stripped"
check "the hand-off row is rendered the same way" grep -q $'^IN handoff:fakeworker\t… hand off to fakeworker (2 panes)$' "$SANDBOX/fzf.stripped"
check "the header reaches fzf without the unsaved-buffers wording" bash -c "! grep -qi 'unsaved\|save first' '$FZF_LOG'"

pick %3 switch:local
eq "remote pane to this machine: --to local, the mapped live directory" "$(cat "$RW_LOG")" "switch --pane %3 --to local --dir $owned/sub/deeper|TMUX_PANE="

pick %3 handback
eq "hand back row: rw bg handback with the labelled root, no y/n" "$(cat "$RW_LOG")" "bg handback --pane %3 --root $owned|TMUX_PANE="
pick %2 handback
eq "hand back from a local pane in the root" "$(cat "$RW_LOG")" "bg handback --pane %2 --root $owned|TMUX_PANE="

pick %1 handoff:fakeworker
eq "one worker: hand-off row runs rw bg handoff for it" "$(cat "$RW_LOG")" "bg handoff --worker fakeworker --pane %1 --root $app|TMUX_PANE="
eq "one worker: one menu only" "$(menus)" "1"

two_workers
pick %1 handoff:other
eq "two workers: the row names the worker (no chooser)" "$(cat "$RW_LOG")" "bg handoff --worker other --pane %1 --root $app|TMUX_PANE="
eq "two workers: one menu only, no second chooser" "$(menus)" "1"
endpoint e0000004 "$app" "" "" "" "/o"
echo "pane_id=%9${T}pane_current_path=$app${T}pane_current_command=bash${T}@remote-host=other${T}@rw-worker=other${T}@rw-endpoint=e0000004${T}pane_title=zsh" >>"$FAKE_TMUX_PANES"
eq "the pane's own worker's hand-off row comes first" "$(keys %9)" "switch:local,switch:fakeworker,handoff:other,handoff:fakeworker"
pick %9 handoff:other
eq "visit pane on the second worker hands off to it" "$(cat "$RW_LOG")" "bg handoff --worker other --pane %9 --root $app|TMUX_PANE="

pick %1 ""
eq "menu esc: nothing runs" "$(cat "$RW_LOG")" ""

export FAKE_RW_EXIT=7 FAKE_RW_OUT="rw: this pane runs 'top'; quit it first"
pick %1 switch:fakeworker
st=$?
eq "switch refusal: exit 7 passed through" "$st" "7"
check "switch refusal: shown inline with its reason" grep -q "rw switch refused" "$SANDBOX/pick.out"
check "switch refusal: the rw reason" grep -q "this pane runs 'top'; quit it first" "$SANDBOX/pick.out"
export FAKE_RW_EXIT=6 FAKE_RW_OUT="rw: fakeworker unreachable"
pick %1 switch:fakeworker
check "switch unreachable: dialog, pane unchanged" grep -q "fakeworker is unreachable over ssh; the pane is unchanged" "$SANDBOX/pick.out"
export FAKE_RW_EXIT=1 FAKE_RW_OUT="rw: resume of claude was not confirmed"
pick %1 switch:fakeworker
check "switch failure: dialog with rw's line" grep -q "cause:  resume of claude was not confirmed" "$SANDBOX/pick.out"
export FAKE_RW_EXIT=7 FAKE_RW_OUT="rw: ~/Developer/app is already being handed off"
pick %1 handoff:other
check "bg refusal: shown inline" grep -q "rw handoff not started" "$SANDBOX/pick.out"
unset FAKE_RW_EXIT FAKE_RW_OUT

# The picker runs nothing but switch and bg (CS5).
: >"$RW_LOG"
for p in %1 %2 %3 %4 %5; do
  for k in $(bash "$PICKER" rows "$p" | cut -f1); do
    FAKE_FZF_KEY="$k" bash "$PICKER" pick "$p" </dev/null >/dev/null 2>&1
  done
done
check "only rw switch / bg handoff / bg handback are ever run" bash -c "! grep -vE '^(switch --pane|bg handoff --worker|bg handback --pane) ' '$RW_LOG'"

# --- probe-rows -------------------------------------------------------------------
bash "$PICKER" rows %5 >"$SANDBOX/rows"
probed="$(bash "$PICKER" probe-rows "$SANDBOX/rows" --raw)"
eq "probe-rows keeps the order" "$(printf '%s\n' "$probed" | cut -f1 | paste -sd, -)" "$(cut -f1 "$SANDBOX/rows" | paste -sd, -)"
eq "probe-rows: reachable worker online" "$(printf '%s\n' "$probed" | awk -F '\t' '$1 == "switch:fakeworker" { print $2 }')" "online"
eq "probe-rows: this machine and hand back stay none" "$(printf '%s\n' "$probed" | awk -F '\t' '$1 == "switch:local" || $1 == "handback" { print $2 }' | paste -sd, -)" "none,none"
eq "probe-rows keeps the label" "$(printf '%s\n' "$probed" | awk -F '\t' '$1 == "switch:fakeworker" { print $3 }')" "$(awk -F '\t' '$1 == "switch:fakeworker" { print $3 }' "$SANDBOX/rows")"
eq "probe-rows keeps the note" "$(printf '%s\n' "$probed" | awk -F '\t' '$1 == "switch:local" { print $4 }')" "$W"
touch "$FAKE_SSH_DOWN"
eq "probe-rows: unreachable worker offline" "$(bash "$PICKER" probe-rows "$SANDBOX/rows" --raw | awk -F '\t' '$1 == "switch:fakeworker" { print $2 }')" "offline"
rm -f "$FAKE_SSH_DOWN"

# The same worker's switch row and hand-off row share one probe.
bash "$PICKER" rows %1 >"$SANDBOX/rows1"
: >"$FAKE_SSH_LOG"
probed="$(bash "$PICKER" probe-rows "$SANDBOX/rows1" --raw)"
eq "probe-rows: switch and hand-off rows of a worker get its status" "$(printf '%s\n' "$probed" | awk -F '\t' '$1 ~ /fakeworker/ { print $1 "=" $2 }' | paste -sd, -)" "switch:fakeworker=online,handoff:fakeworker=online"
eq "probe-rows: one ssh per worker, not per row" "$(grep -c '^fakeworker' "$FAKE_SSH_LOG")" "1"
eq "probe-rows: the other worker is probed once too" "$(grep -c '^other' "$FAKE_SSH_LOG")" "1"
touch "$FAKE_SSH_DOWN"
eq "probe-rows: both of an offline worker's rows go offline" "$(bash "$PICKER" probe-rows "$SANDBOX/rows1" --raw | awk -F '\t' '$1 ~ /other/ { print $2 }' | paste -sd, -)" "offline,offline"
rm -f "$FAKE_SSH_DOWN"

# render: the marker leads the row, with its color; fzf is given --ansi.
GREEN=$'\033[38;2;166;227;161m' RED=$'\033[38;2;243;139;168m' GREY=$'\033[38;2;108;112;134m'
rendered="$(printf 'switch:a\tonline\tswitch this pane to a\t\nswitch:b\toffline\tswitch this pane to b\t%s\nswitch:c\tpending\tswitch this pane to c\t\nswitch:local\tnone\tswitch this pane to this machine\t\n' "$W" | bash "$PICKER" render)"
check "render: online is a green dot" bash -c 'grep -qF "$1" <<<"$2"' _ "switch:a	${GREEN}●" "$rendered"
check "render: offline is a red ring" bash -c 'grep -qF "$1" <<<"$2"' _ "switch:b	${RED}○" "$rendered"
check "render: pending is a grey ellipsis" bash -c 'grep -qF "$1" <<<"$2"' _ "switch:c	${GREY}…" "$rendered"
eq "render: no marker, two spaces" "$(printf '%s\n' "$rendered" | strip | awk -F '\t' '$1 == "switch:local" { print $2 }')" "  switch this pane to this machine"
eq "render: marker, label, note after it" "$(printf '%s\n' "$rendered" | strip | awk -F '\t' '$1 == "switch:b" { print $2 }')" "○ switch this pane to b  $W"
eq "render: probe-rows output is rendered" "$(bash "$PICKER" probe-rows "$SANDBOX/rows1" | strip | awk -F '\t' '$1 == "handoff:fakeworker" { print $2 }')" "● hand off to fakeworker (2 panes)"

# --- Fix wave B ---------------------------------------------------------------------
record() { # root_local worker [jq filter] -- a worker-owned record; prints its id
  local r i
  r="$(rw_root_rel "$1")"
  i="$(rw_root_id "$r")"
  rw_owned_record_write "$i" "$(rw_record_new "$i" "$r" "$1" plain "$2" "/w/$r" |
    jq -c ".owner = \"worker\" | ${3:-.}")"
  printf '%s\n' "$i"
}
hand() { bash "$PICKER" rows "$1" | awk -F '\t' '$1 == "handback" || $1 ~ /^handoff:/ { print $3 }'; }

# B1: the transfer row runs on the root its label names (--root), also for
# a pane whose live directory left the root it was opened in.
one_worker
owned2="$HOME/Developer/owned2"
lib="$HOME/Developer/lib"
mkdir -p "$owned2/x" "$lib"
git init -q "$lib"
owned2="$(rw_physical_path "$owned2")"
lib="$(rw_physical_path "$lib")"
record "$owned2" fakeworker '.endpoints = ["e0000010"]' >/dev/null
endpoint e0000011 "$owned" "$owned" "/w/$rel" "$rel"
# %20: remote on fakeworker, opened in ~/Developer/owned (bound to it), its
# title still there; the worker shell has since cd'd into owned2/x.
echo "pane_id=%20${T}pane_current_path=$owned${T}pane_current_command=bash${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000011${T}@rw-root-id=$oid${T}pane_title=/w/$rel" >>"$FAKE_TMUX_PANES"
export FAKE_REMOTE_CWD="/w/Developer/owned2/x"
eq "B1 remote pane cd'd into another root: the header names that root" "$(hdr %20 | head -n1)" "~/Developer/owned2/x  ·  root ~/Developer/owned2"
eq "B1 ... the row says hand back" "$(hand %20)" "hand back to this machine"
pick %20 handback
eq "B1 ... and the hand-back runs on it, not on the pane's @rw-root-id" "$(cat "$RW_LOG")" "bg handback --pane %20 --root $owned2|TMUX_PANE="
# The reviewer's repro: no live answer, only the title says owned2.
unset FAKE_REMOTE_CWD
sed -i.bak "s|^\(pane_id=%20${T}.*pane_title=\).*|\1/w/Developer/owned2|" "$FAKE_TMUX_PANES"
pick %20 handback
eq "B1 title-only: hand-back runs on the titled root" "$(cat "$RW_LOG")" "bg handback --pane %20 --root $owned2|TMUX_PANE="
# %4: visit pane opened in ~/Developer/app (laptop-owned), now in ~/Developer/lib.
export FAKE_REMOTE_CWD="/w/Developer/lib"
eq "B1 visit pane cd'd elsewhere: the header names the new root" "$(hdr %4 | head -n1)" "~/Developer/lib (root)"
eq "B1 ... the row names the worker" "$(hand %4)" "hand off to fakeworker"
pick %4 handoff:fakeworker
eq "B1 ... and the hand-off runs on it, not on the pane's local cwd" "$(cat "$RW_LOG")" "bg handoff --worker fakeworker --pane %4 --root $lib|TMUX_PANE="
# A directory only the worker has: the enclosing root that exists here.
export FAKE_REMOTE_CWD="/w/Developer/app/newsub"
eq "B1 worker-only subdirectory of a git root: header names the existing root" "$(hdr %4 | head -n1)" "~/Developer/app/newsub  ·  root ~/Developer/app"
pick %4 handoff:fakeworker
eq "B1 ... and the hand-off runs on that root" "$(cat "$RW_LOG")" "bg handoff --worker fakeworker --pane %4 --root $app|TMUX_PANE="
export FAKE_REMOTE_CWD="/w/Developer/onlyremote"
eq "B1 worker-only directory, no enclosing root here: no hand-off row" "$(keys %4)" "switch:local"
eq "B1 ... header: no root on this machine" "$(hdr %4 | head -n1)" "~/Developer/onlyremote  ·  no root on this machine"
check "B1 ... header says why" bash -c "bash '$PICKER' header %4 | grep -q 'exists only on remote (fakeworker): nothing on this machine to hand off'"
export FAKE_REMOTE_CWD="/w/$rel/newdir"
eq "B1 worker-only directory in a worker-owned root: hand back that root" "$(hand %3)" "hand back to this machine"
eq "B1 ... header names the root" "$(hdr %3 | head -n1)" "~/Developer/owned/newdir  ·  root ~/Developer/owned"
export FAKE_REMOTE_CWD="/w/$rel/sub"
eq "B1 the live worker cwd wins over a lagging title" "$(hdr %3 | head -n1)" "~/Developer/owned/sub  ·  root ~/Developer/owned"
unset FAKE_REMOTE_CWD

# B2: a remote that does not answer. The probe has a hard deadline; the menu
# falls back to the title, says so, offers no soft switch, offers release.
export FAKE_PROBE_LOG="$SANDBOX/probe.log"
touch "$FAKE_SSH_DOWN"
eq "B2 unreachable owner pane: release only (a hand-back needs that remote)" "$(keys %3)" "release"
eq "B2 release label" "$(label %3 release)" "release this pane to this machine (remote unreachable)"
eq "B2 header: title-based directory" "$(hdr %3 | head -n1)" "~/Developer/owned/sub/deeper  ·  root ~/Developer/owned"
eq "B2 header: remote unreachable" "$(hdr %3 | sed -n 2p)" "pane on remote (fakeworker), remote unreachable  ·  owned by remote (fakeworker)"
eq "B2 header: the warning line is yellow" "$(bash "$PICKER" header %3 | sed -n 3p)" "${YELLOW}the directory is the last one it reported; switching needs the remote, releasing does not"$'\033[0m'
eq "B2 header: the grey header color is not overridden per line (plain line 1)" "$(bash "$PICKER" header %3 | sed -n 1p)" "~/Developer/owned/sub/deeper  ·  root ~/Developer/owned"
pick %3 release
eq "B2 release runs rw switch --to local --force" "$(cat "$RW_LOG")" "switch --pane %3 --to local --force|TMUX_PANE="
eq "B2 visit pane, its only worker unreachable: release only" "$(keys %4)" "release"
two_workers
eq "B2 visit pane, another worker configured: release, then hand off to the other" "$(keys %4)" "release,handoff:other"
rm -f "$FAKE_SSH_DOWN"
# A hanging ssh (connects, never answers): the menu opens within the deadline.
jq '.ssh.status_timeout_seconds = 1' "$SANDBOX/config.json" >"$SANDBOX/c.json" && mv "$SANDBOX/c.json" "$SANDBOX/config.json"
# The endpoint names its worker, as rw writes it (any lookup that ssh-es to
# the endpoint's worker meets the hang too).
rw_write_json_atomic "$(rw_endpoint_file e0000001)" "$(jq -c '.worker = "fakeworker"' "$(rw_endpoint_file e0000001)")"
export FAKE_SSH_HANG_HOST=fakeworker
t0=$(date +%s)
pick %3 ""
t1=$(date +%s)
check "B2 hanging ssh: the menu opens within the deadline (took $((t1 - t0)) s, ssh hangs 8 s)" test $((t1 - t0)) -le 3
eq "B2 hanging ssh: the menu was shown" "$(menus)" "1"
check "B2 hanging ssh: it offers release" grep -q $'^IN release\t' "$FZF_LOG"
check "B2 hanging ssh: no soft-switch row" bash -c "! grep -q '^IN switch:' '$FZF_LOG'"
# The pane's own remote hangs, the owner answers: hand back is still offered.
export FAKE_SSH_HANG_HOST=other
eq "B2 off-owner pane, its remote hangs: release, then hand back" "$(keys %5)" "release,handback"
pick %5 handback
eq "B2 ... hand back runs on the root" "$(cat "$RW_LOG")" "bg handback --pane %5 --root $owned|TMUX_PANE="
unset FAKE_SSH_HANG_HOST
# A pane whose remote left config.json: release, and no ssh to it at all.
one_worker
: >"$FAKE_PROBE_LOG"
: >"$FAKE_SSH_LOG"
eq "B2 remote not in config.json: release, then hand back" "$(keys %5)" "release,handback"
eq "B2 ... release label" "$(label %5 release)" "release this pane to this machine (remote not in config.json)"
eq "B2 ... never probed" "$(grep -c . "$FAKE_PROBE_LOG")" "0"
check "B2 ... no ssh to it" bash -c "! grep -q '^other' '$FAKE_SSH_LOG'"

# B3: the owner is the chip's owner (I2): a pending forget and another
# machine's mirror leave the directory owned by this machine.
forgot="$HOME/Developer/forgot"
held="$HOME/Developer/held"
mkdir -p "$forgot" "$held"
forgot="$(rw_physical_path "$forgot")"
held="$(rw_physical_path "$held")"
record "$forgot" fakeworker '.pending = {action: "forget", reason: "x", at: "now"}' >/dev/null
record "$held" fakeworker '.focus_machine_id = "another-machine"' >/dev/null
echo "pane_id=%21${T}pane_current_path=$forgot${T}pane_current_command=zsh" >>"$FAKE_TMUX_PANES"
echo "pane_id=%22${T}pane_current_path=$held${T}pane_current_command=zsh" >>"$FAKE_TMUX_PANES"
eq "B3 pending forget: owned by this machine (no hosts line)" "$(hdr %21)" "~/Developer/forgot (root)"
eq "B3 pending forget: soft switch, then hand off" "$(keys %21)" "switch:fakeworker,handoff:fakeworker"
eq "B3 another machine's mirror: owned by this machine (no hosts line)" "$(hdr %22)" "~/Developer/held (root)"

# B4 (revised 2026-11-20): an editor in a REMOTE pane gets no unsaved-buffers
# line either; another change makes unsaved buffers travel.
export FAKE_TMUX_REMOTE_CMD=nvim
check "B4 remote nvim: no unsaved-buffers line" bash -c "! bash '$PICKER' header %3 | grep -qi 'unsaved\|save first'"
unset FAKE_TMUX_REMOTE_CMD

# B5: "(N panes come back)" counts the record's endpoint panes only, not a
# visit pane on another worker that carries the root's @rw-root-id.
echo "pane_id=%23${T}pane_current_path=$owned${T}pane_current_command=bash${T}@remote-host=other${T}@rw-worker=other${T}@rw-endpoint=e0000012${T}@rw-root-id=$oid" >>"$FAKE_TMUX_PANES"
eq "B5 a visit pane (and %20, bound by @rw-root-id only) do not come back" "$(hand %3)" "hand back to this machine"
echo "pane_id=%24${T}pane_current_path=$owned${T}pane_current_command=bash${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000001" >>"$FAKE_TMUX_PANES"
eq "B5 a second endpoint pane does" "$(hand %3)" "hand back to this machine (2 panes)"

# A5: the moves line names the panes, folded to the popup width, with a
# pane's session:window.pane and command kept together.
foldroot="$HOME/Developer/foldroot"
mkdir -p "$foldroot"
git init -q "$foldroot"
foldroot="$(rw_physical_path "$foldroot")"
for i in 1 2 3 4 5 6 7 8; do
  echo "pane_id=%4$i${T}pane_current_path=$foldroot${T}pane_current_command=zsh${T}session_name=a-long-session-name${T}window_index=$i${T}pane_index=0" >>"$FAKE_TMUX_PANES"
done
folded="$(hdr %41)"
eq "A5 the moves line starts the folded list" "$(printf '%s\n' "$folded" | sed -n 2p | cut -c1-35)" "moves: a-long-session-name:1.0 zsh,"
check "A5 the list is folded (more than one line)" test "$(printf '%s\n' "$folded" | wc -l)" -gt 3
check "A5 no folded line is wider than the popup less its margin" bash -c '! printf "%s\n" "$1" | awk "length(\$0) > 76 { bad = 1 } END { exit !bad }"' _ "$folded"
check "A5 a continuation is indented under the first name" bash -c 'printf "%s\n" "$1" | sed -n 3p | grep -q "^       a-long"' _ "$folded"
eq "A5 every pane is named once" "$(printf '%s\n' "$folded" | grep -o 'a-long-session-name:[0-9]*\.0 zsh' | wc -l | tr -d ' ')" "8"
export RW_PICKER_COLS=400
eq "A5 a wide popup keeps the list on one line" "$(hdr %41 | grep -c .)" "2"
export RW_PICKER_COLS=80
two_workers
check "A5 the moves line appears with several workers too" bash -c "bash '$PICKER' header %41 | grep -q '^moves:'"
one_worker

# B7: pick acts on the pane it is given, never on an untargeted lookup.
: >"$FAKE_TMUX_LOG"
pick %4 switch:local
eq "B7 the given pane is the one switched" "$(cat "$RW_LOG")" "switch --pane %4 --to local --dir $app/src|TMUX_PANE="
check "B7 no display-message without a target" bash -c "! grep '^display-message' '$FAKE_TMUX_LOG' | grep -qvE -- ' -[[:alpha:]]*t '"

finish
