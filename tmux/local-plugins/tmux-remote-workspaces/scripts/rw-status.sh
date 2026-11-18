#!/usr/bin/env bash
# `rw status [--json]` -- remote roots and their endpoints.
#
#   (default)  One row per ownership record (root, owner, worker, endpoints,
#              pending), then one row per registered endpoint with its live
#              local pane (re-resolved via tmux, not trusted from the
#              registry) and last event. No ssh: fast and safe to run any
#              time; `rw doctor` does the reachability checks.
#   --json     One JSON array of the ownership record objects, nothing else.
#
# Read-only: never mutates the registry.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

rw_need_jq

json="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json="true"; shift ;;
    *) rw_die "rw status: unknown argument: $1" 64 ;;
  esac
done

records="$(rw_owned_records_json)"
if [ "$json" = "true" ]; then
  printf '%s\n' "$records" | jq -c .
  exit 0
fi

if [ "$(printf '%s' "$records" | jq 'length')" -eq 0 ]; then
  echo "rw status: no remote roots."
else
  printf '%-44s %-6s %-12s %-5s %s\n' "ROOT" "OWNER" "WORKER" "PANES" "PENDING"
  printf '%s' "$records" | jq -r '.[] | [
      ("~/" + .root_rel), .owner, .worker, (.endpoints | length | tostring),
      ((if .pending then .pending.action + ": " + (.pending.reason // "") else "" end)
        + (if .stale_worker then " (remote copy stale)" else "" end))
    ] | @tsv' |
    while IFS="$(printf '\t')" read -r root owner worker panes pending; do
      printf '%-44s %-6s %-12s %-5s %s\n' "$root" "$owner" "$worker" "$panes" "$pending"
    done
fi

endpoints_dir="$(rw_endpoints_dir)"
if [ ! -d "$endpoints_dir" ] || ! compgen -G "$endpoints_dir/*.json" >/dev/null; then
  exit 0
fi

echo
pane_map="$(tmux list-panes -a -F '#{pane_id} #{@rw-endpoint}' 2>/dev/null | awk 'NF == 2')"
events_file="$(rw_events_file)"

printf '%-10s %-12s %-40s %-14s %-28s\n' "ENDPOINT" "WORKER" "REMOTE DIR" "PANE" "LAST EVENT"
for f in "$endpoints_dir"/*.json; do
  [ -f "$f" ] || continue
  endpoint_id="$(jq -r '.endpoint_id' "$f")"
  worker="$(jq -r '.worker' "$f")"
  remote_path="$(jq -r '.workspace.remote_path // empty' "$f")"
  pane="$(printf '%s\n' "$pane_map" | awk -v id="$endpoint_id" '$2 == id { print $1; exit }')"
  [ -n "$pane" ] || pane="(unattached)"
  last=""
  [ -f "$events_file" ] && last="$(grep -F "\"$endpoint_id\"" "$events_file" | tail -n1 |
    jq -r '"\(.event)/\(.outcome) @ \(.ts)"' 2>/dev/null)"
  printf '%-10s %-12s %-40s %-14s %-28s\n' "$endpoint_id" "$worker" "$remote_path" "$pane" "${last:-(none)}"
done
