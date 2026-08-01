#!/usr/bin/env bash
# `rw doctor` -- read-only diagnostics. Never installs, mutates, or injects
# messages into shells/TUIs; only prints a report to stdout for the user who
# explicitly ran this command. Hosts the consume-never-provision preflight
# report for every configured worker (Resolved decision #5).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
note() { printf 'note %s\n' "$1"; }

echo "== Local prerequisites =="
if command -v jq >/dev/null 2>&1; then pass "jq is available"; else fail "jq is required"; fi
if command -v ssh >/dev/null 2>&1; then pass "ssh is available"; else fail "ssh is required"; fi
if command -v uuidgen >/dev/null 2>&1 || [ -r /proc/sys/kernel/random/uuid ]; then
  pass "a uuid source is available"
else
  fail "no uuid source found (uuidgen or /proc/sys/kernel/random/uuid)"
fi
if rw_config_valid; then pass "config.json is valid"; else fail "config.json ($RW_CONFIG_FILE) is invalid"; fi

state_dir="$(rw_state_dir)"
if mkdir -p "$state_dir" 2>/dev/null && [ -w "$state_dir" ]; then
  pass "state dir is writable ($state_dir)"
else
  fail "state dir is not writable ($state_dir)"
fi

echo
echo "== Per-worker consume-never-provision preflight =="
if rw_config_valid; then
  worker_count="$(jq '.workers | length' "$RW_CONFIG_FILE")"
  if [ "$worker_count" -eq 0 ]; then
    note "no workers declared in config.json"
  fi
  preflight_err="$(mktemp "${TMPDIR:-/tmp}/rw-doctor-preflight.XXXXXX")"
  trap 'rm -f "$preflight_err"' EXIT
  i=0
  while [ "$i" -lt "$worker_count" ]; do
    worker_alias="$(jq -r ".workers[$i].alias" "$RW_CONFIG_FILE")"
    i=$((i + 1))
    if report="$("$SCRIPT_DIR/preflight.sh" --worker "$worker_alias" 2>"$preflight_err")"; then
      pass "worker '$worker_alias': tmux+git present, reachable"
    else
      fail "worker '$worker_alias': $(tr '\n' ' ' <"$preflight_err" | sed -n 's/.*rw: //p' | head -c 200)"
    fi
    : >"$preflight_err"
    if [ -n "${report:-}" ] && [ "$(printf '%s' "$report" | jq -r '.ssh_reachable // false')" = "true" ]; then
      missing="$(printf '%s' "$report" | jq -r '.missing // [] | join(",")')"
      [ -n "$missing" ] && note "worker '$worker_alias' missing: $missing (run 'make setup-headless' there)"
      passthrough="$(rw_ssh_batch "$worker_alias" "$(rw_ssh_status_timeout)" "tmux show-option -gqv allow-passthrough" 2>/dev/null || true)"
      if [ "$passthrough" = "on" ]; then
        pass "worker '$worker_alias': allow-passthrough is on"
      elif [ -n "$passthrough" ]; then
        fail "worker '$worker_alias': allow-passthrough is '$passthrough' (expected 'on', needed for OSC 52 over SSH)"
      else
        note "worker '$worker_alias': could not read allow-passthrough (no worker tmux server running yet, or unreachable)"
      fi

      # This program is intentionally expanded by the worker's shell, not by
      # this local doctor process.
      # shellcheck disable=SC2016
      treemux_missing="$(rw_ssh_batch "$worker_alias" "$(rw_ssh_status_timeout)" '
        missing=""
        command -v nvim >/dev/null 2>&1 || missing="${missing} nvim"
        command -v lsof >/dev/null 2>&1 || missing="${missing} lsof"
        [ -x "$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh" ] || missing="${missing} treemux"
        printf "%s\n" "${missing# }"
      ' 2>/dev/null || true)"
      if [ -z "$treemux_missing" ]; then
        pass "worker '$worker_alias': remote Treemux prerequisites are present"
      else
        note "worker '$worker_alias': remote Treemux unavailable (missing: $treemux_missing; run 'make setup-headless' there)"
      fi
    fi
    report=""
  done
else
  fail "cannot run worker preflight -- config.json is invalid"
fi

echo
echo "== Registry / live-pane consistency (report only) =="
endpoints_dir="$(rw_endpoints_dir)"
pane_endpoints="$(tmux list-panes -a -F '#{@rw-endpoint}' 2>/dev/null | awk 'NF')"

if [ -d "$endpoints_dir" ]; then
  for f in "$endpoints_dir"/*.json; do
    [ -f "$f" ] || continue
    id="$(jq -r '.endpoint_id' "$f")"
    if printf '%s\n' "$pane_endpoints" | grep -qx "$id"; then
      pass "endpoint $id has a bound local pane"
    else
      note "endpoint $id has no bound local pane (orphaned registry entry -- report only, no action taken)"
    fi
  done
else
  note "no endpoints directory yet"
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  if ! rw_endpoint_exists "$id"; then
    note "pane references endpoint $id with no registry entry (stale @rw-endpoint cache)"
  fi
done <<<"$pane_endpoints"

echo
echo "== Clipboard / passthrough =="
local_passthrough="$(tmux show-option -gqv allow-passthrough 2>/dev/null || true)"
if [ "$local_passthrough" = "on" ]; then
  pass "local allow-passthrough is on"
else
  fail "local allow-passthrough is not on (OSC 52 clipboard over SSH will not reach the terminal)"
fi
note "worker-side allow-passthrough is checked per reachable worker above."
note "OSC 52 has a ~74KB payload cap; large yanks silently fail to reach the outer terminal -- this is expected, not a bug."
note "Confirm the outer terminal emulator has OSC 52 clipboard access enabled (opt-in, terminal-specific setting)."

echo
echo "== Tombstone / registry consistency (report only) =="
tombstones_dir="$(rw_tombstones_dir)"
inconsistent=0
if [ -d "$tombstones_dir" ]; then
  for tf in "$tombstones_dir"/*.json; do
    [ -f "$tf" ] || continue
    tid="$(jq -r '."endpoint-id" // empty' "$tf" 2>/dev/null)"
    [ -n "$tid" ] || continue
    if rw_endpoint_exists "$tid"; then
      note "endpoint $tid has both a tombstone and a live registry entry -- an incomplete close (crash between tombstone-write and registry removal); the next reconciliation will finish it"
      inconsistent=$((inconsistent + 1))
    fi
  done
fi
if [ "$inconsistent" -eq 0 ]; then
  pass "no tombstone/registry inconsistencies found"
else
  note "$inconsistent tombstone/registry inconsistency(ies) found (report only, no action taken here)"
fi

echo
echo "== Reconciliation preview (report only -- never closes anything here) =="
if reconcile_out="$("$SCRIPT_DIR/../libexec/reconcile" --dry-run 2>&1)"; then
  case "$reconcile_out" in
    *"abort reason="*) note "reconcile: $reconcile_out" ;;
    *) pass "reconcile: $reconcile_out" ;;
  esac
else
  note "reconcile --dry-run failed to run: $reconcile_out"
fi

echo
echo "== Handoff/return machinery (report only) =="
if [ -x "$SCRIPT_DIR/rw-handoff.sh" ] && [ -x "$SCRIPT_DIR/rw-return.sh" ] && [ -x "$SCRIPT_DIR/../libexec/sync/handoff" ]; then
  pass "rw-handoff.sh/rw-return.sh/libexec/sync/handoff are present and executable"
else
  fail "one or more of rw-handoff.sh/rw-return.sh/libexec/sync/handoff is missing or not executable"
fi
adapters_dir="$SCRIPT_DIR/../libexec/adapters"
installed_adapters="$(find "$adapters_dir" -maxdepth 1 -type f -perm -u+x ! -name 'common-adapter.sh' ! -name 'smoke-test' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${installed_adapters:-0}" -gt 0 ]; then
  pass "$installed_adapters provider adapter(s) installed under $adapters_dir"
else
  note "no provider adapters installed under $adapters_dir -- agent handoff degrades to workspace-only"
fi

echo
echo "== Deferred (explicitly out of v1 scope, not bugs -- initial-plan.md) =="
note "continuous watch-mode synchronization and the Mosh transport are deferred; see deferred-sync-and-transport.md."
note "ad hoc worker workspace archive/remove commands are deferred to Phase 6; cleanup is manual only by design."

echo
if [ "$failures" -eq 0 ]; then
  echo "rw doctor: all checks passed"
else
  echo "rw doctor: $failures check(s) failed"
fi
exit "$failures"
