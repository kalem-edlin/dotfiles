#!/usr/bin/env bash
# `rw status` -- human-readable table of endpoints from the registry.
# Re-resolves pane binding live (a pane's @rw-endpoint may have moved/gone
# since the registry entry was written) and does a short-timeout liveness
# check per worker. Read-only: never mutates the registry.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

endpoints_dir="$(rw_endpoints_dir)"
if [ ! -d "$endpoints_dir" ] || [ -z "$(ls -A "$endpoints_dir" 2>/dev/null)" ]; then
  echo "rw status: no endpoints registered."
  exit 0
fi

# Build pane_id -> endpoint_id map once (avoids one `tmux list-panes` per row).
pane_map_file="$(mktemp "${TMPDIR:-/tmp}/rw-status-panes.XXXXXX")"
trap 'rm -f "$pane_map_file"' EXIT
tmux list-panes -a -F '#{pane_id} #{@rw-endpoint}' 2>/dev/null |
  awk 'NF == 2' >"$pane_map_file"

pane_for_endpoint() {
  awk -v id="$1" '$2 == id { print $1; exit }' "$pane_map_file"
}

last_event_for() {
  local endpoint_id="$1" events_file
  events_file="$(rw_events_file)"
  [ -f "$events_file" ] || return 0
  jq -rs --arg id "$endpoint_id" \
    '[.[] | select(.endpoint == $id)] | last | if . then "\(.event)/\(.outcome) @ \(.ts)" else "" end' \
    "$events_file" 2>/dev/null
}

liveness_for() {
  local worker="$1" session_name="$2"
  local timeout
  timeout="$(rw_ssh_status_timeout)"
  if rw_ssh_batch "$worker" "$timeout" "tmux has-session -t '$session_name'" >/dev/null 2>&1; then
    echo "alive"
  else
    echo "unreachable-or-absent"
  fi
}

printf '%-10s %-8s %-10s %-40s %-8s %-14s %-24s %s\n' \
  "ENDPOINT" "WORKER" "MODE" "WORKSPACE" "PANE" "LIVENESS" "LAST EVENT" "UPDATED"

for f in "$endpoints_dir"/*.json; do
  [ -f "$f" ] || continue
  endpoint_id="$(jq -r '.endpoint_id' "$f")"
  worker="$(jq -r '.worker' "$f")"
  mode="$(jq -r '.workspace.mode' "$f")"
  remote_path="$(jq -r '.workspace.remote_path' "$f")"
  updated_at="$(jq -r '.updated_at' "$f")"

  pane_id="$(pane_for_endpoint "$endpoint_id")"
  [ -n "$pane_id" ] || pane_id="(unattached)"

  session_name="$(rw_session_name "$endpoint_id")"
  liveness="$(liveness_for "$worker" "$session_name")"
  last_event="$(last_event_for "$endpoint_id")"
  [ -n "$last_event" ] || last_event="(none)"

  printf '%-10s %-8s %-10s %-40s %-8s %-14s %-24s %s\n' \
    "$endpoint_id" "$worker" "$mode" "$remote_path" "$pane_id" "$liveness" "$last_event" "$updated_at"
done
