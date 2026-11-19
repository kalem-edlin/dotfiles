#!/usr/bin/env bash
# Backs the `prefix e` binding (tmux.reset.conf): ONE display-popup with ONE
# menu for the focused (origin) pane (docs/tasks/remote-owned-directories.md,
# "Pane host switching", S1, D19-D20, D26, CS5).
#
# The pane's directory is resolved first (rw_pick_pane_dir): a local pane's
# pane_current_path; a remote pane's live worker cwd (its pane_title, when
# that is an absolute path) mapped back to this machine through the
# endpoint's worker root / home, else the endpoint's focus path. Its root is
# the enclosing worker-owned root, else rw_default_root_for_path. The owner
# host is that record's worker, else this machine; the pane host is
# @remote-host, else this machine.
#
# The menu (fzf, the worker chooser's look), its header naming the directory,
# the root, the pane host and the owner host:
#   - soft-switch rows first, one per host other than the pane's own (this
#     machine and every configured worker), the owner first, so enter picks
#     it: `rw switch --pane <origin> --to <alias|local> --dir <dir>`. Only
#     the pane changes host; no files move. With an agent in the pane, a row
#     whose destination is not the owner warns that the agent would work on
#     a copy that does not own the directory.
#   - the full-transfer row last. A worker-owned root: "hand back <root> to
#     this machine" (`rw bg handback --pane <origin>`), from any pane, local
#     or remote. A root this machine owns: "hand off <root> to remote", then
#     the worker chooser, skipped when exactly one worker is configured
#     (`rw bg handoff --worker <alias> --pane <origin>`).
# Choosing a row is the confirmation; there is no y/n. Esc moves nothing.
#
# The picker runs only `rw switch`, `rw bg handoff` and `rw bg handback`
# (CS5); it never creates endpoints itself. Transfers run in the BACKGROUND
# (libexec/rw-bg): once chosen, rw bg checks the root and returns, and the
# popup closes at once. Progress shows in the status line (@rw-transfer
# chip) and display-message; a conflict or failure opens its dialog from the
# runner. A refusal rw bg finds synchronously is shown here, inline. `rw
# switch` (no sync, quick) runs in the popup; its exits: 0 done, 6 the
# destination is unreachable, 7 refused with one `rw: <reason>` line, 1
# failed with the pane left as it was.
#
# rw is always RUN from here, never typed into a pane with send-keys: a
# remote pane's foreground is an ssh PTY into the worker, where anything
# typed runs on the worker's own shell (2026-08-05). TMUX_PANE is unset for
# the run, so rw acts on the --pane it is given, not on the popup.
#
# Failures and refusals are dismissible dialogs drawn inline in this popup:
# display-popup from inside a popup is a no-op (tmux draws one overlay per
# client), so rw_dialog cannot be used here.
#
# Modes (self-invocations; the binding only ever calls `pick`):
#   pick [pane]        act on the focused pane (or <pane>)
#   rows <pane>        print the menu rows (key<TAB>label<TAB>status<TAB>note)
#   header <pane>      print the menu header
#   probe-rows <file>  the rows in <file> with live reachability filled in
#   list               emit worker lines instantly (reachability pending)
#   probe              emit the same lines with live online/offline status
#
# Both menus render immediately; fzf's start event reloads them from the
# probe modes (parallel `ssh -o BatchMode=yes` probes bounded by the
# config's status timeout), so reachability fills in without delaying the
# popup. The menu reloads with reload-sync and probe-rows keeps the row
# order, so the first row (the owner) stays under the cursor. In the worker
# chooser, typed text that matches no listed worker is passed through as an
# alias on enter (--print-query); rw rejects aliases not in config.json.
#
# Test seams: RW_PICKER_RW_BIN (the rw to run), RW_PICKER_FZF (the fzf).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"
# shellcheck source=../libexec/rw-dialogs.sh
source "$SCRIPT_DIR/../libexec/rw-dialogs.sh"

mode="${1:-pick}"
RW_BIN="${RW_PICKER_RW_BIN:-$SCRIPT_DIR/rw}"
RW_FZF="${RW_PICKER_FZF:-fzf}"
RW_PICK_SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
RW_PICK_US=$'\037'
RW_PICK_AGENT_WARNING="⚠ the agent will work on a copy that does not own this directory"

# --- Worker list (the handoff chooser) ----------------------------------------

worker_line() { # alias platform status notes
  printf '%s\t[%s]\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

# Configured workers, as alias<TAB>platform<TAB>notes; $RW_PICK_FIRST (an
# alias) is listed first when set.
rw_pick_workers_tsv() {
  jq -r --arg first "${RW_PICK_FIRST:-}" '
    .workers // [] | (map(select(.alias == $first)) + map(select(.alias != $first)))[]
    | [.alias, .platform, (.notes // "")] | @tsv' "$RW_CONFIG_FILE"
}

# rw_pick_worker_aliases -- one configured alias per line, config order.
rw_pick_worker_aliases() {
  jq -r '.workers // [] | .[].alias' "$RW_CONFIG_FILE" 2>/dev/null
}

list_workers() {
  rw_pick_workers_tsv |
    while IFS=$'\t' read -r alias platform notes; do
      worker_line "$alias" "$platform" "…" "$notes"
    done
}

# Each probe prints its own finished line (one printf, atomic well under
# PIPE_BUF) so fzf's reload streams results in completion order: reachable
# workers appear in ~a round trip instead of every row waiting out the
# slowest host's timeout (2026-08-05).
probe_workers() {
  local alias platform notes
  while IFS=$'\t' read -r alias platform notes; do
    (
      if rw_ssh_batch "$alias" "$(rw_ssh_status_timeout)" true >/dev/null 2>&1; then
        worker_line "$alias" "$platform" "online" "$notes"
      else
        worker_line "$alias" "$platform" "offline" "$notes"
      fi
    ) &
  done < <(rw_pick_workers_tsv)
  wait
}

# rw_pick_worker_menu <prompt> <header>
# fzf over the worker list. Prints the chosen (or typed, unmatched) alias;
# prints nothing and returns 1 on abort (esc/ctrl-c) or an empty pick.
rw_pick_worker_menu() {
  local prompt="$1" header="$2" out status sel alias
  out="$(list_workers | "$RW_FZF" \
    --layout=reverse --info=inline \
    --prompt="$prompt" \
    --header="$header" \
    --delimiter=$'\t' \
    --print-query \
    --bind "start:reload:$(printf '%q' "$RW_PICK_SELF") probe")"
  status=$?
  case "$status" in
    0) sel="$(printf '%s\n' "$out" | tail -n1)" ;; # picked a listed worker
    1) sel="$(printf '%s\n' "$out" | head -n1)" ;; # typed alias, no match
    *) return 1 ;;                                 # aborted (esc / ctrl-c)
  esac
  alias="${sel%%$'\t'*}"
  alias="${alias//[[:space:]]/}"
  [ -n "$alias" ] || return 1
  printf '%s\n' "$alias"
}

# --- Display helpers ----------------------------------------------------------

# rw_pick_tilde <path> -- ~/... under $HOME, for display only.
# shellcheck disable=SC2088 # a literal ~ is the point
rw_pick_tilde() {
  case "$1" in
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# rw_pick_plural <n> <noun> -- "1 pane", "3 panes".
rw_pick_plural() { rw_dlg_plural "$@"; }

# rw_pick_host_name <alias|""> -- how a host is named in the header: this
# machine, or remote (<alias>) (C7: never a host name; the alias is the
# config.json one).
rw_pick_host_name() {
  if [ -n "$1" ]; then printf 'remote (%s)' "$1"; else printf 'this machine'; fi
}

# rw_pick_notice <title> <message> -- an inline dismissible notice in this
# popup. Not rw_dialog: that opens a display-popup, and tmux keeps one
# overlay per client (cmd-display-menu.c returns early while
# c->overlay_draw is set), so from inside this popup it would draw nothing.
rw_pick_notice() {
  printf '\n\033[1m%s\033[0m\n' "$1"
  printf '%s\n' "$2" | fold -s -w "$(rw_pick_cols)" | sed 's/^/  /'
  printf '\n  [press any key to dismiss]\n'
  read -r -s -n 1 2>/dev/null </dev/tty || true
}

# rw_pick_cols -- the popup's width less a margin, for wrapping notices.
rw_pick_cols() {
  local cols
  cols="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  case "$cols" in '' | *[!0-9]*) cols=80 ;; esac
  [ "$cols" -gt 20 ] || cols=80
  printf '%d\n' $((cols - 4))
}

# Hold the popup open as a dismissible DIALOG explaining the failure in one
# cause line and one action line. Never a status-bar display-message:
# refusals flashed there were unreadable (2026-08-05, 2026-08-06; operator
# 2026-08-08: "a dialog I can dismiss, not useless text in the command bar").
rw_pick_failure_dialog() {
  local label="$1" cause="$2" action="$3"
  printf '\n\033[1m%s failed\033[0m\n  cause:  %s\n  action: %s\n\n  [press any key to dismiss]\n' \
    "$label" "$cause" "$action"
  read -r -s -n 1 2>/dev/null </dev/tty || true
}

# --- The pane: directory, root, hosts ---------------------------------------------

# rw_pick_map_worker_path <worker path> <worker_root> <root_local> <root_rel> <worker_home>
# A worker path back on this machine: under the worker root to the local
# root, else under the worker home to $HOME; nothing otherwise.
rw_pick_map_worker_path() {
  local cwd="$1" worker_root="${2%/}" root_local="${3%/}" root_rel="$4" worker_home="${5%/}"
  if [ -n "$worker_root" ] && [ -n "$root_local" ]; then
    case "$cwd" in
      "$worker_root") printf '%s\n' "$root_local"; return 0 ;;
      "$worker_root"/*) printf '%s\n' "$root_local${cwd#"$worker_root"}"; return 0 ;;
    esac
  fi
  if [ -z "$worker_home" ] && [ -n "$worker_root" ] && [ -n "$root_rel" ]; then
    worker_home="${worker_root%"/$root_rel"}"
    [ "$worker_home" != "$worker_root" ] || worker_home=""
  fi
  if [ -n "$worker_home" ]; then
    case "$cwd" in
      "$worker_home") printf '%s\n' "$HOME"; return 0 ;;
      "$worker_home"/*) printf '%s\n' "$HOME${cwd#"$worker_home"}"; return 0 ;;
    esac
  fi
  return 0
}

# rw_pick_pane_dir <pane> -- the pane's directory on this machine (S1).
# Local pane: pane_current_path. Remote pane: its live worker cwd (the
# pane_title the endpoint session pushes, trusted only when it is an
# absolute path, as the directory chip does) mapped back through the
# endpoint's worker root / worker home; else the endpoint's focus path.
# RECONCILE AT MERGE: X1's shared resolver (scripts/common.sh) computes the
# same thing for `rw switch --dir`; this one can be replaced by it.
rw_pick_pane_dir() {
  local pane="$1" host endpoint title cwd fields focus worker_root root_local root_rel worker_home mapped=""
  host="$(rw_pane_get "$pane" @remote-host)"
  cwd="$(tmux display-message -pt "$pane" -F '#{pane_current_path}' 2>/dev/null || true)"
  if [ -z "$host" ]; then
    printf '%s\n' "$cwd"
    return 0
  fi
  endpoint="$(rw_pane_get "$pane" @rw-endpoint)"
  fields=""
  [ -n "$endpoint" ] && fields="$(rw_read_endpoint "$endpoint" 2>/dev/null | jq -r --arg us "$RW_PICK_US" '
    [.workspace.focus_path // .workspace.root_local // "", .workspace.worker_root // "",
     .workspace.root_local // "", .root_rel // "", .workspace.worker_home // .worker_home // ""] | join($us)' 2>/dev/null)"
  IFS="$RW_PICK_US" read -r focus worker_root root_local root_rel worker_home <<<"$fields"
  title="$(tmux display-message -pt "$pane" -F '#{pane_title}' 2>/dev/null || true)"
  case "$title" in
    /*) mapped="$(rw_pick_map_worker_path "$title" "$worker_root" "$root_local" "$root_rel" "$worker_home")" ;;
  esac
  if [ -n "$mapped" ]; then
    printf '%s\n' "$mapped"
  elif [ -n "$focus" ]; then
    printf '%s\n' "$focus"
  else
    printf '%s\n' "$cwd"
  fi
}

# rw_pick_context <pane> -- resolves the pane once into:
#   P_PANE P_HOST (alias, or "" for this machine) P_DIR P_ROOT P_ROOT_ID
#   (worker-owned record, or "") P_OWNER (alias, or "") P_AGENT (claude|pi
#   or "") P_EDITOR (nvim|vim|vi or "") P_ROOT_OK (1 when the root may be
#   handed off: under ~, not ~) P_ROOT_PANES (panes that move with a
#   transfer) P_ROOT_EDITORS (editors among them)
rw_pick_context() {
  local pane="$1" record kind pid cmd panes
  P_PANE="$pane"
  P_HOST="$(rw_pane_get "$pane" @remote-host)"
  P_DIR="$(rw_pick_pane_dir "$pane")"
  P_ROOT_ID="" P_OWNER="" P_ROOT="" P_ROOT_OK=0 P_ROOT_PANES=0 P_ROOT_EDITORS=0
  if [ -n "$P_DIR" ] && P_ROOT_ID="$(rw_owned_root_for_path "$P_DIR")"; then
    record="$(rw_owned_record_read "$P_ROOT_ID" 2>/dev/null || true)"
    P_ROOT="$(printf '%s' "$record" | jq -r '.root_local // empty' 2>/dev/null)"
    P_OWNER="$(printf '%s' "$record" | jq -r '.worker // empty' 2>/dev/null)"
    # shellcheck disable=SC2046 # endpoint ids are fixed-format hex
    P_ROOT_PANES="$(rw_root_bound_panes "$P_ROOT_ID" $(printf '%s' "$record" | jq -r '.endpoints[]?' 2>/dev/null) | grep -c . || true)"
  else
    P_ROOT_ID=""
  fi
  if [ -z "$P_ROOT" ] && [ -n "$P_DIR" ]; then
    P_ROOT="$(rw_default_root_for_path "$P_DIR")"
  fi
  if [ -z "$P_OWNER" ] && [ -n "$P_ROOT" ] && rw_root_rel "$P_ROOT" >/dev/null 2>&1; then
    P_ROOT_OK=1
    # Local panes only: they are what a hand-off moves; a remote (visit)
    # pane in the root keeps its own endpoint.
    panes="$(rw_root_panes "$P_ROOT" | awk -F '\t' '$6 == ""')"
    P_ROOT_PANES="$(printf '%s\n' "$panes" | grep -c . || true)"
    P_ROOT_EDITORS="$(printf '%s\n' "$panes" | awk -F '\t' '$8 == "nvim" || $8 == "vim" || $8 == "vi"' | grep -c . || true)"
  fi

  # An agent in the pane: a remote pane's mirrored @agent_kind (B2 clears it
  # when the worker agent is gone); a local pane's, while its @agent_pid
  # lives.
  P_AGENT="" P_EDITOR=""
  kind="$(rw_pane_get "$pane" @agent_kind)"
  if [ -n "$kind" ]; then
    if [ -n "$P_HOST" ]; then
      P_AGENT="$kind"
    else
      pid="$(rw_pane_get "$pane" @agent_pid)"
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && P_AGENT="$kind"
    fi
  fi
  if [ -z "$P_HOST" ]; then
    cmd="$(tmux display-message -pt "$pane" -F '#{pane_current_command}' 2>/dev/null || true)"
    case "$cmd" in nvim | vim | vi) P_EDITOR="$cmd" ;; esac
  fi
}

# --- The menu -----------------------------------------------------------------

# rw_pick_rows -- the menu rows for the resolved context, one per line:
#   key<TAB>label<TAB>status<TAB>note
# key: switch:local, switch:<alias>, handback or handoff. status: "…" on a
# worker row until probe-rows fills it in. Labels are padded to one width so
# the status column lines up.
rw_pick_rows() {
  local -a keys=() labels=() notes=() dests=()
  local d w i width=0 label note status
  # Destinations: every host but the pane's own, the owner first.
  [ "${P_OWNER:-local}" != "${P_HOST:-local}" ] && dests+=("${P_OWNER:-local}")
  [ -n "$P_HOST" ] && [ -n "$P_OWNER" ] && dests+=(local)
  while IFS= read -r w; do
    [ -n "$w" ] && [ "$w" != "$P_HOST" ] && [ "$w" != "$P_OWNER" ] && dests+=("$w")
  done < <(rw_pick_worker_aliases)

  for d in "${dests[@]+"${dests[@]}"}"; do
    if [ "$d" = local ]; then label="switch this pane to this machine"; else label="switch this pane to $d"; fi
    [ "$d" = "${P_OWNER:-local}" ] && label="$label (owner)"
    note=""
    [ -n "$P_AGENT" ] && [ "$d" != "${P_OWNER:-local}" ] && note="$RW_PICK_AGENT_WARNING"
    keys+=("switch:$d") labels+=("$label") notes+=("$note")
  done

  if [ -n "$P_OWNER" ]; then
    label="hand back $(rw_pick_tilde "$P_ROOT") to this machine"
    [ "${P_ROOT_PANES:-0}" -gt 1 ] && label="$label ($(rw_pick_plural "$P_ROOT_PANES" pane) come back)"
    keys+=(handback) labels+=("$label") notes+=("")
  elif [ "$P_ROOT_OK" = 1 ] && [ -n "$(rw_pick_worker_aliases)" ]; then
    label="hand off $(rw_pick_tilde "$P_ROOT") to remote"
    [ "${P_ROOT_PANES:-0}" -gt 1 ] && label="$label ($(rw_pick_plural "$P_ROOT_PANES" pane) move)"
    keys+=(handoff) labels+=("$label") notes+=("")
  fi

  for label in "${labels[@]+"${labels[@]}"}"; do
    [ "${#label}" -gt "$width" ] && width="${#label}"
  done
  for i in "${!keys[@]}"; do
    status=""
    case "${keys[$i]}" in switch:local | handback | handoff) ;; switch:*) status="…" ;; esac
    printf '%s\t%-*s\t%s\t%s\n' "${keys[$i]}" "$width" "${labels[$i]}" "$status" "${notes[$i]}"
  done
}

# rw_pick_header -- names the directory, the root, the pane host and the
# owner host; then what a choice would cost.
rw_pick_header() {
  local dir root
  dir="$(rw_pick_tilde "$P_DIR")"
  root="$(rw_pick_tilde "$P_ROOT")"
  if [ "$P_DIR" = "$P_ROOT" ]; then
    printf '%s (root)\n' "$dir"
  else
    printf '%s  ·  root %s\n' "$dir" "$root"
  fi
  printf 'pane on %s  ·  owned by %s\n' "$(rw_pick_host_name "$P_HOST")" "$(rw_pick_host_name "$P_OWNER")"
  [ -n "$P_EDITOR" ] && printf '%s reopens on the destination, but unsaved buffers do not travel: save first\n' "$P_EDITOR"
  if [ -z "$P_OWNER" ] && [ "${P_ROOT_EDITORS:-0}" -gt 0 ] && [ -z "$P_EDITOR" ]; then
    printf 'a hand-off moves editors too, but unsaved buffers do not: save first\n'
  fi
  if [ -z "$P_OWNER" ] && [ "$P_ROOT_OK" != 1 ]; then
    printf '%s cannot be handed off: only directories under ~ (not ~ itself) can\n' "$root"
  fi
  return 0
}

# probe_rows <rows file> -- the same rows, in the same order, each worker
# row's status set to online or offline. Probes run in parallel; the rows
# are printed once all have answered (fzf reload-sync keeps the instant list
# until then), so the order and the cursor never move.
probe_rows() {
  local file="$1" dir n=0 key line label note alias
  dir="$(mktemp -d "${TMPDIR:-/tmp}/rw-picker-probe.XXXXXX")" || {
    cat "$file"
    return 0
  }
  while IFS= read -r line; do
    key="${line%%$'\t'*}"
    n=$((n + 1))
    case "$key" in
      switch:local | handback | handoff | '') ;;
      switch:*)
        alias="${key#switch:}"
        (
          if rw_ssh_batch "$alias" "$(rw_ssh_status_timeout)" true >/dev/null 2>&1; then
            echo online >"$dir/$n"
          else
            echo offline >"$dir/$n"
          fi
        ) &
        ;;
    esac
  done <"$file"
  wait
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [ -f "$dir/$n" ]; then
      # Split by hand: `read` would trim the label's padding and collapse
      # the empty status field.
      key="${line%%$'\t'*}"
      line="${line#*$'\t'}"
      label="${line%%$'\t'*}"
      line="${line#*$'\t'}"
      note="${line#*$'\t'}"
      printf '%s\t%s\t%s\t%s\n' "$key" "$label" "$(cat "$dir/$n")" "$note"
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
  rm -rf "$dir"
}

# --- Actions ------------------------------------------------------------------

# rw_pick_bg <verb> <args...>
# `rw bg <verb> <args...>`: rw bg checks the root and returns at once, the
# transfer runs detached, and the popup closes. A synchronous refusal (the
# root is invalid, already moving, ...) is shown inline instead.
rw_pick_bg() {
  local verb="$1" out status
  shift
  out="$(env -u TMUX_PANE "$RW_BIN" bg "$verb" "$@" </dev/null 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && exit 0
  rw_pick_notice "rw $verb not started" "$(printf '%s\n' "$out" | grep '^rw' | tail -n 1 | sed 's/^rw: //')"
  exit "$status"
}

# rw_pick_switch <dest> -- `rw switch` for the origin pane, output live in
# the popup; any failure held open as a dialog.
rw_pick_switch() {
  local dest="$1" out status refusal where
  out="$(mktemp "${TMPDIR:-/tmp}/rw-picker-run.XXXXXX")"
  env -u TMUX_PANE "$RW_BIN" switch --pane "$P_PANE" --to "$dest" --dir "$P_DIR" </dev/null 2>&1 | tee "$out"
  status=${PIPESTATUS[0]}
  refusal="$(grep '^rw: ' "$out" | tail -n 1 | sed 's/^rw: //')"
  rm -f "$out"
  where="$dest"
  [ "$dest" = local ] && where="this machine"
  case "$status" in
    0) exit 0 ;;
    6)
      rw_pick_failure_dialog "rw switch" "$where is unreachable over ssh; the pane is unchanged" \
        "check the worker is awake and on the network, then retry"
      ;;
    7) rw_pick_notice "rw switch refused" "${refusal:-the pane cannot switch to $where now}" ;;
    *)
      rw_pick_failure_dialog "rw switch" "${refusal:-unrecognized failure (exit $status)}" \
        "the pane was left as it was; run 'rw switch --pane $P_PANE --to $dest' from a shell to see its output"
      ;;
  esac
  exit "$status"
}

# rw_pick_handoff -- the worker chooser (skipped with exactly one worker,
# D26), then `rw bg handoff`.
rw_pick_handoff() {
  local workers n alias header note
  workers="$(rw_pick_worker_aliases)"
  n="$(printf '%s\n' "$workers" | grep -c . || true)"
  if [ "$n" -eq 1 ]; then
    alias="$workers"
  else
    note="$(rw_pick_plural "$P_ROOT_PANES" pane) working in it move to the chosen worker (any session)"
    [ "$P_ROOT_PANES" -le 1 ] && note="this pane moves to the chosen worker; nothing else works in it"
    header="hand off $(rw_pick_tilde "$P_ROOT")"$'\n'"$note"
    [ "$P_ROOT_EDITORS" -gt 0 ] && header="$header"$'\n'"editors move too, but unsaved buffers do not: save first"
    alias="$(RW_PICK_FIRST="$P_HOST" rw_pick_worker_menu 'rw handoff ⇒ ' "$header")" || exit 0
  fi
  rw_pick_bg handoff --worker "$alias" --pane "$P_PANE"
}

# rw_pick_menu -- the S1 menu; prints the chosen key, nothing on abort.
rw_pick_menu() {
  local rows header sel
  rows="$(mktemp "${TMPDIR:-/tmp}/rw-picker-rows.XXXXXX")" || return 1
  rw_pick_rows >"$rows"
  if [ ! -s "$rows" ]; then
    rm -f "$rows"
    rw_pick_notice "Remote workspace" "Nothing to offer here: no remote worker is configured in config.json ($RW_CONFIG_FILE)."
    return 1
  fi
  header="$(rw_pick_header)"
  sel="$("$RW_FZF" \
    --layout=reverse --info=inline --no-sort --no-multi \
    --prompt='rw ⇒ ' \
    --header="$header" \
    --delimiter=$'\t' --with-nth=2.. \
    --bind "start:reload-sync:$(printf '%q' "$RW_PICK_SELF") probe-rows $(printf '%q' "$rows")" \
    <"$rows")"
  rm -f "$rows"
  sel="${sel%%$'\t'*}"
  [ -n "$sel" ] || return 1
  printf '%s\n' "$sel"
}

pick() {
  local origin_pane="${1:-}" key
  if ! command -v jq >/dev/null 2>&1 || ! command -v "$RW_FZF" >/dev/null 2>&1; then
    rw_pick_notice "Remote workspace" "prefix e needs jq and fzf on the tmux server's PATH; one of them is missing."
    exit 0
  fi
  if ! rw_config_valid; then
    rw_pick_notice "Remote workspace" "config.json ($RW_CONFIG_FILE) is invalid."
    exit 0
  fi

  # Resolve the invoking pane BEFORE fzf: inside a popup, display-message
  # with no target resolves against the client's active pane, which is
  # exactly the pane the popup was opened over.
  [ -n "$origin_pane" ] || origin_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  [ -n "$origin_pane" ] || exit 0
  rw_pick_context "$origin_pane"
  if [ -z "$P_DIR" ]; then
    rw_pick_notice "Remote workspace" "Could not tell which directory this pane is in."
    exit 0
  fi

  key="$(rw_pick_menu)" || exit 0
  case "$key" in
    switch:*) rw_pick_switch "${key#switch:}" ;;
    handback) rw_pick_bg handback --pane "$P_PANE" ;;
    handoff) rw_pick_handoff ;;
  esac
  exit 0
}

case "$mode" in
  list) list_workers ;;
  probe) probe_workers ;;
  probe-rows) probe_rows "${2:?rw-picker: probe-rows needs a rows file}" ;;
  rows)
    rw_pick_context "${2:?rw-picker: rows needs a pane id}"
    rw_pick_rows
    ;;
  header)
    rw_pick_context "${2:?rw-picker: header needs a pane id}"
    rw_pick_header
    ;;
  pick) pick "${2:-}" ;;
  *) rw_die "rw-picker: unknown mode: $mode" 64 ;;
esac
