#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

failures=0

pass() {
  printf 'ok   %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

note() {
  printf 'note %s\n' "$1"
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

interval="$(tmux show-option -gqv @continuum-save-interval 2>/dev/null || true)"
if [ "$interval" = "$(jq -r '.autosave_interval_minutes' "$WORKSPACE_CONFIG_FILE" 2>/dev/null)" ]; then
  pass "Continuum interval is ${interval} minutes"
else
  fail "Continuum interval is not loaded from config.json"
fi

status_right="$(tmux show-option -gqv status-right 2>/dev/null || true)"
case "$status_right" in
  *continuum_save.sh*) pass "Continuum timer is present in status-right" ;;
  *) fail "Continuum timer is missing from status-right" ;;
esac

save_path="$(tmux show-option -gqv @resurrect-save-script-path 2>/dev/null || true)"
case "$save_path" in
  *tmux/scripts/resurrect_save.sh) pass "Continuum uses the verified save wrapper" ;;
  *) fail "Continuum does not use the verified save wrapper" ;;
esac

manual_binding="$(tmux list-keys -T prefix C-s 2>/dev/null || true)"
case "$manual_binding" in
  *manual_resurrect_save.sh*'#{@rw-worker}'*) pass "manual save binding is remote-aware" ;;
  *) fail "manual save binding is not remote-aware" ;;
esac

save_hook="$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null || true)"
restore_hook="$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null || true)"
case "$save_hook" in
  *tmux-workspace-resurrect/scripts/save.sh*) pass "Resurrect save hook is installed" ;;
  *) fail "Resurrect save hook is missing" ;;
esac
case "$restore_hook" in
  *tmux-workspace-resurrect/scripts/restore.sh*) pass "Resurrect restore hook is installed" ;;
  *) fail "Resurrect restore hook is missing" ;;
esac

if [ "$(tmux show-option -gqv @resurrect-processes 2>/dev/null)" = "false" ]; then
  pass "Resurrect process replay is disabled"
else
  fail "Resurrect process replay must be false"
fi

# Worker save timer: informational, not a failure. tmux-continuum's own
# status-line autosave already covers a machine with an attached, rendering
# client (the laptop) -- see initial-plan.md, "Remote-side tmux durability".
# This timer only matters on a fully detached headless worker, and this
# script has no reliable way to tell "am I running as the laptop or a
# worker right now", so an absent timer here is expected/fine, not a bug.
case "$(uname -s 2>/dev/null)" in
  Darwin)
    if launchctl print "gui/$(id -u)/com.kalem.tmux-resurrect-save" >/dev/null 2>&1; then
      pass "worker save timer (launchd com.kalem.tmux-resurrect-save) is loaded"
    else
      note "worker save timer (launchd com.kalem.tmux-resurrect-save) is not loaded -- expected on a worker; Continuum covers a laptop with an attached client"
    fi
    ;;
  Linux)
    if systemctl --user is-active --quiet tmux-resurrect-save.timer 2>/dev/null; then
      pass "worker save timer (systemd tmux-resurrect-save.timer) is active"
    else
      note "worker save timer (systemd tmux-resurrect-save.timer) is not active -- expected on a worker; Continuum covers a laptop with an attached client"
    fi
    ;;
  *)
    note "worker save timer check skipped on unrecognized platform"
    ;;
esac

# client-detached hook: best-effort immediate save on clean detach, on top
# of (never a substitute for) the periodic timer above -- see
# tmux-workspace-resurrect.tmux.
detached_hook="$(tmux show-hooks -g 2>/dev/null | grep '^client-detached')"
case "$detached_hook" in
  *scripts/resurrect_save.sh*) pass "verified client-detached save hook is present" ;;
  *) fail "client-detached save hook is missing" ;;
esac

if jq -e '.hooks.SessionStart[]?.hooks[]? |
  select(.command | contains("record-agent-session.sh") and endswith("claude"))' \
  "$HOME/.claude/settings.json" >/dev/null 2>&1; then
  pass "Claude SessionStart hook is declared"
else
  fail "Claude SessionStart hook is missing"
fi

if jq -e '.hooks.SessionStart[]?.hooks[]? |
  select(.command | contains("record-agent-session.sh") and endswith("codex"))' \
  "$HOME/.codex/hooks.json" >/dev/null 2>&1; then
  pass "Codex SessionStart hook is declared"
else
  fail "Codex SessionStart hook is missing or not stowed"
fi

if [ -f "$HOME/.pi/agent/extensions/tmux-workspace-resurrect.ts" ]; then
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

sidecar="$(workspace_sidecar_file)"
if [ -f "$sidecar" ] && jq -e '.version == 1' "$sidecar" >/dev/null 2>&1; then
  pass "workspace sidecar is valid ($(jq '.panes | length' "$sidecar") panes)"
else
  fail "workspace sidecar has not been created yet"
fi

if [ "$failures" -eq 0 ]; then
  tmux display-message "tmux-workspace-resurrect doctor: all checks passed" 2>/dev/null || true
else
  tmux display-message "tmux-workspace-resurrect doctor: $failures check(s) failed" 2>/dev/null || true
fi

exit "$failures"
