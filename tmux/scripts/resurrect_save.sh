#!/usr/bin/env bash
# Serialized, verified save entrypoint shared by Continuum, manual saves,
# clean-detach saves, and the headless launchd/systemd timer.

set -u

TMUX_BIN="${TMUX_RESURRECT_SAVE_TMUX_BIN:-tmux}"
PLUGIN_DIR="${TMUX_RESURRECT_SAVE_PLUGIN_DIR:-$HOME/.config/tmux/plugins/tmux-resurrect}"
SAVE_SCRIPT="$PLUGIN_DIR/scripts/save.sh"
PRINT_TIMESTAMP=0
success_marker=""

for arg in "$@"; do
  case "$arg" in
    --print-timestamp) PRINT_TIMESTAMP=1 ;;
    quiet) : ;; # Compatibility with tmux-continuum's save-script contract.
    *)
      printf 'tmux verified save: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

fail() {
  [ -z "$success_marker" ] || restore_previous_timestamp "$success_marker"
  printf 'tmux verified save: %s\n' "$1" >&2
  exit 1
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

file_inode() {
  stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null
}

snapshot_is_sane() {
  [ -s "$1" ] || return 1
  awk -F'\t' '
    $1 == "pane" && NF == 11 { pane_ok = 1 }
    NF > 0 { last_type = $1; last_nf = NF }
    END { exit !(pane_ok && last_type == "state" && last_nf == 3) }
  ' "$1"
}

restore_previous_timestamp() {
  local marker="$1" previous=""
  [ -f "$marker" ] && previous="$(sed -n '1p' "$marker" 2>/dev/null)"
  if is_uint "$previous"; then
    "$TMUX_BIN" set-option -gq @continuum-save-last-timestamp "$previous" 2>/dev/null || true
  else
    "$TMUX_BIN" set-option -guq @continuum-save-last-timestamp 2>/dev/null || true
  fi
}

command -v "$TMUX_BIN" >/dev/null 2>&1 || fail "tmux is not executable: $TMUX_BIN"
"$TMUX_BIN" list-sessions >/dev/null 2>&1 || fail "no tmux server with sessions is running"

configured_dir="$("$TMUX_BIN" show-option -gqv @resurrect-dir 2>/dev/null || true)"
if [ -z "$configured_dir" ]; then
  if [ -d "$HOME/.tmux/resurrect" ]; then
    configured_dir="$HOME/.tmux/resurrect"
  else
    configured_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
  fi
fi
host="$(hostname 2>/dev/null || true)"
resurrect_dir="$(printf '%s\n' "$configured_dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g")"
success_marker="$resurrect_dir/.last-successful-save"
mkdir -p "$resurrect_dir" || fail "cannot create resurrect directory: $resurrect_dir"
[ -x "$SAVE_SCRIPT" ] || fail "tmux-resurrect save script is not executable: $SAVE_SCRIPT"

server_pid="$("$TMUX_BIN" display-message -p '#{pid}' 2>/dev/null || true)"
is_uint "$server_pid" || fail "cannot resolve the tmux server pid"
lock_dir="${TMPDIR:-/tmp}/tmux-resurrect-${server_pid}-verified-save.lock"
waited=0
while ! mkdir "$lock_dir" 2>/dev/null; do
  owner="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
  if is_uint "$owner" && ! kill -0 "$owner" 2>/dev/null; then
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    continue
  fi
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -lt 300 ] || fail "timed out waiting for another save to finish"
done
printf '%s\n' "$$" >"$lock_dir/pid"
trap 'rm -f "$lock_dir/pid" 2>/dev/null; rmdir "$lock_dir" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

last="$resurrect_dir/last"
sidecar="$resurrect_dir/workspace_state.json"
before_sidecar_inode=""
[ -f "$sidecar" ] && before_sidecar_inode="$(file_inode "$sidecar" || true)"

if ! bash "$SAVE_SCRIPT" quiet; then
  fail "tmux-resurrect returned an error"
fi

# Verification is by artifact, not by attempt path: tmux-resurrect cannot
# be pointed at a caller-chosen snapshot file (its helpers.sh resets
# _RESURRECT_FILE_PATH unconditionally at source time, so an env override
# never survives). The authoritative `last` must be structurally sane, and
# the sidecar-inode check below proves THIS invocation ran the full save
# chain -- a valid byte-identical attempt is deleted by tmux-resurrect and
# `last` legitimately keeps its previous target, so a changed `last` must
# not be required.
snapshot_is_sane "$last" || {
  fail "authoritative snapshot is missing or malformed: $last"
}

after_sidecar_inode=""
[ -f "$sidecar" ] && after_sidecar_inode="$(file_inode "$sidecar" || true)"
[ -n "$after_sidecar_inode" ] || {
  fail "workspace-resurrect sidecar was not produced"
}
[ -z "$before_sidecar_inode" ] || [ "$after_sidecar_inode" != "$before_sidecar_inode" ] || {
  fail "workspace-resurrect sidecar was not refreshed"
}

snapshot_name="$(readlink "$last" 2>/dev/null || printf 'last')"
if ! command -v jq >/dev/null 2>&1 ||
  ! jq -e --arg snapshot "$snapshot_name" '
    .version == 1 and
    .resurrect_snapshot == $snapshot and
    (.saved_at | type == "string" and length > 0) and
    (.panes | type == "array") and
    (.treemux | type == "array")
  ' "$sidecar" >/dev/null 2>&1; then
  fail "workspace-resurrect sidecar failed validation"
fi

completed_at="$(date +%s)"
# Update Continuum's option BEFORE publishing the marker: fail() rolls the
# option back from the marker, so the marker must still hold the PRIOR
# timestamp while any step here can still fail.
"$TMUX_BIN" set-option -gq @continuum-save-last-timestamp "$completed_at" || fail "cannot update Continuum save timestamp"
marker_tmp="$resurrect_dir/.last-successful-save.$$"
printf '%s\n' "$completed_at" >"$marker_tmp" || fail "cannot write save-success marker"
chmod 0600 "$marker_tmp" 2>/dev/null || true
mv "$marker_tmp" "$success_marker" || fail "cannot publish save-success marker"
"$TMUX_BIN" refresh-client -S 2>/dev/null || true

[ "$PRINT_TIMESTAMP" -eq 0 ] || printf '%s\n' "$completed_at"
