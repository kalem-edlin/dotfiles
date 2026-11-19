#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Remote key latency (docs/tasks/remote-owned-directories.md, "Remote key
# latency (2026-11-18)"):
#   - ssh/.ssh/mini-lan-available, the `Match ... exec` LAN check ssh runs
#     on EVERY invocation for the mini: a "LAN unreachable" answer is cached
#     per network and served at once; a stale one is re-checked in the
#     background without holding the caller (or a $(... 2>&1) pipe); a
#     changed network checks synchronously; "reachable" is never cached.
#     nc, route and ip are stubs: no network.
#   - rw-copy-mode.sh (prefix [ / PPage on a remote pane) makes exactly one
#     ssh call.
#   - rw doctor fails a worker whose ssh config evaluation (ssh -G) is slow.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"

LAN_CHECK="$(cd "$RW_PLUGIN/../../.." && pwd)/ssh/.ssh/mini-lan-available"

# elapsed_ms <command...> -- runs the command, sets ELAPSED_MS and RC.
elapsed_ms() {
  local start
  start="$(rw_now_epoch)"
  "$@"
  RC=$?
  ELAPSED_MS="$(rw_elapsed_ms "$start")"
}

# --- the LAN check's negative cache -------------------------------------------
mkdir -p "$SANDBOX/lanbin"
export LAN_NC_LOG="$SANDBOX/nc.log" LAN_NC_UP="$SANDBOX/lan.up" LAN_GW="10.0.0.1"
: >"$LAN_NC_LOG"
cat >"$SANDBOX/lanbin/nc" <<'EOF'
#!/usr/bin/env bash
# Stub nc: reachable when $LAN_NC_UP exists, else hangs like an mDNS
# lookup of an absent .local name (exec: the watchdog's kill ends it).
echo "nc $*" >>"$LAN_NC_LOG"
[ -e "$LAN_NC_UP" ] && exit 0
exec sleep 5
EOF
cat >"$SANDBOX/lanbin/route" <<'EOF'
#!/usr/bin/env bash
printf '   route to: default\n    gateway: %s\n  interface: en0\n' "$LAN_GW"
EOF
cat >"$SANDBOX/lanbin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'default via %s dev eth0\n' "$LAN_GW"
EOF
chmod +x "$SANDBOX/lanbin/nc" "$SANDBOX/lanbin/route" "$SANDBOX/lanbin/ip"

lan() { PATH="$SANDBOX/lanbin:$PATH" MINI_LAN_CACHE_DIR="$SANDBOX/lancache" "$LAN_CHECK" test-mini.local; }
lan_stale() { MINI_LAN_RECHECK=0 lan; }
nc_calls() { wc -l <"$LAN_NC_LOG" | tr -d ' '; }
cache_file="$SANDBOX/lancache/test-mini.local_22"

elapsed_ms lan
eq "cold, LAN down: not available" "$RC" "1"
check "cold: checked synchronously (the 1.5 s watchdog)" test "$ELAPSED_MS" -ge 1200
eq "cold: one nc" "$(nc_calls)" "1"
check "cold: the negative answer is cached for this network" grep -q " 10.0.0.1" "$cache_file"

elapsed_ms lan
eq "warm: not available" "$RC" "1"
check "warm: answered from the cache (${ELAPSED_MS} ms)" test "$ELAPSED_MS" -lt 500
eq "warm: no nc" "$(nc_calls)" "1"

start="$(rw_now_epoch)"
out="$(lan_stale 2>&1)"
RC=$?
ELAPSED_MS="$(rw_elapsed_ms "$start")"
eq "stale: still answered from the cache" "$RC" "1"
check "stale: a \$(... 2>&1) caller is not held by the re-check (${ELAPSED_MS} ms)" test "$ELAPSED_MS" -lt 500
eq "stale: no output" "$out" ""
check "stale: re-checked in the background" wait_for 3 test "$(nc_calls)" = 2
sleep 2 # let the background re-check finish and rewrite the cache

LAN_GW="10.9.9.9"
elapsed_ms lan
eq "changed network: not available" "$RC" "1"
check "changed network: checked synchronously" test "$ELAPSED_MS" -ge 1200
check "changed network: cached under the new network" grep -q " 10.9.9.9" "$cache_file"

touch "$LAN_NC_UP"
LAN_GW="10.0.0.1"
elapsed_ms lan
eq "LAN up on a new network: available" "$RC" "0"
check "LAN up: the negative cache entry is removed" test ! -e "$cache_file"
before="$(nc_calls)"
lan
eq "LAN up again: available" "$?" "0"
eq "LAN up: a positive answer is never cached (nc ran again)" "$(nc_calls)" "$((before + 1))"

# --- prefix [ on a remote pane: one ssh ---------------------------------------
export FAKE_TMUX_PANES="$SANDBOX/panes.tsv"
printf 'pane_id=%%5\t@rw-endpoint=ep-lat\t@rw-worker=fakeworker\t@remote-host=fakeworker\n' >"$FAKE_TMUX_PANES"
: >"$FAKE_SSH_LOG"
bash "$RW_PLUGIN/scripts/rw-copy-mode.sh" %5
eq "rw-copy-mode: exactly one ssh" "$(wc -l <"$FAKE_SSH_LOG" | tr -d ' ')" "1"
check "rw-copy-mode: it enters copy-mode in the endpoint session" \
  grep -q "tmux copy-mode -t '$(rw_session_name ep-lat)'" "$FAKE_SSH_LOG"
: >"$FAKE_SSH_LOG"
bash "$RW_PLUGIN/scripts/rw-copy-mode.sh" %5 --page-up
check "rw-copy-mode --page-up: one ssh, copy-mode -u" \
  test "$(grep -c "tmux copy-mode -u -t" "$FAKE_SSH_LOG")" = 1

# --- rw doctor: slow ssh config evaluation ------------------------------------
cat >"$SANDBOX/bin/slow-config-ssh" <<'EOF'
#!/usr/bin/env bash
# The fake ssh behind a slow `Match ... exec`: config evaluation (all that
# ssh -G does) takes 0.6 s.
case " $* " in *" -G "*) sleep 0.6; exit 0 ;; esac
exec "$(dirname "$0")/ssh" "$@"
EOF
chmod +x "$SANDBOX/bin/slow-config-ssh"
doctor_out="$(bash "$RW_PLUGIN/scripts/rw-doctor.sh" 2>&1)"
check "doctor: a fast ssh config passes" grep -q "^ok   worker 'fakeworker': ssh config evaluates in" <<<"$doctor_out"
doctor_out="$(RW_SSH_BIN="$SANDBOX/bin/slow-config-ssh" bash "$RW_PLUGIN/scripts/rw-doctor.sh" 2>&1)"
check "doctor: a slow ssh config fails, naming Match exec" \
  grep -q "^FAIL worker 'fakeworker': evaluating its ssh config takes .*Match ... exec" <<<"$doctor_out"

finish
