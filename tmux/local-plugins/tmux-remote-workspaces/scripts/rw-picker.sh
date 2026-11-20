#!/usr/bin/env bash
# Backs the `prefix e` binding (tmux.reset.conf): ONE display-popup with ONE
# menu for the focused (origin) pane (docs/tasks/remote-owned-directories.md,
# "Pane host switching", S1, D19-D20, D26, CS5).
#
# The pane's directory is resolved first (rw_pick_context): a local pane's
# pane_current_path; a remote pane's live worker cwd and foreground command
# from rw_pane_remote_probe (one ssh with a HARD deadline, the status
# timeout), mapped back to this machine; when the remote does not answer in
# time, the title-based directory (rw_pane_dir without --live) and the pane
# is marked "remote unreachable". Owner and root: rw_owner_for_path (the
# chip's rules: the longest enclosing worker-owned root, a pending forget
# and another machine's mirror not counting), else rw_default_root_for_path
# of the directory, or of its nearest existing parent when the directory
# exists only on the remote (then only a root that encloses it: a
# worker-owned record or a git toplevel; otherwise no root, and no hand-off
# row). The owner host is that record's worker, else this machine; the pane
# host is @remote-host, else this machine.
#
# The menu (fzf), its header naming the directory and the root. Every row is
# one short line, never padded to a common width (the popup is a fixed size
# and a long label used to push the reachability status off its right edge):
#   <marker> <label>  <note>
# The marker is the first thing on a row: `…` (grey) while the destination
# is being probed, a green `●` online, a red `○` offline, two spaces for a
# row that needs no remote (this machine, hand back, release). The rows:
#   - soft-switch rows first, one per host other than the pane's own (this
#     machine and every configured worker), the owner first, so enter picks
#     it: `rw switch --pane <origin> --to <alias|local> --dir <dir>`. Only
#     the pane changes host; no files move. With an agent in the pane, a row
#     whose destination is not the owner carries the note `⚠ agent would work
#     on a non-owner copy`.
#   - the full-transfer rows last. A worker-owned root: one `hand back to
#     this machine` row (`rw bg handback --pane <origin> --root <root>`),
#     from any pane, local or remote. A root this machine owns: one `hand
#     off to <alias>` row per configured worker (`rw bg handoff --worker
#     <alias> --pane <origin> --root <root>`), the pane's own worker first.
#     Either label ends with `(N panes)` when more than one pane moves.
#     --root is always the root the header names, so a pane that cd'd out of
#     the root it was opened in moves the root it is in now.
#   - a remote pane whose remote is unreachable (or no longer in
#     config.json) gets no soft-switch row (each needs that remote) but
#     "release this pane to this machine (remote unreachable)" first: `rw
#     switch --pane <origin> --to local --force`. A transfer row that needs
#     that remote (a hand-back to it, a hand-off to it) is left out too.
# The header (muted, --color=header:..., not the user's FZF_DEFAULT_OPTS
# red): line 1 is `<dir> (root)` or `<dir>  ·  root <root>`; `pane on <host>
# ·  owned by <host>` follows only when the two hosts differ or the pane's
# remote is unreachable or unconfigured; warnings (unreachable remote, a
# directory only the remote has, a root that cannot be handed off) are
# yellow; when a hand-off row is offered and more than one pane would move,
# `moves: <session>:<window>.<pane> <command>, ...` names them.
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
#   pick [pane]               act on <pane> (the binding passes #{pane_id});
#                             with no pane, the popup client's active pane
#   rows <pane>               print the menu rows, machine form:
#                             key<TAB>status<TAB>label<TAB>note, status one
#                             of none, pending, online, offline
#   header <pane>             print the menu header (with ANSI colors)
#   render                    rows on stdin -> what fzf shows:
#                             key<TAB>marker, label and note (with ANSI)
#   probe-rows <file> [--raw] the rows in <file> with live reachability
#                             filled in, rendered (--raw: machine form)
#
# The menu renders immediately; fzf's start event reloads it from probe-rows
# (one parallel `ssh -o BatchMode=yes` probe per distinct worker, bounded by
# the config's status timeout), so reachability fills in without delaying
# the popup. The menu reloads with reload-sync and probe-rows keeps the row
# order, so the first row (the owner) stays under the cursor.
#
# Test seams: RW_PICKER_RW_BIN (the rw to run), RW_PICKER_FZF (the fzf),
# RW_PICKER_COLS (the popup width, else the tty's), RW_PICKER_STUBS (a file
# sourced after roots.sh: stand-ins for its helpers).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=roots.sh
source "$SCRIPT_DIR/roots.sh"
# shellcheck source=../libexec/rw-dialogs.sh
source "$SCRIPT_DIR/../libexec/rw-dialogs.sh"
if [ -n "${RW_PICKER_STUBS:-}" ]; then
  # shellcheck source=/dev/null
  source "$RW_PICKER_STUBS"
fi

mode="${1:-pick}"
RW_BIN="${RW_PICKER_RW_BIN:-$SCRIPT_DIR/rw}"
RW_FZF="${RW_PICKER_FZF:-fzf}"
RW_PICK_SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
RW_PICK_AGENT_WARNING="⚠ agent would work on a non-owner copy"

# rw_pick_worker_aliases -- one configured alias per line, config order.
rw_pick_worker_aliases() {
  jq -r '.workers // [] | .[].alias' "$RW_CONFIG_FILE" 2>/dev/null
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
  cols="${RW_PICKER_COLS:-$(stty size </dev/tty 2>/dev/null | awk '{print $2}')}"
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

# rw_pick_context <pane> -- resolves the pane once into:
#   P_PANE P_HOST (alias, or "" for this machine) P_DIR P_ROOT (may be ""
#   when the directory exists only on the remote) P_ROOT_ID (worker-owned
#   record, or "") P_OWNER (alias, or "") P_AGENT (claude|pi or "")
#   P_ROOT_OK (1 when the root may be handed off: under ~, not ~)
#   P_ROOT_PANES (panes that move with a transfer) P_ROOT_PANE_LIST (a
#   hand-off's panes, rw_root_panes lines) P_UNREACHABLE ("", "unreachable",
#   or "unconfigured" when @remote-host is not in config.json)
#   P_REMOTE_ONLY (1 when neither the directory nor a root enclosing it
#   exists on this machine)
rw_pick_context() {
  local pane="$1" line="" rc kind pid panes eps base
  P_PANE="$pane"
  P_HOST="$(rw_pane_get "$pane" @remote-host)"
  P_DIR="" P_UNREACHABLE="" P_REMOTE_ONLY=0
  if [ -n "$P_HOST" ]; then
    if ! rw_pick_worker_aliases | grep -qxF -- "$P_HOST"; then
      P_UNREACHABLE=unconfigured # never ssh to an alias config.json dropped
    else
      # One ssh with a hard deadline (I3): the live cwd (a pane_title can
      # lag a worker-side cd by over a minute).
      line="$(rw_pane_remote_probe "$pane" 2>/dev/null)"
      rc=$?
      case "$rc" in
        0) P_DIR="${line%%$'\t'*}" ;;
        6) P_UNREACHABLE=unreachable ;;
      esac
    fi
  fi
  # The title, else the endpoint's focus path, else pane_current_path.
  [ -n "$P_DIR" ] || P_DIR="$(rw_pane_dir "$pane")"

  P_ROOT_ID="" P_OWNER="" P_ROOT="" P_ROOT_OK=0 P_ROOT_PANES=0 P_ROOT_PANE_LIST=""
  if [ -n "$P_DIR" ] && line="$(rw_owner_for_path "$P_DIR" 2>/dev/null)" && [ -n "$line" ]; then
    IFS=$'\t' read -r P_ROOT_ID P_OWNER P_ROOT <<<"$line"
    # The panes a hand-back moves: those bound to one of the record's
    # endpoints. Not @rw-root-id alone: a visit pane on another worker
    # carries it too, and stays where it is.
    eps="$(rw_owned_record_read "$P_ROOT_ID" 2>/dev/null | jq -r '.endpoints[]?' 2>/dev/null | tr '\n' ' ')"
    P_ROOT_PANES="$(tmux list-panes -a -F '#{@rw-endpoint}' 2>/dev/null |
      awk -v eps="$eps" 'BEGIN { n = split(eps, e, " "); for (i = 1; i <= n; i++) want[e[i]] = 1 }
        $1 != "" && ($1 in want) { c++ } END { print c + 0 }')"
  fi
  if [ -z "$P_ROOT" ] && [ -n "$P_DIR" ]; then
    if [ -d "$P_DIR" ]; then
      P_ROOT="$(rw_default_root_for_path "$P_DIR")"
    else
      # Only on the remote (a remote pane cd'd into something this machine
      # lacks): the root is one that exists here AND encloses it, a record
      # or a git toplevel above the nearest existing parent. Never that
      # parent itself (a hand-off of ~/Developer for ~/Developer/new) nor the
      # missing directory.
      base="$(rw_local_existing_dir "$P_DIR")"
      if rw_owned_root_for_path "$base" >/dev/null 2>&1 ||
        git -C "$base" rev-parse --show-toplevel >/dev/null 2>&1; then
        P_ROOT="$(rw_default_root_for_path "$base")"
      else
        P_REMOTE_ONLY=1
      fi
    fi
  fi
  if [ -z "$P_OWNER" ] && [ -n "$P_ROOT" ] && rw_root_rel "$P_ROOT" >/dev/null 2>&1; then
    P_ROOT_OK=1
    # Local panes only: they are what a hand-off moves; a remote (visit)
    # pane in the root keeps its own endpoint.
    panes="$(rw_root_panes "$P_ROOT" | awk -F '\t' '$6 == ""')"
    P_ROOT_PANE_LIST="$panes"
    P_ROOT_PANES="$(printf '%s\n' "$panes" | grep -c . || true)"
  fi

  # An agent in the pane: a remote pane's mirrored @agent_kind (B2 clears it
  # when the worker agent is gone); a local pane's, while its @agent_pid
  # lives.
  P_AGENT=""
  kind="$(rw_pane_get "$pane" @agent_kind)"
  if [ -n "$kind" ]; then
    if [ -n "$P_HOST" ]; then
      P_AGENT="$kind"
    else
      pid="$(rw_pane_get "$pane" @agent_pid)"
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && P_AGENT="$kind"
    fi
  fi
  return 0
}

# --- The menu -----------------------------------------------------------------

# rw_pick_handoff_aliases -- the workers a hand-off row is offered for, one
# alias per line: none unless this machine owns a root under ~ and a worker
# is configured. The pane's own worker comes first (when it answers); an
# unreachable pane host gets no row (the hand-off could not run), the other
# workers still do.
rw_pick_handoff_aliases() {
  local w
  { [ -z "$P_OWNER" ] && [ "$P_ROOT_OK" = 1 ]; } || return 0
  if [ -n "$P_HOST" ] && [ -z "$P_UNREACHABLE" ]; then printf '%s\n' "$P_HOST"; fi
  while IFS= read -r w; do
    [ -n "$w" ] && [ "$w" != "$P_HOST" ] && printf '%s\n' "$w"
  done < <(rw_pick_worker_aliases)
  return 0
}

# rw_pick_rows -- the menu rows for the resolved context, one per line, in
# machine form:
#   key<TAB>status<TAB>label<TAB>note
# key: switch:local, switch:<alias>, handback, handoff:<alias> or release.
# status: none (nothing remote to reach), or pending on a row whose
# destination is a worker, until probe-rows sets online or offline. The
# labels carry no root path (the header names it) and no padding.
rw_pick_rows() {
  local -a keys=() labels=() notes=() dests=()
  local d w i label note status
  if [ -n "$P_UNREACHABLE" ]; then
    # Every soft switch needs the pane's own remote (rw switch exits 6);
    # releasing the pane to a local shell does not (I4).
    label="release this pane to this machine (remote unreachable)"
    [ "$P_UNREACHABLE" = unconfigured ] && label="release this pane to this machine (remote not in config.json)"
    keys+=(release) labels+=("$label") notes+=("")
  else
    # Destinations: every host but the pane's own, the owner first.
    [ "${P_OWNER:-local}" != "${P_HOST:-local}" ] && dests+=("${P_OWNER:-local}")
    [ -n "$P_HOST" ] && [ -n "$P_OWNER" ] && dests+=(local)
    while IFS= read -r w; do
      [ -n "$w" ] && [ "$w" != "$P_HOST" ] && [ "$w" != "$P_OWNER" ] && dests+=("$w")
    done < <(rw_pick_worker_aliases)
  fi

  for d in "${dests[@]+"${dests[@]}"}"; do
    if [ "$d" = local ]; then label="switch this pane to this machine"; else label="switch this pane to $d"; fi
    [ "$d" = "${P_OWNER:-local}" ] && label="$label (owner)"
    note=""
    [ -n "$P_AGENT" ] && [ "$d" != "${P_OWNER:-local}" ] && note="$RW_PICK_AGENT_WARNING"
    keys+=("switch:$d") labels+=("$label") notes+=("$note")
  done

  if [ -n "$P_OWNER" ]; then
    # A hand-back to an unreachable pane host cannot run: no row.
    if [ -z "$P_UNREACHABLE" ] || [ "$P_OWNER" != "$P_HOST" ]; then
      label="hand back to this machine"
      [ "${P_ROOT_PANES:-0}" -gt 1 ] && label="$label (${P_ROOT_PANES} panes)"
      keys+=(handback) labels+=("$label") notes+=("")
    fi
  else
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      label="hand off to $w"
      [ "${P_ROOT_PANES:-0}" -gt 1 ] && label="$label (${P_ROOT_PANES} panes)"
      keys+=("handoff:$w") labels+=("$label") notes+=("")
    done < <(rw_pick_handoff_aliases)
  fi

  for i in "${!keys[@]}"; do
    status=none
    case "${keys[$i]}" in switch:local | handback | release) ;; switch:* | handoff:*) status=pending ;; esac
    printf '%s\t%s\t%s\t%s\n' "${keys[$i]}" "$status" "${labels[$i]}" "${notes[$i]}"
  done
}

# rw_pick_render -- machine rows on stdin -> the rows fzf shows (--ansi):
#   key<TAB><marker> <label>  <note>
# The marker is one cell plus a space, so labels line up whatever the status.
rw_pick_render() {
  awk -F '\t' '
    BEGIN {
      rst = "\033[0m"
      grey = "\033[38;2;108;112;134m"; green = "\033[38;2;166;227;161m"
      red = "\033[38;2;243;139;168m"; yellow = "\033[38;2;249;226;175m"
    }
    {
      m = "  "
      if ($2 == "pending") m = grey "…" rst " "
      else if ($2 == "online") m = green "●" rst " "
      else if ($2 == "offline") m = red "○" rst " "
      line = m $3
      if ($4 != "") line = line "  " yellow $4 rst
      print $1 "\t" line
    }'
}

# rw_pick_warn <text> -- one header line in warning yellow.
rw_pick_warn() { printf '\033[38;2;249;226;175m%s\033[0m\n' "$1"; }

# rw_pick_moves_line -- `moves: <session>:<window>.<pane> <command>, ...`, the
# local panes a hand-off moves, folded to the popup width (a continuation is
# indented under the first name). A pane's session:window.pane and its
# command stay on one line (the joining space is a placeholder for fold).
rw_pick_moves_line() {
  local list cols
  cols="$(rw_pick_cols)"
  list="$(printf '%s\n' "$P_ROOT_PANE_LIST" | awk -F '\t' 'NF { printf "%s%s:%s.%s\001%s", (n++ ? ", " : ""), $3, $4, $5, $8 }')"
  [ -n "$list" ] || return 0
  printf '%s\n' "$list" | fold -s -w "$((cols - 7))" | tr '\001' ' ' |
    awk '{ print (NR == 1 ? "moves: " : "       ") $0 }'
}

# rw_pick_header -- names the directory and the root; the hosts only when
# they differ or the remote cannot be reached; warnings in yellow; the panes
# a hand-off would move.
rw_pick_header() {
  local dir root host
  dir="$(rw_pick_tilde "$P_DIR")"
  root="$(rw_pick_tilde "$P_ROOT")"
  if [ -z "$P_ROOT" ]; then
    printf '%s  ·  no root on this machine\n' "$dir"
  elif [ "$P_DIR" = "$P_ROOT" ]; then
    printf '%s (root)\n' "$dir"
  else
    printf '%s  ·  root %s\n' "$dir" "$root"
  fi
  if [ "$P_HOST" != "$P_OWNER" ] || [ -n "$P_UNREACHABLE" ]; then
    host="$(rw_pick_host_name "$P_HOST")"
    case "$P_UNREACHABLE" in
      unreachable) host="$host, remote unreachable" ;;
      unconfigured) host="$host, not in config.json" ;;
    esac
    printf 'pane on %s  ·  owned by %s\n' "$host" "$(rw_pick_host_name "$P_OWNER")"
  fi
  if [ -n "$P_UNREACHABLE" ]; then
    rw_pick_warn 'the directory is the last one it reported; switching needs the remote, releasing does not'
  fi
  if [ "$P_REMOTE_ONLY" = 1 ]; then
    rw_pick_warn "$dir exists only on $(rw_pick_host_name "$P_HOST"): nothing on this machine to hand off"
  fi
  if [ -z "$P_OWNER" ] && [ -n "$P_ROOT" ] && [ "$P_ROOT_OK" != 1 ]; then
    rw_pick_warn "$root cannot be handed off: only directories under ~ (not ~ itself) can"
  fi
  if [ "${P_ROOT_PANES:-0}" -gt 1 ] && [ -n "$(rw_pick_handoff_aliases)" ]; then
    rw_pick_moves_line
  fi
  return 0
}

# probe_rows <rows file> -- the same machine rows, in the same order, each
# worker row's status set to online or offline. One probe per distinct
# worker (a switch row and a hand-off row for it share the answer), in
# parallel; the rows are printed once all have answered (fzf reload-sync
# keeps the instant list until then), so the order and the cursor never move.
probe_rows() {
  local file="$1" dir n=0 alias
  dir="$(mktemp -d "${TMPDIR:-/tmp}/rw-picker-probe.XXXXXX")" || {
    cat "$file"
    return 0
  }
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    n=$((n + 1))
    (
      if rw_ssh_batch "$alias" "$(rw_ssh_status_timeout)" true >/dev/null 2>&1; then
        printf '%s\tonline\n' "$alias" >"$dir/r.$n"
      else
        printf '%s\toffline\n' "$alias" >"$dir/r.$n"
      fi
    ) &
  done < <(awk -F '\t' '$1 ~ /^(switch|handoff):/ { a = $1; sub(/^[^:]*:/, "", a); if (a != "local" && !(a in seen)) { seen[a] = 1; print a } }' "$file")
  wait
  : >"$dir/map"
  cat "$dir"/r.* >>"$dir/map" 2>/dev/null
  awk -F '\t' -v OFS='\t' '
    NR == FNR { st[$1] = $2; next }
    $1 ~ /^(switch|handoff):/ { a = $1; sub(/^[^:]*:/, "", a); if (a in st) $2 = st[a] }
    { print }' "$dir/map" "$file"
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

# rw_pick_switch <dest> [rw switch args...] -- `rw switch` for the origin
# pane (by default with --dir <the resolved directory>), output live in the
# popup; any failure held open as a dialog.
rw_pick_switch() {
  local dest="$1" out status refusal where
  local -a extra=(--dir "$P_DIR")
  shift
  [ "$#" -eq 0 ] || extra=("$@")
  out="$(mktemp "${TMPDIR:-/tmp}/rw-picker-run.XXXXXX")"
  env -u TMUX_PANE "$RW_BIN" switch --pane "$P_PANE" --to "$dest" "${extra[@]}" </dev/null 2>&1 | tee "$out"
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
  # --color=header: a muted overlay grey, replacing the red the user's
  # FZF_DEFAULT_OPTS would otherwise give it. --ansi: the status markers and
  # warning lines carry their own colors.
  sel="$(rw_pick_render <"$rows" | "$RW_FZF" \
    --layout=reverse --info=inline --no-sort --no-multi --ansi \
    --prompt='rw ⇒ ' \
    --color='header:#9399b2' \
    --header="$header" \
    --delimiter=$'\t' --with-nth=2.. \
    --bind "start:reload-sync:$(printf '%q' "$RW_PICK_SELF") probe-rows $(printf '%q' "$rows")")"
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

  # The binding passes #{pane_id}, and everything below acts on that pane
  # alone (P_PANE; every tmux call is targeted). Without one (an older
  # binding), resolve it BEFORE fzf: inside a popup, display-message with no
  # target resolves against the client's active pane, the pane the popup
  # was opened over.
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
    handback) rw_pick_bg handback --pane "$P_PANE" --root "$P_ROOT" ;;
    handoff:*) rw_pick_bg handoff --worker "${key#handoff:}" --pane "$P_PANE" --root "$P_ROOT" ;;
    release) rw_pick_switch local --force ;;
  esac
  exit 0
}

case "$mode" in
  probe-rows)
    if [ "${3:-}" = --raw ]; then
      probe_rows "${2:?rw-picker: probe-rows needs a rows file}"
    else
      probe_rows "${2:?rw-picker: probe-rows needs a rows file}" | rw_pick_render
    fi
    ;;
  render) rw_pick_render ;;
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
