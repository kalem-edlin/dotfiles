#!/usr/bin/env bash
# rw-paste-image.sh <pane_id> -- `prefix C-v`: paste the laptop clipboard
# image into a pane as a file path (D3, C1 in
# docs/tasks/drop-to-remote-paste.md).
#
# Saves the pasteboard image as ~/Pictures/rw-clips/<UTC timestamp>.png.
# In a remote workspace pane it is pushed with libexec/rw-push-file (it lands
# at <worker_home>/Pictures/rw-clips/<same>.png) and the worker path is
# typed into the pane; in a local pane the laptop path is typed. Paths are
# escaped the way a Ghostty drop escapes them, so both behave alike.
#
# Bound with `run-shell -b`, so tmux never waits on it (osascript can take
# hundreds of ms, R3). It prints nothing: run-shell would show any output in
# the pane. Every outcome other than a typed path is one display-message.
# bash 3.2 compatible (macOS /bin/bash).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

exec >/dev/null 2>&1

pane="${1:-}"
case "$pane" in %[0-9]*) ;; *) exit 64 ;; esac

say() { tmux display-message -t "$pane" "$1" 2>/dev/null || true; }

# Ghostty.Shell.escape (F3): a backslash before each special character.
ghostty_escape() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      \\ | ' ' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>' | '"' | "'" | '`' | '!' | '#' | '$' | '&' | ';' | '|' | '*' | '?' | $'\t')
        out="$out\\$c"
        ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

dir="$HOME/Pictures/rw-clips"
mkdir -p "$dir" || {
  say "rw: cannot create ~/Pictures/rw-clips"
  exit 0
}
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
file="$dir/$stamp.png"
n=1
while [ -e "$file" ]; do
  file="$dir/$stamp-$n.png"
  n=$((n + 1))
done
tmp="$(mktemp "$dir/.clip.XXXXXX")" || {
  say "rw: cannot write to ~/Pictures/rw-clips"
  exit 0
}

# `the clipboard as «class PNGf»` prints «data PNGf<hex>»; strip the
# wrapper (byte-wise, so the guillemets' encoding does not matter) and
# decode. No image on the pasteboard: osascript exits non-zero. Anything
# unexpected fails the PNG signature check below.
osascript -e 'the clipboard as «class PNGf»' 2>/dev/null |
  LC_ALL=C sed -e 's/^[^P]*PNGf//' -e 's/[^0-9A-Fa-f]*$//' |
  xxd -r -p >"$tmp"
st=("${PIPESTATUS[@]}")
magic="$(head -c 8 "$tmp" | xxd -p)"
if [ "${st[0]}" -ne 0 ] || [ "$magic" != "89504e470d0a1a0a" ]; then
  rm -f "$tmp"
  say "rw: no image on the clipboard"
  exit 0
fi
mv -f "$tmp" "$file" || {
  rm -f "$tmp"
  say "rw: cannot save the clipboard image"
  exit 0
}
chmod 0644 "$file" 2>/dev/null || true

path="$("$RW_PLUGIN_DIR/libexec/rw-push-file" "$pane" "$file" 2>/dev/null)"
rc=$?
case "$rc" in
  0) ;;
  2) path="$file" ;;
  *)
    rw_log "rw-paste-image: push of $file from pane $pane failed (rc=$rc)"
    say "rw: copying the clipboard image to the worker failed; it is saved in ~/Pictures/rw-clips"
    exit 0
    ;;
esac
case "$path" in
  /*$'\n'* | '') say "rw: copying the clipboard image to the worker failed"; exit 0 ;;
  /*) ;;
  *) say "rw: copying the clipboard image to the worker failed"; exit 0 ;;
esac

tmux send-keys -t "$pane" -l -- "$(ghostty_escape "$path")" 2>/dev/null ||
  say "rw: could not type the image path into the pane"
exit 0
