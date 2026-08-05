#!/usr/bin/env bash
# Remote-aware Treemux for `prefix + Tab` -- tree-as-endpoint design
# (2026-08-05 redesign, operator-driven; replaces the in-window remote
# sidebar AND the rw-dispatch key-forwarding layer those sidebars required).
#
#   Plain local pane         -> upstream Treemux, unchanged.
#   Shell endpoint pane      -> toggle a TREE ENDPOINT: its own worker-side
#     tmux session running the tree nvim (with the deployed shim
#     nvim/rw-tree-init.lua as -u), shown in its own LOCAL pane split left
#     of the shell pane. Every endpoint's worker window stays single-pane
#     forever, so nav/resize/close are stock local tmux -- instant, no ssh
#     in any keystroke path.
#   Tree endpoint pane       -> toggle off (close self).
#
# File-open policy lives in the worker shim (rw-tree-init.lua): reuse a live
# editor, take over an idle associated shell, or ask rw-tree-listener.sh for
# a fresh local editor pane. ORPHANING IS A FEATURE: closing the shell
# endpoint leaves its tree endpoint standing alone as a normal remote-backed
# pane (operator decision 2026-08-05); an orphaned tree's opens produce new
# editor endpoints split off the tree pane itself.
#
# The remote bootstrap runs with temp-file output capture, never $(ssh ...
# heredoc): macOS bash 3.2's $() parser truncates at case-pattern parens
# inside heredocs (2026-08-05 lockout incident) -- standing rule for this
# plugin.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

pane_id="${TMUX_PANE:-$(tmux display-message -p -F '#{pane_id}' 2>/dev/null || true)}"

show_error() {
  local message="$1"
  message="${message//$'\n'/ }"
  if [ -n "$pane_id" ]; then
    tmux display-message -t "$pane_id" "rw: $message" 2>/dev/null || true
  fi
  rw_warn "$message"
}

run_local_treemux() {
  local toggle args
  toggle="$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh"
  args="$(tmux show-option -gqv @treemux-key-Tab 2>/dev/null || true)"

  if [ -z "$pane_id" ]; then
    show_error "Treemux must be invoked from a tmux pane."
    return 1
  fi
  if [ ! -x "$toggle" ] || [ -z "$args" ]; then
    show_error "local Treemux is not loaded; install its TPM plugin and reload tmux."
    return 1
  fi

  "$toggle" "$args" "$pane_id"
}

if [ -z "$pane_id" ]; then
  show_error "Treemux must be invoked from a tmux pane."
  exit 1
fi

endpoint_id="$(rw_pane_get "$pane_id" @rw-endpoint)"
if [ -z "$endpoint_id" ]; then
  run_local_treemux
  exit $?
fi

# A stale pane cache must not fall through to local Treemux: that would show
# a plausible-looking but incorrect focus-machine tree beside a remote shell.
endpoint_json="$(rw_read_endpoint "$endpoint_id" 2>/dev/null || true)"
if [ -z "$endpoint_json" ]; then
  show_error "remote endpoint $endpoint_id has no registry entry; run 'rw doctor' instead of opening a local tree."
  exit 1
fi

role="$(printf '%s' "$endpoint_json" | jq -r '.role // empty')"
if [ "$role" = "tree" ]; then
  # Tab on the tree pane itself: toggle off.
  exec "$SCRIPT_DIR/rw-close.sh" --pane "$pane_id" --reason "treemux-toggle"
fi

worker="$(printf '%s' "$endpoint_json" | jq -r '.worker // empty')"
if [ -z "$worker" ]; then
  show_error "remote endpoint $endpoint_id has no worker in its registry entry."
  exit 1
fi

local_pane_for_endpoint() {
  tmux list-panes -a -F '#{pane_id} #{@rw-endpoint}' 2>/dev/null |
    awk -v id="$1" '$2 == id { print $1; exit }'
}

# Toggle off: a live tree endpoint already linked to this shell endpoint.
existing_tree="$(jq -r --arg id "$endpoint_id" \
  'select(.role == "tree" and .tree_of == $id) | .endpoint_id' \
  "$(rw_endpoints_dir)"/*.json 2>/dev/null | head -n 1)"
if [ -n "$existing_tree" ]; then
  tree_pane="$(local_pane_for_endpoint "$existing_tree")"
  if [ -n "$tree_pane" ]; then
    exec "$SCRIPT_DIR/rw-close.sh" --pane "$tree_pane" --reason "treemux-toggle"
  fi
  rw_close_endpoint_core "$existing_tree" "treemux-toggle"
  exit 0
fi

# ---------------------------------------------------------------------------
# Create the tree endpoint.
# ---------------------------------------------------------------------------

tree_id="$(rw_new_short_id)"
tree_session="$(rw_session_name "$tree_id")"
shell_session="$(rw_session_name "$endpoint_id")"
shim_b64="$(base64 <"$RW_PLUGIN_DIR/nvim/rw-tree-init.lua" | tr -d '\n')"
start_ts="$(rw_now_epoch)"

remote_out="$(mktemp "${TMPDIR:-/tmp}/rw-treemux.XXXXXX")"
trap 'rm -f "$remote_out"' EXIT
rw_ssh_batch "$worker" "$(rw_ssh_connect_timeout)" \
  bash -s -- "$shell_session" "$tree_session" "$shim_b64" >"$remote_out" 2>&1 <<'REMOTE_TREE'
set -uo pipefail
shell_session="${1:?}"
tree_session="${2:?}"
shim_b64="${3:?}"

shell_pane="$(tmux display-message -pt "=$shell_session:" -F '#{pane_id}' 2>/dev/null)" ||
  { echo "endpoint session $shell_session is not running on this worker" >&2; exit 20; }
cwd="$(tmux display-message -pt "=$shell_session:" -F '#{pane_current_path}' 2>/dev/null)"
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"

treemux_dir="$HOME/.config/tmux/plugins/treemux"
[ -x "$treemux_dir/scripts/toggle.sh" ] ||
  { echo "Treemux is not installed on this worker; run make setup-headless there" >&2; exit 21; }
upstream_init="$HOME/.config/tmux/treemux_init.lua"
[ -f "$upstream_init" ] || upstream_init="$treemux_dir/configs/treemux_init.lua"

tree_dir="$HOME/.local/state/tmux-remote-workspaces/tree"
mkdir -p "$tree_dir" && chmod 700 "$tree_dir"
shim="$tree_dir/rw-tree-init.lua"
printf '%s' "$shim_b64" | base64 -d >"$shim" ||
  { echo "failed to deploy rw-tree-init.lua" >&2; exit 22; }

state="$tree_dir/$tree_session.json"
printf '{"shell_pane":"%s","editor_pane":"","editor_socket":""}' "$shell_pane" >"$state"
rm -f "$state.request"
tree_sock="$tree_dir/$tree_session.sock"
rm -f "$tree_sock"

nvim_cmd="RW_TREE_STATE='$state' RW_TREE_UPSTREAM_INIT='$upstream_init' \
NVIM_APPNAME=nvim-treemux nvim '$root' --listen '$tree_sock' -u '$shim' \
'+let g:nvim_tree_remote_tmux_pane=\"$shell_pane\"' \
'+let g:nvim_tree_remote_tmux_split_position=\"\"' \
'+let g:nvim_tree_remote_tmux_split_size=\"70%\"' \
'+let g:nvim_tree_remote_tmux_focus=\"editor\"' \
'+let g:nvim_tree_remote_tmux_editor_init_file=\"\"' \
'+let g:nvim_tree_remote_treemux_path=\"$treemux_dir\"' \
+Neotree '+lua vim.api.nvim_win_close(1000, false)'"

tmux new-session -d -s "$tree_session" -c "$root" "$nvim_cmd" ||
  { echo "failed to create tree session $tree_session" >&2; exit 23; }
tmux set-option -t "$tree_session" prefix None
tmux set-option -t "$tree_session" prefix2 None
tmux set-option -t "$tree_session" mouse off
tmux set-option -t "$tree_session" escape-time 10
tmux set-option -t "$tree_session" status off

printf '%s\n%s\n%s\n' "$shell_pane" "$root" "$state"
REMOTE_TREE
remote_status=$?
if [ "$remote_status" -ne 0 ]; then
  msg="$(cat "$remote_out")"
  [ -n "$msg" ] || msg="remote tree bootstrap failed on $worker (exit $remote_status)"
  show_error "$msg"
  exit "$remote_status"
fi
{ read -r shell_worker_pane; read -r root; read -r state_file; } <"$remote_out"
rm -f "$remote_out"
trap - EXIT
if [ -z "${state_file:-}" ]; then
  show_error "remote tree bootstrap returned no state path; aborting."
  exit 1
fi

now="$(rw_now_iso)"
registry_json="$(jq -nc \
  --arg endpoint_id "$tree_id" \
  --arg worker "$worker" \
  --arg focus_machine_id "$(rw_machine_id)" \
  --arg remote_path "$root" \
  --arg tree_of "$endpoint_id" \
  --arg tree_state_file "$state_file" \
  --arg shell_worker_pane "$shell_worker_pane" \
  --arg now "$now" \
  '{
    endpoint_id: $endpoint_id,
    worker: $worker,
    role: "tree",
    tree_of: $tree_of,
    tree_state_file: $tree_state_file,
    shell_worker_pane: $shell_worker_pane,
    focus_machine_id: $focus_machine_id,
    focus_pane_id: "",
    workspace: {identity: "", mode: "tree", focus_path: "", remote_path: $remote_path},
    launch_intent: {worker: $worker, workspace_arg: "tree"},
    agent: {provider: null, session_id: null, resume_intent: null},
    created_at: $now, updated_at: $now, generation: 1
  }')"
rw_write_json_atomic "$(rw_endpoint_file "$tree_id")" "$registry_json"

tree_pane="$(tmux split-window -hb -l 40 -t "$pane_id" -P -F '#{pane_id}' \
  "exec bash '$SCRIPT_DIR/rw-tree-pane.sh' '$tree_id'")"
if [ -z "$tree_pane" ]; then
  rw_close_endpoint_core "$tree_id" "treemux-local-split-failed"
  show_error "could not create the local tree pane."
  exit 1
fi
registry_json="$(printf '%s' "$registry_json" | jq -c --arg p "$tree_pane" '.focus_pane_id = $p')"
rw_write_json_atomic "$(rw_endpoint_file "$tree_id")" "$registry_json"

nohup "$SCRIPT_DIR/rw-tree-listener.sh" "$tree_id" >/dev/null 2>&1 &
disown 2>/dev/null || true

rw_log_event "treemux-open" "$tree_id" "$worker" "$(rw_elapsed_ms "$start_ts")" "success" "tree_of=$endpoint_id"
exit 0
