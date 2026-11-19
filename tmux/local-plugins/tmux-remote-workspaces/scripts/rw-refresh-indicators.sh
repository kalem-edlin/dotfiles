#!/usr/bin/env bash
# Reconcile display-only metadata with what is really running.
#
#   (no args)      every pane's @remote-host / @workspace-resurrect-skip and
#                  @rw-off-owner, then the transfer options below (plugin
#                  load, and after a restore)
#   --pane <id>    only that pane's @rw-off-owner (the zsh chpwd hook, the
#                  attach loop, rw switch / open)
#   --root <path>  @rw-off-owner of every pane whose directory is <path> or
#                  inside it (rw handoff / handback, after an ownership
#                  change)
#   --transfers    only the background-transfer options (libexec/rw-bg calls
#                  this when a transfer starts and when it ends)
#
# Panes: endpoint intent may outlive or precede attachment; host/directory
# chips and workspace-resurrect skipping must only activate while
# attach-loop.sh really owns the local pane's process tree.
#
# Off-owner (docs/tasks/remote-owned-directories.md, S6 / CS3): the pane
# option @rw-off-owner is 1 while the pane's host differs from the owner
# host of the pane's directory, and unset otherwise. This script is its only
# writer. The host chip turns red on it (tmux-remote-workspaces.tmux wraps
# @catppuccin_host_color).
#   pane host   @remote-host (the worker its attach loop runs on), else this
#               machine
#   directory   a remote pane: its endpoint's directory (workspace.focus_path,
#               the laptop-side path it was opened in), never later cds on
#               the worker; a local pane: pane_current_path
#   owner host  the worker of the worker-owned record enclosing the
#               directory (longest root_local match, as
#               rw_owned_root_for_path), else this machine. A record with a
#               pending forget no longer counts, and a worker-held copy's
#               mirror (another machine's focus_machine_id) is owned here.
# It never touches ssh and reads the records with at most one jq, so the
# chpwd hook can call it on every cd.
#
# Runs that compute it are serialized by one mkdir lock (rw_with_lock
# "rw-indicators", ~5 s stale guard), and each reads the panes and the
# records only once it holds the lock. Every change that can flip the flag
# (a cd, a switch, a hand-off) starts a run after the change, so the last
# run to take the lock reads the newest state and writes last: concurrent
# chpwd / attach-loop / handoff runs can no longer leave a stale value
# (last write wins, but from a read made before another run's write).
# Uncontended, the lock costs one mkdir and one rmdir.
#
# Transfers: every bg/<root_id>/ job whose runner is alive sets the global
# options
#   @rw-transfer        "handoff <root_rel>" / "handback <root_rel>", several
#                       joined with ", "
#   @rw-transfer-label  the chip text: "handing off <name>…", "handing back
#                       <name>…", or "<n> transfers…"
# and both are unset when none runs. While one runs, a chip that shows the
# label (and renders empty without it) is prepended to status-right once;
# it is a plain format, so it appears and disappears with the option,
# without waiting for status-interval.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# catppuccin mocha, as tmux/scripts/autosave_indicator.sh: yellow icon, gray
# text cell, the theme's own status separators. Commas inside the
# conditional are escaped (#,).
RW_TRANSFER_CHIP='#{?@rw-transfer-label,#[fg=#f9e2af#,bg=#1e1e2e]#{@catppuccin_status_left_separator}#[fg=#1e1e2e#,bg=#f9e2af]⇄ #[fg=#cdd6f4#,bg=#313244] #{@rw-transfer-label}#[fg=#313244#,bg=#1e1e2e]#{@catppuccin_status_right_separator},}'

wire_transfer_chip() {
  local current
  current="$(tmux show-option -gqv status-right 2>/dev/null)" || return 0
  case "$current" in *"$RW_TRANSFER_CHIP"*) return 0 ;; esac
  tmux set-option -gq status-right "${RW_TRANSFER_CHIP}${current}"
}

refresh_transfers() {
  local dir job pid verb rel n=0 list="" label=""
  dir="$(rw_bg_dir)"
  for job in "$dir"/*; do
    [ -f "$job/job.json" ] || continue
    pid="$(cat "$job/pid" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      [ -n "$pid" ] && rm -rf "$job" # a runner that died without cleaning up
      continue
    fi
    verb="$(jq -r '.verb // empty' "$job/job.json" 2>/dev/null)"
    rel="$(jq -r '.root_rel // empty' "$job/job.json" 2>/dev/null)"
    [ -n "$verb" ] && [ -n "$rel" ] || continue
    n=$((n + 1))
    list="${list:+$list, }$verb $rel"
    case "$verb" in
      handoff) label="handing off ${rel##*/}…" ;;
      *) label="handing back ${rel##*/}…" ;;
    esac
  done
  if [ "$n" -eq 0 ]; then
    tmux set-option -gqu @rw-transfer 2>/dev/null || true
    tmux set-option -gqu @rw-transfer-label 2>/dev/null || true
    return 0
  fi
  [ "$n" -eq 1 ] || label="$n transfers…"
  tmux set-option -gq @rw-transfer "$list" 2>/dev/null || true
  tmux set-option -gq @rw-transfer-label "$label" 2>/dev/null || true
  wire_transfer_chip
}

# --- Off-owner ---------------------------------------------------------------

RW_IND_TAB=$'\t'
# One tmux call per pane (display-message) or per run (list-panes -a); a
# literal TAB in the format survives tmux's output sanitizing (only values
# are sanitized; checked on tmux 3.7b).
RW_IND_FMT="#{pane_id}${RW_IND_TAB}#{pane_current_path}${RW_IND_TAB}#{@remote-host}${RW_IND_TAB}#{@rw-endpoint}"
# Field separator for jq output: not IFS whitespace, so `read` keeps empty
# fields (a TAB run would collapse into one separator).
RW_IND_US=$'\037'

# rw_ind_split <line> -- the four RW_IND_FMT fields into RW_F_PANE,
# RW_F_CWD, RW_F_HOST, RW_F_EP. Split by hand: `read` with IFS=TAB would
# collapse an empty @remote-host and shift @rw-endpoint into its place.
rw_ind_split() {
  local rest="$1" i
  local -a f=()
  for i in 0 1 2 3; do
    f[i]="${rest%%"$RW_IND_TAB"*}"
    case "$rest" in *"$RW_IND_TAB"*) rest="${rest#*"$RW_IND_TAB"}" ;; *) rest="" ;; esac
  done
  RW_F_PANE="${f[0]}" RW_F_CWD="${f[1]}" RW_F_HOST="${f[2]}" RW_F_EP="${f[3]}"
}

# Worker-owned roots, loaded once per run: RW_IND_ROOTS[i] is a root_local,
# RW_IND_OWNERS[i] its worker. Nothing (no jq) when there are no records.
RW_IND_ROOTS=()
RW_IND_OWNERS=()
rw_ind_load_roots() {
  local dir own root worker fmid pending
  RW_IND_ROOTS=()
  RW_IND_OWNERS=()
  dir="$(rw_owned_dir)"
  compgen -G "$dir/*/record.json" >/dev/null 2>&1 || return 0
  own="$(cat "$(rw_machine_id_file)" 2>/dev/null || true)"
  while IFS="$RW_IND_US" read -r root worker fmid pending; do
    [ -n "$root" ] && [ -n "$worker" ] || continue
    [ "$pending" = forget ] && continue
    # A worker-held copy: this machine is its owner, as for any other path.
    [ -n "$fmid" ] && [ "$fmid" != "$own" ] && continue
    RW_IND_ROOTS+=("$root")
    RW_IND_OWNERS+=("$worker")
  done < <(jq -r --arg us "$RW_IND_US" 'select(.owner == "worker")
      | [.root_local // "", .worker // "", .focus_machine_id // "", .pending.action // ""] | join($us)' \
    "$dir"/*/record.json 2>/dev/null)
}

# rw_ind_owner_of <abs-path> -- the owner host of a path: a worker alias,
# or nothing for this machine. The longest enclosing root wins.
rw_ind_owner_of() {
  local path="$1" i best="" owner=""
  for i in "${!RW_IND_ROOTS[@]}"; do
    case "$path" in
      "${RW_IND_ROOTS[$i]}" | "${RW_IND_ROOTS[$i]}"/*)
        if [ "${#RW_IND_ROOTS[$i]}" -gt "${#best}" ]; then
          best="${RW_IND_ROOTS[$i]}"
          owner="${RW_IND_OWNERS[$i]}"
        fi
        ;;
    esac
  done
  printf '%s' "$owner"
}

# rw_ind_pane_dir <cwd> <remote host> <endpoint> -- the directory the flag
# follows: a remote pane's endpoint directory, else the pane's cwd.
rw_ind_pane_dir() {
  local cwd="$1" host="$2" endpoint="$3" dir=""
  if [ -n "$host" ] && [ -n "$endpoint" ]; then
    dir="$(jq -r '.workspace.focus_path // .workspace.root_local // empty' \
      "$(rw_endpoint_file "$endpoint")" 2>/dev/null || true)"
  fi
  printf '%s' "${dir:-$cwd}"
}

# rw_ind_set_off_owner <pane> <pane host> <dir>
rw_ind_set_off_owner() {
  local pane="$1" host="$2" dir="$3"
  if [ "$host" != "$(rw_ind_owner_of "$dir")" ]; then
    rw_pane_set "$pane" @rw-off-owner 1
  else
    rw_pane_unset "$pane" @rw-off-owner
  fi
}

# rw_ind_refresh_pane <pane-id>
rw_ind_refresh_pane() {
  local line
  line="$(tmux display-message -pt "$1" -F "$RW_IND_FMT" 2>/dev/null || true)"
  rw_ind_split "$line"
  [ -n "$RW_F_PANE" ] || return 0
  rw_ind_load_roots
  rw_ind_set_off_owner "$RW_F_PANE" "$RW_F_HOST" "$(rw_ind_pane_dir "$RW_F_CWD" "$RW_F_HOST" "$RW_F_EP")"
}

# rw_ind_refresh_root <path> -- every pane whose directory is in the root.
rw_ind_refresh_root() {
  local root line dir
  root="$(rw_physical_path "$1")"
  rw_ind_load_roots
  while IFS= read -r line; do
    rw_ind_split "$line"
    [ -n "$RW_F_PANE" ] || continue
    dir="$(rw_ind_pane_dir "$RW_F_CWD" "$RW_F_HOST" "$RW_F_EP")"
    case "$dir" in "$root" | "$root"/*) ;; *) continue ;; esac
    rw_ind_set_off_owner "$RW_F_PANE" "$RW_F_HOST" "$dir"
  done < <(tmux list-panes -a -F "$RW_IND_FMT" 2>/dev/null || true)
}

# rw_ind_refresh_all -- every pane: @remote-host from the process tree,
# then @rw-off-owner.
rw_ind_refresh_all() {
  local line processes pane_id cwd endpoint pane_pid worker host
  rw_ind_load_roots
  processes="$(ps axo pid=,ppid=,command= 2>/dev/null || true)"
  while IFS= read -r line; do
    rw_ind_split "$line"
    pane_id="$RW_F_PANE" cwd="$RW_F_CWD" endpoint="$RW_F_EP"
    [ -n "$pane_id" ] || continue
    pane_pid="$(tmux display-message -pt "$pane_id" -F '#{pane_pid}' 2>/dev/null || true)"
    worker="$(rw_pane_get "$pane_id" @rw-worker)"
    if [ -n "$pane_pid" ] && [ -n "$worker" ] &&
      printf '%s\n' "$processes" |
        rw_ps_tree_matches '(^|/)attach-loop\.sh([[:space:]]|$)' "$pane_pid"; then
      rw_pane_set "$pane_id" @remote-host "$worker"
      rw_pane_set "$pane_id" @workspace-resurrect-skip "1"
      host="$worker"
    else
      rw_pane_unset "$pane_id" @remote-host
      rw_pane_unset "$pane_id" @workspace-resurrect-skip
      host=""
    fi
    rw_ind_set_off_owner "$pane_id" "$host" "$(rw_ind_pane_dir "$cwd" "$host" "$endpoint")"
  done < <(tmux list-panes -a -F "$RW_IND_FMT" 2>/dev/null || true)
}

# The lock every off-owner computation runs under (see the header).
RW_IND_LOCK=rw-indicators

case "${1:-}" in
  --transfers)
    refresh_transfers
    exit 0
    ;;
  --pane)
    [ -n "${2:-}" ] || rw_die "rw-refresh-indicators: --pane needs a pane id" 64
    rw_with_lock "$RW_IND_LOCK" rw_ind_refresh_pane "$2"
    exit 0
    ;;
  --root)
    [ -n "${2:-}" ] || rw_die "rw-refresh-indicators: --root needs a path" 64
    rw_with_lock "$RW_IND_LOCK" rw_ind_refresh_root "$2"
    exit 0
    ;;
  "") ;;
  *) rw_die "rw-refresh-indicators: unknown argument: $1" 64 ;;
esac

rw_with_lock "$RW_IND_LOCK" rw_ind_refresh_all
refresh_transfers
