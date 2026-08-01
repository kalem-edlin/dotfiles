#!/usr/bin/env bash
#
# Direct periodic save trigger for tmux-resurrect on a headless worker.
#
# Why this exists: tmux-continuum's autosave is a `#()` interpolation baked
# into `status-right`, evaluated only while some client is actively
# rendering the status line (see tmux-continuum/continuum.tmux and
# scripts/continuum_save.sh). A fully detached worker tmux server — the
# normal state for an always-on headless box with no attached SSH client —
# never renders a status line, so that interpolation never fires and the
# server never autosaves. This script is installed as the command body of a
# launchd user agent (macOS) / systemd user timer (Linux) so saves happen on
# a fixed interval independent of any client. See
# docs/tasks/tmux-remote-workspaces/initial-plan.md, "Remote-side tmux
# durability".
#
# It invokes tmux-resurrect's own save.sh entrypoint with the "quiet" flag —
# the exact same script and argument continuum's timer uses internally
# (continuum_save.sh -> fetch_and_run_tmux_resurrect_save_script -> runs
# "$resurrect_save_script_path" "quiet"). That entrypoint dumps sessions,
# windows, and panes, then calls the plugin's own `execute_hook
# "post-save-all"`, which chains into tmux-workspace-resurrect's
# scripts/save.sh (the sidecar that captures shell buffers, agent sessions,
# Neovim state, etc). One invocation here therefore drives the entire save
# chain — nothing else needs to be triggered separately.
#
# Verified (2026-07-31, on an attached-client laptop tmux server, as a
# stand-in for a fully detached worker): running this entrypoint directly
# with $TMUX unset — i.e. not "inside" any tmux client or pane, exactly the
# process context a launchd/systemd timer runs under — still produces a
# fresh resurrect snapshot AND an updated workspace sidecar. tmux's `tmux`
# CLI does not require $TMUX to find the server; it connects to the default
# socket the same way whether or not the caller is itself inside tmux. No
# `tmux run-shell` wrapping is needed or used, matching how continuum itself
# invokes the script (as a plain background subprocess of the server, not a
# pane command).
#
# Quiet by design: exits 0 with no output when no tmux SERVER is running
# (the common state between sessions on a worker) so the timer never spams
# logs. tmux-resurrect's own "quiet" flag suppresses its interactive
# spinner/status messages during the save itself. This is distinct from the
# tmux BINARY being missing/unresolvable, which is a real provisioning
# failure (see below) and is NOT treated quietly.
#
# --check mode: pass "--check" as the sole argument to validate that the
# tmux binary and the tmux-resurrect save entrypoint both resolve, without
# performing a save or any other side effect. Prints what it resolved to
# stdout and exits 0 on success, nonzero on failure. Used by
# setup/misc-headless.sh (and a doctor script) to prove, under a
# launchd-like minimal environment (env -i HOME=... PATH=/usr/bin:/bin),
# that this wrapper will actually work when launchd invokes it — not just
# that it works in the provisioning shell's environment.

set -u

TMUX_BIN="${TMUX_RESURRECT_SAVE_TMUX_BIN:-tmux}"
PLUGIN_DIR="${TMUX_RESURRECT_SAVE_PLUGIN_DIR:-$HOME/.config/tmux/plugins/tmux-resurrect}"
SAVE_SCRIPT="$PLUGIN_DIR/scripts/save.sh"

if [ "${1:-}" = "--check" ]; then
  RESOLVED_TMUX="$(command -v "$TMUX_BIN" 2>/dev/null || true)"
  status=0

  if [ -z "$RESOLVED_TMUX" ]; then
    echo "tmux-resurrect-save --check: FAIL - tmux binary not resolvable (TMUX_RESURRECT_SAVE_TMUX_BIN=${TMUX_RESURRECT_SAVE_TMUX_BIN:-<unset>}, tried '$TMUX_BIN', PATH=$PATH)"
    status=1
  elif [ ! -x "$RESOLVED_TMUX" ]; then
    echo "tmux-resurrect-save --check: FAIL - resolved tmux is not executable: $RESOLVED_TMUX"
    status=1
  else
    echo "tmux-resurrect-save --check: tmux binary OK: $RESOLVED_TMUX"
  fi

  if [ ! -f "$SAVE_SCRIPT" ]; then
    echo "tmux-resurrect-save --check: FAIL - resurrect save script not found: $SAVE_SCRIPT"
    status=1
  elif [ ! -x "$SAVE_SCRIPT" ]; then
    echo "tmux-resurrect-save --check: FAIL - resurrect save script not executable: $SAVE_SCRIPT"
    status=1
  else
    echo "tmux-resurrect-save --check: save script OK: $SAVE_SCRIPT"
  fi

  if [ "$status" -eq 0 ]; then
    echo "tmux-resurrect-save --check: OK"
  fi
  exit "$status"
fi

if ! command -v "$TMUX_BIN" >/dev/null 2>&1; then
  # The tmux BINARY itself is missing/unresolvable. Under launchd this
  # almost always means TMUX_RESURRECT_SAVE_TMUX_BIN was never set (or
  # points at a stale/wrong path) — i.e. a real provisioning failure, not
  # the benign "no server running" state below. Log it loudly and fail so
  # launchd surfaces the job as erroring instead of silently no-op'ing.
  echo "tmux-resurrect-save: ERROR - tmux binary not found/executable (TMUX_RESURRECT_SAVE_TMUX_BIN=${TMUX_RESURRECT_SAVE_TMUX_BIN:-<unset>}, tried '$TMUX_BIN', PATH=$PATH)" >&2
  exit 1
fi

# No server running is the ordinary, expected state between endpoint
# sessions on a worker — exit quietly rather than treating it as a failure.
if ! "$TMUX_BIN" list-sessions >/dev/null 2>&1; then
  exit 0
fi

if [ ! -f "$SAVE_SCRIPT" ]; then
  echo "tmux-resurrect-save: save script not found at $SAVE_SCRIPT" >&2
  exit 1
fi

exec bash "$SAVE_SCRIPT" quiet
