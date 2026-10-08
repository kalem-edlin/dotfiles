#!/usr/bin/env bash
# Tests for scripts/pane-mem, scripts/pane-mem-chip, scripts/wire-mem-chip and
# src/pane-mem.c. Never touches a real tmux server: a fake `tmux` shim is
# first in PATH and the harness aborts unless `command -v tmux` resolves to it.
#
# Run: bash tmux/local-plugins/tmux-agent-sessions/tests/pane-mem-test.sh

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TEST_DIR/.." && pwd)"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/pane-mem-test.XXXXXX")" || exit 1
trap 'rm -rf "$scratch"' EXIT

# --- tmux safety harness ----------------------------------------------------
shim_dir="$scratch/shim"
mkdir -p "$shim_dir" "$scratch/tmux-tmpdir"
cat >"$shim_dir/tmux" <<'SHIM'
#!/usr/bin/env bash
# Fake tmux: logs argv (one call per line, args separated by \x1f) and keeps
# status-right in a file.
{
  first=1
  for a in "$@"; do
    if [ "$first" -eq 1 ]; then first=0; else printf '\037'; fi
    printf '%s' "$a"
  done
  printf '\n'
} >>"$FAKE_TMUX_LOG"
case "$1 ${2:-} ${3:-}" in
  "show-option -gqv status-right")
    [ -f "$FAKE_TMUX_STATUS" ] && cat "$FAKE_TMUX_STATUS"
    ;;
  "set-option -gq status-right")
    printf '%s\n' "$4" >"$FAKE_TMUX_STATUS"
    ;;
  *) exit 1 ;;
esac
exit 0
SHIM
chmod +x "$shim_dir/tmux"
PATH="$shim_dir:$PATH"
export PATH
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$scratch/tmux-tmpdir"
export FAKE_TMUX_LOG="$scratch/tmux.log"
export FAKE_TMUX_STATUS="$scratch/status-right"
: >"$FAKE_TMUX_LOG"
if [ "$(command -v tmux)" != "$shim_dir/tmux" ]; then
  echo "ABORT: tmux does not resolve to the shim" >&2
  exit 2
fi

# --- tiny assertion helpers -------------------------------------------------
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2] got [$3]"; fi
}

# Builds a scratch plugin copy at $1 (scripts only, no bin/).
make_plugin_copy() {
  mkdir -p "$1/scripts"
  cp "$PLUGIN_DIR/scripts/pane-mem" "$PLUGIN_DIR/scripts/pane-mem-chip" "$1/scripts/"
}

# A pid that is certainly dead: a finished child's pid, checked with kill -0.
dead_pid() {
  local p
  while :; do
    p="$(sh -c 'echo $$')"
    kill -0 "$p" 2>/dev/null || { printf '%s' "$p"; return; }
  done
}
DEAD="$(dead_pid)"

# --- 1. ps fallback with a fixture (exact tree sums) ------------------------
fb="$scratch/fallback"
make_plugin_copy "$fb"
fake_ps_dir="$scratch/fakeps"
mkdir -p "$fake_ps_dir"
# Tree: 0 (self-parent, as on macOS) -> 1 -> {10 -> {11, 12 -> 13}, 20}
cat >"$fake_ps_dir/ps" <<'PS'
#!/bin/sh
cat <<'T'
    0     0     0
    1     0   100
   10     1  1000
   11    10   200
   12    10   300
   13    12    40
   20     1     5
T
PS
chmod +x "$fake_ps_dir/ps"
out="$(PATH="$fake_ps_dir:$PATH" "$fb/scripts/pane-mem" 10 13 20 1 999 abc 12)"
eq "fallback tree sums" "10 1540
13 40
20 5
1 1645
12 340" "$out"
out="$(PATH="$fake_ps_dir:$PATH" "$fb/scripts/pane-mem" 0)"
eq "fallback cycle at pid 0" "0 1645" "$out"
out="$(PATH="$fake_ps_dir:$PATH" "$fb/scripts/pane-mem" 999)"
rc=$?
eq "fallback dead root prints nothing" "" "$out"
eq "fallback dead root exit 0" "0" "$rc"
out="$("$fb/scripts/pane-mem")"
eq "no args prints nothing" "" "$out"

# --- 2. ps fallback against live processes ----------------------------------
out="$("$fb/scripts/pane-mem" "$PPID" "$$" "$DEAD")"
lines="$(printf '%s\n' "$out" | grep -c .)"
eq "fallback live: two lines" "2" "$lines"
pk="$(printf '%s\n' "$out" | awk -v p="$PPID" '$1 == p { print $2 }')"
sk="$(printf '%s\n' "$out" | awk -v p="$$" '$1 == p { print $2 }')"
if [ -n "$sk" ] && [ "$sk" -gt 0 ] && [ -n "$pk" ] && [ "$pk" -ge "$sk" ]; then ok; else bad "fallback live sums: parent=$pk self=$sk"; fi

# --- 3. C helper (macOS only) ------------------------------------------------
if [ "$(uname -s)" = Darwin ] && command -v clang >/dev/null 2>&1; then
  hp="$scratch/helper"
  make_plugin_copy "$hp"
  mkdir -p "$hp/bin"
  if clang -O2 -Wall -Wextra -Werror -o "$hp/bin/pane-mem-darwin" "$PLUGIN_DIR/src/pane-mem.c"; then
    ok
    out="$("$hp/bin/pane-mem-darwin" "$PPID" "$$" "$DEAD" 0x1 -5 "")"
    rc=$?
    eq "helper exit 0" "0" "$rc"
    lines="$(printf '%s\n' "$out" | grep -c .)"
    eq "helper live: two lines" "2" "$lines"
    pk="$(printf '%s\n' "$out" | awk -v p="$PPID" '$1 == p { print $2 }')"
    sk="$(printf '%s\n' "$out" | awk -v p="$$" '$1 == p { print $2 }')"
    if [ -n "$sk" ] && [ "$sk" -gt 0 ] && [ -n "$pk" ] && [ "$pk" -ge "$sk" ]; then ok; else bad "helper live sums: parent=$pk self=$sk"; fi
    out="$("$hp/bin/pane-mem-darwin" "$DEAD")"
    eq "helper dead root prints nothing" "" "$out"
    out="$("$hp/bin/pane-mem-darwin")"
    eq "helper no args" "" "$out"
    # launchd's tree contains this shell's tree.
    out="$("$hp/bin/pane-mem-darwin" 1 "$$")"
    one="$(printf '%s\n' "$out" | awk '$1 == 1 { print $2 }')"
    sk="$(printf '%s\n' "$out" | awk -v p="$$" '$1 == p { print $2 }')"
    if [ -n "$one" ] && [ -n "$sk" ] && [ "$one" -ge "$sk" ]; then ok; else bad "helper pid 1 contains self: one=$one self=$sk"; fi
    # Entry point dispatches to the helper.
    out="$("$hp/scripts/pane-mem" "$$" "$DEAD")"
    case "$out" in
      "$$ "[0-9]*) ok ;;
      *) bad "entry point via helper: [$out]" ;;
    esac
  else
    bad "helper compile with -Wall -Wextra -Werror"
  fi
else
  echo "skip: C helper tests (not macOS or no clang)"
fi

# --- 4. dispatch through stow-style symlinks --------------------------------
fk="$scratch/fakehelper"
make_plugin_copy "$fk"
mkdir -p "$fk/bin"
cat >"$fk/bin/pane-mem-darwin" <<'H'
#!/bin/sh
# Fixed values: 655360 KiB for every arg except 1 (3 GiB-ish) and 7 (dead).
for p in "$@"; do
  case "$p" in
    7) ;;
    1) echo "$p 2516582" ;;
    *) echo "$p 655360" ;;
  esac
done
H
chmod +x "$fk/bin/pane-mem-darwin"
stow_dir="$scratch/stowed/scripts"
mkdir -p "$stow_dir"
ln -s "../../fakehelper/scripts/pane-mem" "$stow_dir/pane-mem"       # relative
ln -s "$fk/scripts/pane-mem-chip" "$stow_dir/pane-mem-chip"           # absolute
out="$("$stow_dir/pane-mem" 42 7)"
eq "symlinked entry point finds helper" "42 655360" "$out"

# --- 5. chip -----------------------------------------------------------------
chip="$stow_dir/pane-mem-chip"
fmt() { "$chip" --fmt "$1"; }
eq "fmt 0" "0M" "$(fmt 0)"
eq "fmt 1" "1M" "$(fmt 1)"
eq "fmt 1023 KiB" "1M" "$(fmt 1023)"
eq "fmt 1024 KiB" "1M" "$(fmt 1024)"
eq "fmt 2047 KiB" "1M" "$(fmt 2047)"
eq "fmt 640 MiB" "640M" "$(fmt 655360)"
eq "fmt 1023 MiB" "1023M" "$(fmt 1047552)"
eq "fmt 1 GiB - 1 KiB" "1023M" "$(fmt 1048575)"
eq "fmt 1 GiB" "1.0G" "$(fmt 1048576)"
eq "fmt 2.4 GiB" "2.4G" "$(fmt 2516582)"
eq "fmt 10 GiB" "10.0G" "$(fmt 10485760)"
eq "fmt 1.95 GiB rounds" "2.0G" "$(fmt 2044724)"
eq "fmt junk" "" "$(fmt abc)"

LSEP=$' \xee\x82\xb6'
RSEP=$'\xee\x82\xb4 '
ICON=$'\xf3\xb0\x8d\x9b'
expect_chip() {
  printf '#[fg=#cba6f7,bg=#1e1e2e,nobold,nounderscore,noitalics]%s#[fg=#1e1e2e,bg=#cba6f7,nobold,nounderscore,noitalics]%s #[fg=#cdd6f4,bg=#313244] %s#[fg=#313244,bg=#1e1e2e,nobold,nounderscore,noitalics]%s' \
    "$LSEP" "$ICON" "$1" "$RSEP"
}
eq "chip 640M" "$(expect_chip 640M)" "$("$chip" 42)"
eq "chip 2.4G" "$(expect_chip 2.4G)" "$("$chip" 1)"
eq "chip dead pid" "" "$("$chip" 7)"
eq "chip empty pid" "" "$("$chip" "")"
eq "chip no arg" "" "$("$chip")"
eq "chip junk pid" "" "$("$chip" '12;rm')"
# Live pid through the real fallback path.
out="$("$fb/scripts/pane-mem-chip" "$$")"
case "$out" in
  "#[fg=#cba6f7,bg=#1e1e2e,"*"#[fg=#cdd6f4,bg=#313244] "[0-9]*[MG]"#[fg=#313244,bg=#1e1e2e,"*) ok ;;
  *) bad "live chip shape: [$out]" ;;
esac
eq "live chip dead pid" "" "$("$fb/scripts/pane-mem-chip" "$DEAD")"

# None of the above may call tmux.
eq "pane-mem/chip never call tmux" "" "$(cat "$FAKE_TMUX_LOG")"

# --- 6. wire-mem-chip idempotency -------------------------------------------
wire="$PLUGIN_DIR/scripts/wire-mem-chip"
interp="#(~/.config/tmux/local-plugins/tmux-agent-sessions/scripts/pane-mem-chip #{pane_pid})"
autosave="#(~/.config/tmux/scripts/autosave_indicator.sh '#{@remote-host}')"
rest='#[fg=#f5c2e7]dir#[fg=#89b4fa]host'

printf '%s\n' "${autosave}${rest}" >"$FAKE_TMUX_STATUS"
"$wire"
eq "wire prepends" "${interp}${autosave}${rest}" "$(cat "$FAKE_TMUX_STATUS")"
"$wire"
"$wire"
eq "wire idempotent" "${interp}${autosave}${rest}" "$(cat "$FAKE_TMUX_STATUS")"

printf '%s\n' "${autosave}${interp}${rest}${interp}" >"$FAKE_TMUX_STATUS"
"$wire"
eq "wire strips copies and moves to front" "${interp}${autosave}${rest}" "$(cat "$FAKE_TMUX_STATUS")"

rm -f "$FAKE_TMUX_STATUS"
"$wire"
eq "wire on empty status-right" "${interp}" "$(cat "$FAKE_TMUX_STATUS")"

: >"$FAKE_TMUX_LOG"
printf '%s\n' "$rest" >"$FAKE_TMUX_STATUS"
"$wire"
US=$'\037'
eq "wire tmux argv" "show-option${US}-gqv${US}status-right
set-option${US}-gq${US}status-right${US}${interp}${rest}" "$(cat "$FAKE_TMUX_LOG")"

# --- done ----------------------------------------------------------------------
printf 'pane-mem tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
