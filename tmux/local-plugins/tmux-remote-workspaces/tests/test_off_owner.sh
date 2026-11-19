#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Off-owner panes and the red host chip (docs/tasks/remote-owned-directories.md,
# "Pane host switching": S6, CS3):
#   - rw-refresh-indicators.sh --pane / --root / no argument compute
#     @rw-off-owner for local panes in a frozen root, visit-style remote
#     panes (a remote pane whose directory this machine owns), remote panes
#     on a non-owner worker and owner panes; a remote pane follows its
#     endpoint's directory, not its live cwd; a pending forget and a
#     worker-held copy are owned by this machine
#   - the zsh chpwd hook calls --pane "$TMUX_PANE" in the background, and
#     only while a record exists (plus once to clear)
#   - on a throwaway tmux server (TMUX_TMPDIR scratch, -L, -f /dev/null,
#     shells zsh -f): the plugin's wrap of @catppuccin_host_color is
#     idempotent, and the host chip's format renders red for the focused
#     off-owner pane and the normal colour otherwise (also through the real
#     pinned catppuccin-tmux when it is installed)

set -uo pipefail
REAL_TMUX="$(command -v tmux || true)"
REAL_HOME="$HOME"
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

REFRESH="$RW_PLUGIN/scripts/rw-refresh-indicators.sh"
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"

app="$HOME/Developer/app"
owned="$HOME/Developer/owned"
forgot="$HOME/Developer/forgot"
held="$HOME/Developer/held"
mkdir -p "$app/src" "$owned/sub" "$forgot" "$held"
app="$(rw_physical_path "$app")"
owned="$(rw_physical_path "$owned")"
forgot="$(rw_physical_path "$forgot")"
held="$(rw_physical_path "$held")"

record() { # root_local owner-worker [jq filter]
  local rel id
  rel="$(rw_root_rel "$1")"
  id="$(rw_root_id "$rel")"
  rw_owned_record_write "$id" "$(rw_record_new "$id" "$rel" "$1" plain "$2" "/w/$rel" |
    jq -c ".owner = \"worker\" | ${3:-.}")"
  printf '%s\n' "$id"
}
oid="$(record "$owned" fakeworker)"
record "$forgot" fakeworker '.pending = {action: "forget", reason: "x", at: "now"}' >/dev/null
# A worker-held copy's mirror (written by another focus machine).
record "$held" fakeworker '.focus_machine_id = "another-machine"' >/dev/null

endpoint() { # id focus_path
  rw_write_json_atomic "$(rw_endpoint_file "$1")" \
    "$(jq -nc --arg id "$1" --arg f "$2" '{endpoint_id: $id, workspace: {focus_path: $f}}')"
}
endpoint e0000001 "$owned/sub"
endpoint e0000002 "$app"
endpoint e0000003 "$owned"

T=$'\t'
{
  echo "pane_id=%1${T}pane_current_path=$app/src${T}pane_pid=900001"
  echo "pane_id=%2${T}pane_current_path=$owned/sub${T}pane_pid=900002"
  # owner pane: remote on fakeworker, in the root fakeworker owns
  echo "pane_id=%3${T}pane_current_path=$owned/sub${T}pane_pid=900003${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000001"
  # visit-style: remote on fakeworker, directory owned by this machine
  echo "pane_id=%4${T}pane_current_path=$app${T}pane_pid=900004${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000002"
  # remote on a worker that does not own the root
  echo "pane_id=%5${T}pane_current_path=$owned${T}pane_pid=900005${T}@remote-host=other${T}@rw-worker=other${T}@rw-endpoint=e0000003"
  # remote owner pane whose local cwd says nothing about its endpoint
  echo "pane_id=%6${T}pane_current_path=$app${T}pane_pid=900006${T}@remote-host=fakeworker${T}@rw-worker=fakeworker${T}@rw-endpoint=e0000001"
  echo "pane_id=%7${T}pane_current_path=$forgot${T}pane_pid=900007"
  echo "pane_id=%8${T}pane_current_path=$held${T}pane_pid=900008"
  echo "pane_id=%9${T}pane_current_path=$owned${T}pane_pid=900009"
} >"$FAKE_TMUX_PANES"

flag_of() { # pane: 1 or "" (unset)
  local v
  v="$(tr '\t' '\n' <<<"$(grep -E "^pane_id=$1(	|$)" "$FAKE_TMUX_PANES")" | sed -n 's/^@rw-off-owner=//p')"
  printf '%s' "$v"
}

# --- --pane ----------------------------------------------------------------------
for p in 1 2 3 4 5 6 7 8 9; do bash "$REFRESH" --pane "%$p"; done
eq "--pane: local pane, laptop-owned dir: not off-owner" "$(flag_of %1)" ""
eq "--pane: local pane in a worker-owned root (frozen copy): off-owner" "$(flag_of %2)" "1"
eq "--pane: remote pane on the owner: not off-owner" "$(flag_of %3)" ""
eq "--pane: visit-style remote pane in a laptop-owned dir: off-owner" "$(flag_of %4)" "1"
eq "--pane: remote pane on a non-owner worker: off-owner" "$(flag_of %5)" "1"
eq "--pane: remote pane follows its endpoint's dir, not the local cwd" "$(flag_of %6)" ""
eq "--pane: a pending forget no longer counts as remote-owned" "$(flag_of %7)" ""
eq "--pane: a worker-held copy is owned by this machine" "$(flag_of %8)" ""
eq "--pane: root itself (not only below it)" "$(flag_of %9)" "1"

# A cd out of the frozen root clears it.
sed -i.bak "s|^pane_id=%2${T}pane_current_path=[^${T}]*|pane_id=%2${T}pane_current_path=$app|" "$FAKE_TMUX_PANES"
bash "$REFRESH" --pane %2
eq "--pane: after a cd out of the root, cleared" "$(flag_of %2)" ""
bash "$REFRESH" --pane %404
check "--pane: an unknown pane is a no-op" test "$?" = 0

# --- --root ------------------------------------------------------------------------
# Stale flags everywhere; --root <owned> touches only panes whose dir is in it.
for p in 1 2 3 4 5 9; do tmux set-option -pqt "%$p" @rw-off-owner 1; done
tmux set-option -pqut %5 @rw-off-owner
bash "$REFRESH" --root "$owned"
eq "--root: a pane outside the root is untouched" "$(flag_of %1)" "1"
eq "--root: a moved-out pane is untouched" "$(flag_of %2)" "1"
eq "--root: owner pane in the root recomputed" "$(flag_of %3)" ""
eq "--root: visit pane in another root untouched" "$(flag_of %4)" "1"
eq "--root: non-owner remote pane in the root recomputed" "$(flag_of %5)" "1"
eq "--root: local pane in the root recomputed" "$(flag_of %9)" "1"

# After a hand-back the record is gone: --root clears its panes.
rm -rf "$(rw_owned_record_dir "$oid")"
bash "$REFRESH" --root "$owned"
eq "--root after hand-back: the frozen pane is no longer off-owner" "$(flag_of %9)" ""
eq "--root after hand-back: a remote pane in it now is" "$(flag_of %3)" "1"
oid="$(record "$owned" fakeworker)"

# --- no argument ---------------------------------------------------------------------
# @remote-host is recomputed from the process tree first: %3 and %5 run an
# attach loop, %4 and %6 do not (stale intent), so they are local now.
printf '%s\n' "910003 900003 bash $RW_PLUGIN/scripts/attach-loop.sh e0000001" \
  "910005 900005 bash $RW_PLUGIN/scripts/attach-loop.sh e0000003" >"$SANDBOX/ps-extra"
export FAKE_PS_EXTRA="$SANDBOX/ps-extra"
for p in 1 2 3 4 5 6 7 8 9; do tmux set-option -pqt "%$p" @rw-off-owner 1; done
bash "$REFRESH"
eq "all: local pane, laptop-owned" "$(flag_of %1)" ""
eq "all: owner pane with a live attach loop" "$(flag_of %3)" ""
eq "all: non-owner remote pane with a live attach loop" "$(flag_of %5)" "1"
eq "all: a pane without its attach loop is local again (laptop dir)" "$(flag_of %4)" ""
eq "all: a pane without its attach loop is local again (its cwd)" "$(flag_of %6)" ""
eq "all: frozen-copy local pane" "$(flag_of %9)" "1"
eq "all: @remote-host dropped where no attach loop runs" "$(grep -E '^pane_id=%4	' "$FAKE_TMUX_PANES" | tr '\t' '\n' | sed -n 's/^@remote-host=//p')" ""
unset FAKE_PS_EXTRA

check "unknown argument is a usage error" bash -c "! bash '$REFRESH' --nope 2>/dev/null"

# --- zsh chpwd hook ----------------------------------------------------------------
ZSHRC="$RW_PLUGIN/../../../zsh/.zshrc"
if command -v zsh >/dev/null 2>&1 && [ -f "$ZSHRC" ]; then
  # The hook block only: from the frozen-root warning to its startup calls.
  sed -n '/^_rw_remote_root_warn() {/,/^_rw_off_owner_refresh$/p' "$ZSHRC" >"$SANDBOX/hook.zsh"
  cat >"$SANDBOX/bin/fake-refresh" <<'EOF'
#!/bin/sh
echo "$*" >>"$HOOK_LOG"
EOF
  chmod +x "$SANDBOX/bin/fake-refresh"
  export HOOK_LOG="$SANDBOX/hook.log"
  : >"$HOOK_LOG"
  zsh_run() { # commands after the hook is loaded
    TMUX=/fake/socket,1,0 TMUX_PANE=%42 RW_REFRESH_INDICATORS="$SANDBOX/bin/fake-refresh" \
      zsh -f -c "source '$SANDBOX/hook.zsh' >/dev/null; $1; wait" 2>&1
  }
  zsh_run "cd '$owned/sub'; cd '$app'" >/dev/null
  wait_for 3 bash -c "[ \$(grep -c . '$HOOK_LOG') -ge 3 ]"
  eq "hook: startup and each cd call --pane \$TMUX_PANE" "$(sort -u "$HOOK_LOG")" "--pane %42"
  eq "hook: once at startup, once per cd" "$(grep -c . "$HOOK_LOG")" "3"
  : >"$HOOK_LOG"
  TMUX='' TMUX_PANE='' RW_REFRESH_INDICATORS="$SANDBOX/bin/fake-refresh" \
    zsh -f -c "source '$SANDBOX/hook.zsh' >/dev/null; cd '$owned'" >/dev/null 2>&1
  sleep 0.3
  eq "hook: outside tmux, nothing runs" "$(grep -c . "$HOOK_LOG")" "0"
  # No records: nothing runs, except once to clear after the last one went.
  mv "$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned" "$SANDBOX/owned.away"
  : >"$HOOK_LOG"
  zsh_run "cd '$app'; cd '$owned'" >/dev/null
  sleep 0.3
  eq "hook: no records, no call" "$(grep -c . "$HOOK_LOG")" "0"
  mv "$SANDBOX/owned.away" "$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned"
  : >"$HOOK_LOG"
  zsh_run "mv '$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned' '$SANDBOX/owned.away'; cd '$app'; cd '$owned'" >/dev/null
  wait_for 3 bash -c "[ \$(grep -c . '$HOOK_LOG') -ge 2 ]"
  sleep 0.3
  eq "hook: the last record gone, one clearing call, then none" "$(grep -c . "$HOOK_LOG")" "2"
  mv "$SANDBOX/owned.away" "$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned"
  # cd stays fast: the call is detached.
  cat >"$SANDBOX/bin/slow-refresh" <<'EOF'
#!/bin/sh
sleep 3
EOF
  chmod +x "$SANDBOX/bin/slow-refresh"
  t0=$(date +%s)
  TMUX=/fake/socket,1,0 TMUX_PANE=%42 RW_REFRESH_INDICATORS="$SANDBOX/bin/slow-refresh" \
    zsh -f -c "source '$SANDBOX/hook.zsh' >/dev/null; cd '$app'" >/dev/null 2>&1
  t1=$(date +%s)
  check "hook: cd does not wait for the refresh" test $((t1 - t0)) -lt 2
else
  ok "hook: skipped (no zsh or no zsh/.zshrc)"
fi

# --- Chip on a throwaway tmux server ---------------------------------------------------
if [ -z "$REAL_TMUX" ]; then
  ok "chip: skipped (no tmux)"
  finish
  exit $?
fi
# A short TMUX_TMPDIR: the socket path must fit in sun_path (104 bytes).
TT="$(mktemp -d /tmp/rwt.XXXXXX)"
SOCK="rw-x2-test-$$"
mkdir -p "$SANDBOX/realbin"
cat >"$SANDBOX/realbin/tmux" <<EOF
#!/bin/sh
exec '$REAL_TMUX' -L '$SOCK' "\$@"
EOF
chmod +x "$SANDBOX/realbin/tmux"
rt() { TMUX_TMPDIR="$TT" PATH="$SANDBOX/realbin:$PATH" "$@"; }
cleanup_server() {
  rt tmux kill-server >/dev/null 2>&1
  rm -rf "$TT"
}
# shellcheck disable=SC2064 # expand now
trap "cleanup_server; rm -rf '$SANDBOX' 2>/dev/null || { sleep 1; rm -rf '$SANDBOX'; }" EXIT

rt tmux -f /dev/null new-session -d -s chip -x 160 -y 40 -c "$owned/sub" 'zsh -f'
rt tmux split-window -t chip -c "$app" 'zsh -f'
pa="$(rt tmux list-panes -t chip -F '#{pane_id}' | head -n1)"
pb="$(rt tmux list-panes -t chip -F '#{pane_id}' | tail -n1)"
wait_for 5 bash -c "[ \"\$(TMUX_TMPDIR='$TT' '$SANDBOX/realbin/tmux' display -p -t '$pb' '#{pane_current_path}')\" = '$app' ]"

# What host_indicator.sh leaves before the plugin loads, then the plugin
# (twice: a config reload must not nest the wrap).
rt tmux set -g @catppuccin_host_color '#89b4fa'
rt tmux set -g @catppuccin_host_text 'host'
rt bash "$RW_PLUGIN/tmux-remote-workspaces.tmux"
rt bash "$RW_PLUGIN/tmux-remote-workspaces.tmux"
color="$(rt tmux show -gv @catppuccin_host_color)"
eq "chip: colour wrapped once" "$color" '#{?@rw-off-owner,#f38ba8,#89b4fa}'

# The flag comes from the real script on the real server.
rt bash "$REFRESH" --pane "$pa"
rt bash "$REFRESH" --pane "$pb"
eq "chip: frozen-root pane flagged on the server" "$(rt tmux show -pqv -t "$pa" @rw-off-owner)" "1"
eq "chip: laptop-owned pane not flagged" "$(rt tmux show -pqv -t "$pb" @rw-off-owner)" ""

# The host module exactly as the pinned catppuccin-tmux builds it
# (build_status_module, status_fill icon): the colour spliced raw into the
# separator fg and the icon bg.
module="#[fg=${color},bg=#1e1e2e,nobold,nounderscore,noitalics]L#[fg=#1e1e2e,bg=${color},nobold,nounderscore,noitalics]I #[fg=#cdd6f4,bg=#313244] host"
red="$(rt tmux display-message -p -t "$pa" "$module")"
norm="$(rt tmux display-message -p -t "$pb" "$module")"
eq "chip: off-owner pane renders red" "$red" "#[fg=#f38ba8,bg=#1e1e2e,nobold,nounderscore,noitalics]L#[fg=#1e1e2e,bg=#f38ba8,nobold,nounderscore,noitalics]I #[fg=#cdd6f4,bg=#313244] host"
eq "chip: owner pane keeps its colour" "$norm" "#[fg=#89b4fa,bg=#1e1e2e,nobold,nounderscore,noitalics]L#[fg=#1e1e2e,bg=#89b4fa,nobold,nounderscore,noitalics]I #[fg=#cdd6f4,bg=#313244] host"
rt tmux select-pane -t "$pa"
check "chip: untargeted (the focused pane) renders red" bash -c "TMUX_TMPDIR='$TT' '$SANDBOX/realbin/tmux' display -p '$module' | grep -q 'bg=#f38ba8'"
rt tmux select-pane -t "$pb"
check "chip: focus moves to an owner pane, normal colour" bash -c "! TMUX_TMPDIR='$TT' '$SANDBOX/realbin/tmux' display -p '$module' | grep -q 'f38ba8'"

# The real pinned theme, when installed: run it against this server and
# render its status-right.
CAT="$REAL_HOME/.config/tmux/plugins/catppuccin-tmux/catppuccin.tmux"
if [ -f "$CAT" ]; then
  rt tmux set -g @catppuccin_status_modules_right 'host'
  rt tmux set -g @catppuccin_status_fill icon
  rt tmux set -g @catppuccin_status_connect_separator no
  rt bash "$CAT" >/dev/null 2>&1
  sr="$(rt tmux show -gv status-right)"
  case "$sr" in *'@rw-off-owner'*) ok "catppuccin: status-right carries the conditional" ;; *) bad "catppuccin: status-right carries the conditional" ;; esac
  case "$(rt tmux display-message -p -t "$pa" "$sr")" in
    *'bg=#f38ba8'*) ok "catppuccin: off-owner pane's chip is red" ;;
    *) bad "catppuccin: off-owner pane's chip is red" ;;
  esac
  case "$(rt tmux display-message -p -t "$pb" "$sr")" in
    *'bg=#f38ba8'*) bad "catppuccin: owner pane's chip is the host colour" ;;
    *'bg=#89b4fa'*) ok "catppuccin: owner pane's chip is the host colour" ;;
    *) bad "catppuccin: owner pane's chip is the host colour" ;;
  esac
else
  ok "catppuccin: skipped (pinned theme not installed)"
fi

finish
