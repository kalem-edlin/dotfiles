#!/usr/bin/env bash
# `rw doctor` -- read-only diagnostics. Never installs, mutates, or injects
# messages into shells/TUIs; only prints a report to stdout for the user who
# explicitly ran this command. Hosts the consume-never-provision preflight
# report for every configured worker.

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
        if command -v nvim >/dev/null 2>&1; then
          nvim_version="$(nvim --version 2>/dev/null | sed -n "1s/^NVIM v//p")"
          nvim_major="${nvim_version%%.*}"
          nvim_minor="${nvim_version#*.}"
          nvim_minor="${nvim_minor%%.*}"
          case "$nvim_major:$nvim_minor" in
            *[!0-9:]* | :* | *:) missing="${missing} nvim>=0.10(version-unreadable)" ;;
            *)
              if [ "$nvim_major" -eq 0 ] && [ "$nvim_minor" -lt 10 ]; then
                missing="${missing} nvim>=0.10(found:$nvim_version)"
              fi
              ;;
          esac
        else
          missing="${missing} nvim>=0.10(missing)"
        fi
        command -v lsof >/dev/null 2>&1 || missing="${missing} lsof"
        [ -x "$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh" ] || missing="${missing} treemux"
        printf "%s\n" "${missing# }"
      ' 2>/dev/null || true)"
      if [ -z "$treemux_missing" ]; then
        pass "worker '$worker_alias': remote Treemux prerequisites are present"
      else
        note "worker '$worker_alias': remote Treemux unavailable (needs: $treemux_missing; run 'make setup-headless' there)"
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
if reconcile_local_out="$("$SCRIPT_DIR/../libexec/reconcile-local" --dry-run 2>&1)"; then
  [ -n "$reconcile_local_out" ] || reconcile_local_out="rw reconcile-local: dry-run skipped (no server or no endpoints)"
  pass "reconcile-local: $reconcile_local_out"
else
  note "reconcile-local --dry-run failed to run: $reconcile_local_out"
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
echo "== Local durability (verified operating-system timer) =="
if ! tmux has-session 2>/dev/null && [ -z "${TMUX:-}" ]; then
  note "no local tmux server running -- autosave state not checked"
else
  save_path="$(tmux show-option -gqv @resurrect-save-script-path 2>/dev/null || true)"
  case "$save_path" in
    *tmux/scripts/resurrect_save.sh*)
      pass "manual and periodic saves share the verified save wrapper"
      ;;
    *)
      fail "@resurrect-save-script-path does not point at tmux/scripts/resurrect_save.sh"
      ;;
  esac

  manual_binding="$(tmux list-keys -T prefix 2>/dev/null | grep ' C-s ' || true)"
  case "$manual_binding" in
    *manual_resurrect_save.sh*'#{@remote-host}'*)
      pass "prefix C-s dispatches saves to the focused remote worker"
      ;;
    *)
      fail "prefix C-s is not wired to the remote-aware manual save dispatcher"
      ;;
  esac

  status_right="$(tmux show-option -gqv status-right 2>/dev/null || true)"
  case "$status_right" in
    *continuum_save.sh*)
      fail "status-right still contains Continuum's save scheduler"
      ;;
    *)
      pass "status-right contains no save scheduler"
      ;;
  esac

  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if launchctl print "gui/$(id -u)/com.kalem.tmux-resurrect-save" >/dev/null 2>&1; then
        pass "launchd verified-save timer is loaded"
      else
        fail "launchd verified-save timer is not loaded"
      fi
      ;;
    Linux)
      if systemctl --user is-active --quiet tmux-resurrect-save.timer 2>/dev/null; then
        pass "systemd verified-save timer is active"
      else
        fail "systemd verified-save timer is not active"
      fi
      ;;
  esac

  resurrect_dir="$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)"
  [ -n "$resurrect_dir" ] || resurrect_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
  host="$(hostname 2>/dev/null || true)"
  resurrect_dir="$(printf '%s\n' "$resurrect_dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g")"
  last_save="$(sed -n '1p' "$resurrect_dir/.last-successful-save" 2>/dev/null || true)"
  interval="$(tmux show-option -gqv @workspace-autosave-interval 2>/dev/null || true)"
  case "$interval" in '' | *[!0-9]*) interval=5 ;; esac
  case "$last_save" in
    '' | *[!0-9]*) fail "verified successful-save marker is missing or invalid" ;;
    *)
      save_age=$(($(date +%s) - last_save))
      if [ "$save_age" -le $((interval * 60 * 3)) ]; then
        pass "last verified save was ${save_age}s ago"
      else
        fail "last verified save was ${save_age}s ago; periodic saving has stalled"
      fi
      ;;
  esac
fi

echo
echo "== Boundaries (out of scope by design -- docs/tmux-remote-workspaces.md) =="
note "handoff is explicit and transactional; continuous synchronization and Mosh transport are not part of the system."
note "endpoint close never removes a worker checkout; workspace archival and removal remain manual."

echo
if [ "$failures" -eq 0 ]; then
  echo "rw doctor: all checks passed"
else
  echo "rw doctor: $failures check(s) failed"
fi
exit "$failures"
