#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

dry_run="false"
if [ "${1:-}" = "--dry-run" ] || [ "${TMUX_WORKSPACE_RESURRECT_DRY_RUN:-}" = "1" ]; then
  dry_run="true"
fi

restore_result_file="${TMUX_WORKSPACE_RESTORE_RESULT_FILE:-}"
if [ -n "$restore_result_file" ]; then
  rm -f -- "$restore_result_file"
fi

restore_timeout="$(jq -er '.restore_timeout_seconds | numbers' "$WORKSPACE_CONFIG_FILE" 2>/dev/null || echo 30)"
pane_timeout="$(jq -er '.restore_pane_timeout_seconds | numbers' "$WORKSPACE_CONFIG_FILE" 2>/dev/null || echo 2)"
case "$restore_timeout" in '' | *[!0-9]*) restore_timeout=30 ;; esac
case "$pane_timeout" in '' | *[!0-9]*) pane_timeout=2 ;; esac
[ "$restore_timeout" -gt 0 ] || restore_timeout=30
[ "$pane_timeout" -gt 0 ] || pane_timeout=2
restore_deadline=$(($(date +%s) + restore_timeout))
pane_timeout_ticks=$((pane_timeout * 10))
restore_config="$(jq -c '.' "$WORKSPACE_CONFIG_FILE" 2>/dev/null || printf '{}')"
launch_delay_ms="$(jq -er '.restore_whitelist.delay_ms | numbers' "$WORKSPACE_CONFIG_FILE" 2>/dev/null || echo 500)"
case "$launch_delay_ms" in '' | *[!0-9]*) launch_delay_ms=500 ;; esac
launch_delay_seconds="$(awk -v ms="$launch_delay_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
launch_delay_budget=$(((launch_delay_ms + 999) / 1000))

sidecar="$(workspace_sidecar_file)"
if [ ! -f "$sidecar" ] || ! jq -e '.version == 1' "$sidecar" >/dev/null 2>&1; then
  workspace_log "restore skipped: no valid workspace sidecar"
  exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-workspace-resurrect-restore.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mapping_file="$work_dir/pane-map.tsv"
sidebar_file="$work_dir/sidebar-logical-ids"
: >"$mapping_file"
: >"$sidebar_file"

restore_failed=false
while IFS= read -r logical_id; do
  pane_id="$(tmux display-message -pt "$logical_id" -F '#{pane_id}' 2>/dev/null || true)"
  if [ -n "$pane_id" ]; then
    printf '%s\t%s\n' "$logical_id" "$pane_id" >>"$mapping_file"
  else
    restore_failed=true
    workspace_log "restore mapping incomplete: pane missing for $logical_id"
  fi
done < <(jq -r '.panes[].logical_id' "$sidecar")

mapped_pane() {
  local logical_id="$1"
  awk -F '\t' -v logical="$logical_id" '$1 == logical { print $2; exit }' "$mapping_file"
}

if workspace_config_bool '.capture.treemux'; then
  while IFS=$'\t' read -r main_logical sidebar_logical treemux_args; do
    printf '%s\n' "$sidebar_logical" >>"$sidebar_file"
    main_pane="$(mapped_pane "$main_logical")"
    sidebar_pane="$(mapped_pane "$sidebar_logical")"
    if [ -z "$main_pane" ]; then
      restore_failed=true
      workspace_log "Treemux restore skipped for $main_logical: main pane missing"
      continue
    fi

    if [ "$dry_run" = "true" ]; then
      workspace_log "dry-run: Treemux mapping validated for $main_logical"
      continue
    fi

    if [ -n "$sidebar_pane" ] && tmux display-message -pt "$sidebar_pane" -F '#{pane_id}' >/dev/null 2>&1; then
      tmux kill-pane -t "$sidebar_pane"
    fi

    treemux_toggle="$HOME/.config/tmux/plugins/treemux/scripts/toggle.sh"
    if [ -x "$treemux_toggle" ]; then
      if ! "$treemux_toggle" "$treemux_args" "$main_pane" >/dev/null 2>&1; then
        restore_failed=true
        workspace_log "Treemux reconstruction failed for $main_logical"
      fi
    else
      restore_failed=true
      workspace_log "Treemux reconstruction skipped: toggle.sh unavailable"
    fi
  done < <(jq -r '.treemux[] | [.main_logical_id, .sidebar_logical_id, .args] | @tsv' "$sidecar")
fi

queued=0
launched=0
skipped=0
while IFS= read -r pane_record; do
  logical_id="$(printf '%s' "$pane_record" | jq -r '.logical_id')"
  # Command substitution removes trailing newlines. NUL-delimited jq output
  # preserves an unfinished multiline shell edit byte-for-byte.
  IFS= read -r -d '' selected_command < <(printf '%s' "$pane_record" | jq -j '.selected_command, "\u0000"') || true
  selected_source="$(printf '%s' "$pane_record" | jq -r '.selected_source')"
  pending_cursor="$(printf '%s' "$pane_record" | jq -r '.pending_cursor // 0')"

  if grep -Fqx "$logical_id" "$sidebar_file" 2>/dev/null || [ -z "$selected_command" ]; then
    continue
  fi

  policy_result="$(python3 "$SCRIPT_DIR/restore_policy.py" "$pane_record" "$restore_config" 2>/dev/null || printf '{"action":"ignore"}')"
  restore_action="$(jq -r '.action // "ignore"' <<<"$policy_result")"
  if [ "$restore_action" = "ignore" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore ignored for $logical_id: excluded agent command"
    continue
  fi

  pane_id="$(mapped_pane "$logical_id")"
  if [ -z "$pane_id" ]; then
    skipped=$((skipped + 1))
    restore_failed=true
    workspace_log "restore skipped for $logical_id: pane missing"
    continue
  fi

  # Generic restore opt-out seam: any plugin (e.g. tmux-remote-workspaces)
  # can set @workspace-resurrect-skip on a pane it manages so a recorded
  # command (e.g. a stale `ssh mini`) is never pasted into it. See
  # docs/tmux-remote-workspaces.md, "Persistence and reconciliation".
  if [ -n "$(tmux show-option -pt "$pane_id" -qv @workspace-resurrect-skip 2>/dev/null)" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore skipped for $logical_id: @workspace-resurrect-skip is set"
    continue
  fi

  launch_key="$(jq -r '.key // ""' <<<"$policy_result")"
  if [ "$restore_action" = "execute" ]; then
    policy_command="$(jq -r '.command // empty' <<<"$policy_result")"
    prior_launch="$(tmux show-option -pt "$pane_id" -qv @workspace-resurrect-launched-key 2>/dev/null || true)"
    if [ -z "$policy_command" ] || [ "$prior_launch" = "$launch_key" ]; then
      if [ "$prior_launch" = "$launch_key" ]; then
        workspace_log "restore launch skipped for $logical_id: already launched $launch_key"
        continue
      fi
      restore_action="queue"
    else
      selected_command="$policy_command"
    fi
  fi

  if [ "$dry_run" = "true" ]; then
    if [ "$restore_action" = "execute" ]; then
      launched=$((launched + 1))
      workspace_log "dry-run: launch candidate $logical_id from $selected_source"
    else
      queued=$((queued + 1))
      workspace_log "dry-run: queue candidate $logical_id from $selected_source"
    fi
    continue
  fi

  # Never append to or execute a prompt the user has already begun editing.
  # The live pane option is authoritative even when it matches this snapshot.
  if [ "$(tmux display-message -pt "$pane_id" '#{!=:#{@workspace-pending-buffer},}' 2>/dev/null)" = "1" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore skipped for $logical_id: live pending input exists"
    continue
  fi

  if [ "$(date +%s)" -ge "$restore_deadline" ]; then
    skipped=$((skipped + 1))
    restore_failed=true
    workspace_log "restore skipped for $logical_id: global ${restore_timeout}s readiness budget exhausted"
    continue
  fi

  shell_ready="false"
  attempt=0
  while [ "$attempt" -lt "$pane_timeout_ticks" ] && [ "$(date +%s)" -lt "$restore_deadline" ]; do
    pane_command="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
    if workspace_command_is_shell "$pane_command"; then
      shell_ready="true"
      break
    fi
    # An existing foreground application should not spend the readiness
    # budget intended for new shells, especially on a repeated restore.
    [ -z "$pane_command" ] || break
    sleep 0.1
    attempt=$((attempt + 1))
  done

  if [ "$shell_ready" != "true" ]; then
    skipped=$((skipped + 1))
    if [ -z "$pane_command" ]; then
      restore_failed=true
      workspace_log "restore skipped for $logical_id: pane did not become ready"
    else
      workspace_log "restore skipped for $logical_id: foreground process is already running"
    fi
    continue
  fi

  if [ "$restore_action" = "execute" ] && [ "$launched" -gt 0 ] && [ "$launch_delay_ms" -gt 0 ]; then
    sleep "$launch_delay_seconds"
    # Intentional pacing does not consume the bounded readiness budget.
    restore_deadline=$((restore_deadline + launch_delay_budget))
  fi
  # Bracketed-paste delivery needs BOTH halves right, learned the hard way
  # (2026-08-08: every queued pane restored as literal "^[[200~cmd^[[201~"
  # + "zsh: substitution failed", and the zsh buffer-capture hook then
  # re-saved the mangled text into the sidecar):
  #   1. paste-buffer's default vis(3) sanitization rewrites raw ESC bytes
  #      into the two-character text "^[" -- -S is required for the
  #      hand-rolled \e[200~ markers to reach the shell as control bytes.
  #   2. zsh only interprets those markers once ZLE has enabled bracketed
  #      paste; the shell-process check above passes well before that, so
  #      wait for the pane's own bracket_paste_flag.
  paste_ready="false"
  attempt=0
  while [ "$attempt" -lt "$pane_timeout_ticks" ] && [ "$(date +%s)" -lt "$restore_deadline" ]; do
    if [ "$(tmux display-message -pt "$pane_id" -F '#{bracket_paste_flag}' 2>/dev/null)" = "1" ]; then
      paste_ready="true"
      break
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done

  # Recheck after both pacing and shell-readiness waits, just before delivery.
  # A tmux boolean preserves even pending input consisting only of newlines.
  pane_command="$(tmux display-message -pt "$pane_id" -F '#{pane_current_command}' 2>/dev/null || true)"
  live_pending="$(tmux display-message -pt "$pane_id" '#{!=:#{@workspace-pending-buffer},}' 2>/dev/null || true)"
  if ! workspace_command_is_shell "$pane_command" || [ "$live_pending" = "1" ]; then
    skipped=$((skipped + 1))
    workspace_log "restore skipped for $logical_id: pane became active before delivery"
    continue
  fi

  buffer_name="workspace-resurrect-${pane_id#%}"
  cursor_moves=0
  if [ "$selected_source" = "pending-buffer" ] &&
    [[ "$pending_cursor" =~ ^[0-9]+$ ]] &&
    [ "$pending_cursor" -lt "${#selected_command}" ]; then
    cursor_moves=$((${#selected_command} - pending_cursor))
  fi
  cursor_restore_widget="false"
  if [ "$cursor_moves" -gt 0 ] &&
    [ "$(tmux show-option -pt "$pane_id" -qv @workspace-restore-cursor-widget 2>/dev/null || true)" = "1" ]; then
    tmux set-option -pt "$pane_id" @workspace-restore-cursor-target "$pending_cursor"
    cursor_restore_widget="true"
  fi
  if [ "$paste_ready" = "true" ]; then
    # Markers let embedded newlines join the editable shell buffer instead
    # of acting as Enter; -S delivers them unsanitized. Cursor keys share the
    # same ordered PTY write after the closing marker, so ZLE cannot finish a
    # later paste transaction after tmux has already sent the movements.
    {
      printf '\033[200~%s\033[201~' "$selected_command"
      if [ "$cursor_restore_widget" = "true" ]; then
        printf '\033[99~'
      elif [ "$cursor_moves" -gt 0 ]; then
        remaining_moves="$cursor_moves"
        while [ "$remaining_moves" -gt 0 ]; do
          printf '\033[D'
          remaining_moves=$((remaining_moves - 1))
        done
      fi
    } | tmux load-buffer -b "$buffer_name" -
    tmux paste-buffer -S -b "$buffer_name" -t "$pane_id" -d
  elif [ "$selected_command" = "${selected_command%%$'\n'*}" ]; then
    # No bracketed paste in sight (tmux without bracket_paste_flag, or a
    # shell that never enabled it): a single-line command needs no markers.
    printf '%s' "$selected_command" | tmux load-buffer -b "$buffer_name" -
    tmux paste-buffer -b "$buffer_name" -t "$pane_id" -d
  else
    skipped=$((skipped + 1))
    restore_failed=true
    workspace_log "restore skipped for $logical_id: bracketed paste unavailable and command is multiline"
    continue
  fi

  if [ "$paste_ready" != "true" ] && [ "$cursor_moves" -gt 0 ]; then
    tmux send-keys -N "$cursor_moves" -t "$pane_id" Left
  fi

  if [ "$restore_action" = "execute" ]; then
    tmux send-keys -t "$pane_id" Enter
    tmux set-option -pt "$pane_id" @workspace-resurrect-launched-key "$launch_key"
    launched=$((launched + 1))
    workspace_log "launched $selected_source in $logical_id"
  else
    tmux set-option -pt "$pane_id" @workspace-pending-buffer "$selected_command"
    tmux set-option -pt "$pane_id" @workspace-pending-cursor "${#selected_command}"
    if [ "$selected_source" = "pending-buffer" ] && [[ "$pending_cursor" =~ ^[0-9]+$ ]]; then
      tmux set-option -pt "$pane_id" @workspace-pending-cursor "$pending_cursor"
    fi
    queued=$((queued + 1))
    workspace_log "queued $selected_source in $logical_id"
  fi
done < <(jq -c '.panes[]' "$sidecar")

workspace_log "restore complete: launched=$launched queued=$queued skipped=$skipped dry_run=$dry_run"
if [ "$restore_failed" = "false" ] && [ "$dry_run" = "false" ] && [ -n "$restore_result_file" ]; then
  result_tmp="${restore_result_file}.tmp.$$"
  printf 'success\n' >"$result_tmp"
  mv -f -- "$result_tmp" "$restore_result_file"
fi
