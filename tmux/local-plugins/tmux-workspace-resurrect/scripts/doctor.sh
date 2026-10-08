#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }
note() { printf 'note %s\n' "$1"; }
is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

snapshot_is_sane() {
  [ -s "$1" ] || return 1
  awk -F'\t' '
    $1 == "pane" && NF == 11 { pane_ok = 1 }
    NF > 0 { last_type = $1; last_nf = NF }
    END { exit !(pane_ok && last_type == "state" && last_nf == 3) }
  ' "$1"
}

if command -v jq >/dev/null 2>&1; then
  pass "jq is available"
else
  fail "jq is required"
fi
if jq -e . "$WORKSPACE_CONFIG_FILE" >/dev/null 2>&1; then
  pass "config.json is valid"
else
  fail "config.json is invalid"
fi

expected_interval="$(jq -r '.autosave_interval_minutes' "$WORKSPACE_CONFIG_FILE" 2>/dev/null)"
loaded_interval="$(tmux show-option -gqv @workspace-autosave-interval 2>/dev/null || true)"
if [ "$loaded_interval" = "$expected_interval" ]; then
  pass "verified save interval is ${loaded_interval} minutes"
else
  fail "verified save interval is not loaded from config.json"
fi
if [ "$(tmux show-option -gqv @continuum-save-interval 2>/dev/null || true)" = "0" ]; then
  pass "Continuum's status-driven save scheduler is disabled"
else
  fail "Continuum's save interval must be zero"
fi

status_right="$(tmux show-option -gqv status-right 2>/dev/null || true)"
case "$status_right" in
  *autosave_indicator.sh*) pass "verified autosave indicator is present" ;;
  *) fail "verified autosave indicator is missing" ;;
esac
case "$status_right" in
  *continuum_save.sh*) fail "Continuum save command is still embedded in status-right" ;;
  *) pass "status-right contains no save scheduler" ;;
esac
if [ "$(tmux show-option -gwqv allow-set-title 2>/dev/null || true)" = "off" ]; then
  pass "application title animations cannot trigger tmux status redraws"
else
  fail "allow-set-title must be off"
fi

save_path="$(tmux show-option -gqv @resurrect-save-script-path 2>/dev/null || true)"
case "$save_path" in
  *tmux/scripts/resurrect_save.sh) pass "manual and timer saves use the verified wrapper" ;;
  *) fail "verified save wrapper is not configured" ;;
esac

manual_binding="$(tmux list-keys -T prefix 2>/dev/null | grep ' C-s ' || true)"
case "$manual_binding" in
  *manual_resurrect_save.sh*'#{@remote-host}'*) pass "manual save binding is remote-aware" ;;
  *) fail "manual save binding is not remote-aware" ;;
esac

save_hook="$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null || true)"
restore_hook="$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null || true)"
case "$save_hook" in
  *tmux-workspace-resurrect/scripts/save.sh*) pass "workspace save hook is installed" ;;
  *) fail "workspace save hook is missing" ;;
esac
case "$restore_hook" in
  *tmux-workspace-resurrect/scripts/restore.sh*) pass "workspace restore hook is installed" ;;
  *) fail "workspace restore hook is missing" ;;
esac

if [ "$(tmux show-option -gqv @resurrect-processes 2>/dev/null)" = "false" ]; then
  pass "unsafe Resurrect process replay is disabled"
else
  fail "Resurrect process replay must be false"
fi

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
  *) fail "no supported verified-save timer exists on this platform" ;;
esac

detached_hook="$(tmux show-hooks -g 2>/dev/null | grep '^client-detached' || true)"
case "$detached_hook" in
  *scripts/resurrect_save.sh*) pass "client-detached save hook is present" ;;
  *) fail "client-detached save hook is missing" ;;
esac

resurrect_dir="$(workspace_resurrect_dir)"
marker="$resurrect_dir/.last-successful-save"
last="$resurrect_dir/last"
sidecar="$(workspace_sidecar_file)"
now="$(date +%s)"
last_success=""
[ -f "$marker" ] && last_success="$(sed -n '1p' "$marker" 2>/dev/null)"
if is_uint "$last_success"; then
  age=$((now - last_success))
  stale_after=$((expected_interval * 60 * 3))
  if [ "$age" -le "$stale_after" ]; then
    pass "verified save is fresh ($((age / 60))m old)"
  else
    fail "verified save is stale ($((age / 60))m old)"
  fi
else
  fail "verified save marker is missing or invalid"
fi

if snapshot_is_sane "$last"; then
  pass "authoritative Resurrect snapshot is structurally sane"
else
  fail "authoritative Resurrect snapshot is missing or malformed"
fi

snapshot_name="$(readlink "$last" 2>/dev/null || printf 'last')"
if [ -f "$sidecar" ] && jq -e --arg snapshot "$snapshot_name" '
  .version == 1 and
  .resurrect_snapshot == $snapshot and
  (.saved_at | type == "string" and length > 0) and
  (.panes | type == "array") and
  (.treemux | type == "array")
' "$sidecar" >/dev/null 2>&1; then
  pass "workspace sidecar matches the authoritative snapshot ($(jq '.panes | length' "$sidecar") panes)"
  agent_errors="$(jq '[.agent_capture_errors[]?] | length' "$sidecar")"
  if [ "$agent_errors" -gt 0 ]; then
    fail "$agent_errors agent pane(s) lack verified resume IDs"
    while IFS= read -r problem; do
      note "$problem"
    done < <(jq -r '.agent_capture_errors[] | "\(.logical_id): \(.error)"' "$sidecar")
  else
    pass "no agent capture errors reported in this snapshot"
  fi
else
  fail "workspace sidecar is invalid or does not match the authoritative snapshot"
fi

server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || true)"
lock_dir="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-verified-save.lock"
max_save="$(jq -r '.save_timeout_seconds // 120' "$WORKSPACE_CONFIG_FILE" 2>/dev/null)"
if [ -d "$lock_dir" ]; then
  lock_mtime="$(mtime "$lock_dir" 2>/dev/null || true)"
  owner="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
  if is_uint "$lock_mtime"; then lock_age=$((now - lock_mtime)); else lock_age=$((max_save + 31)); fi
  if ! is_uint "$owner" || ! kill -0 "$owner" 2>/dev/null; then
    fail "save lock has no live owner"
  elif [ "$lock_age" -gt $((max_save + 30)) ]; then
    fail "save lock owner $owner is hung (${lock_age}s old)"
  else
    note "save is currently running under pid $owner (${lock_age}s)"
  fi
else
  pass "no save lock is stuck"
fi

bad_nvim=0
registered_nvim=0
while IFS= read -r pane_id; do
  server="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-server 2>/dev/null || true)"
  [ -n "$server" ] || continue
  registered_nvim=$((registered_nvim + 1))
  owner="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-owner-pid 2>/dev/null || true)"
  if ! is_uint "$owner" || ! kill -0 "$owner" 2>/dev/null || [ ! -S "$server" ]; then
    bad_nvim=$((bad_nvim + 1))
    continue
  fi
done < <(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)
if [ "$bad_nvim" -eq 0 ]; then
  pass "Neovim pane registrations are healthy ($registered_nvim registered)"
else
  fail "$bad_nvim of $registered_nvim Neovim pane registrations are stale"
fi

claude_settings=""
for candidate in "$HOME/.config/claudef/settings.json" "$HOME/.claude/settings.json"; do
  [ -f "$candidate" ] && claude_settings="$candidate" && break
done
if [ -n "$claude_settings" ] && jq -e '.hooks.SessionStart[]?.hooks[]? |
  select(.command | contains("record-agent-session.sh") and endswith("claude"))' \
  "$claude_settings" >/dev/null 2>&1; then
  pass "Claude session recording hook is declared"
else
  fail "Claude session recording hook is missing"
fi

if [ -f "$HOME/.config/pif/extensions/tmux-workspace-resurrect.ts" ] ||
  [ -f "$HOME/.pi/agent/extensions/tmux-workspace-resurrect.ts" ]; then
  pass "Pi session extension is installed"
else
  fail "Pi session extension is missing"
fi

if [ -f "$HOME/.zsh/tmux-workspace-resurrect.zsh" ]; then
  pass "zsh pane-state integration is installed"
else
  fail "zsh pane-state integration is missing"
fi
if [ -f "$HOME/.config/nvim/lua/tmux_workspace_resurrect.lua" ]; then
  pass "Neovim session integration is installed"
else
  fail "Neovim session integration is missing"
fi

if [ "$failures" -eq 0 ]; then
  tmux display-message "tmux-workspace-resurrect doctor: all checks passed" 2>/dev/null || true
else
  tmux display-message "tmux-workspace-resurrect doctor: $failures check(s) failed" 2>/dev/null || true
fi

exit "$failures"
