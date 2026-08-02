#!/usr/bin/env bash
# Prints an autosave-freshness chip for tmux status-right, derived from
# tmux-continuum's @continuum-save-last-timestamp option.
#
# Styling: this renders a chip byte-identical in structure to catppuccin's
# own status modules (the "dotfiles"/"mac" chips), so it sits flush against
# them. It cannot BE a catppuccin custom module, because catppuccin's
# build_status_module() bakes the icon background colour in once at load
# time, and this chip's whole purpose is to change colour at runtime. So we
# reproduce build_status_module()'s output ourselves.
#
# The reproduced recipe is catppuccin.tmux:131-156, branch
# status_fill="icon" + status_connect_separator="no" (both set in
# tmux/tmux.conf:67-68):
#
#   #[fg=COLOR,bg=BG,...]LSEP  #[fg=BG,bg=COLOR,...]ICON<sp>
#   #[fg=FG,bg=GRAY]<sp>TEXT   #[fg=GRAY,bg=BG,...]RSEP
#
# If tmux/tmux.conf ever changes @catppuccin_status_fill away from "icon"
# or turns on @catppuccin_status_connect_separator, this chip will stop
# matching and the recipe above must be re-derived from catppuccin.tmux.
#
# Runs on every status refresh, so it must stay cheap and must never print
# an error string: any failure path prints nothing and exits 0.
#
# Cost note: each separate `tmux show-option` call spawns its own client
# process and pays a full socket round-trip (~5ms measured on this
# machine). `tmux show-options -g` dumps every global option in a single
# client spawn, so all five values we need (status-right, the two
# continuum options, and the two separator glyphs) come out of one call.

set -u

# catppuccin mocha, from plugins/catppuccin-tmux/catppuccin-mocha.tmuxtheme.
THM_BG="#1e1e2e"
THM_FG="#cdd6f4"
THM_GRAY="#313244"
FRESH_COLOR="#f5c2e7" # thm_pink -- same as the directory chip
LATE_COLOR="#f9e2af"  # thm_yellow
STALE_COLOR="#f38ba8" # thm_red

ICON="󰄬"

GRACE_SECONDS=60
DEFAULT_INTERVAL_MIN=15
DEFAULT_LSEP=""
DEFAULT_RSEP=""

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Emits the finished chip. $1 = icon background colour, $2 = text.
chip() {
  printf '#[fg=%s,bg=%s,nobold,nounderscore,noitalics]%s#[fg=%s,bg=%s,nobold,nounderscore,noitalics]%s #[fg=%s,bg=%s] %s#[fg=%s,bg=%s,nobold,nounderscore,noitalics]%s' \
    "$1" "$THM_BG" "$lsep" \
    "$THM_BG" "$1" "$ICON" \
    "$THM_FG" "$THM_GRAY" "$2" \
    "$THM_GRAY" "$THM_BG" "$rsep"
}

opts="$(tmux show-options -g 2>/dev/null)" || exit 0

status_right=""
interval_min=""
last_save=""
lsep="$DEFAULT_LSEP"
rsep="$DEFAULT_RSEP"
have_status_right=0
have_interval=0
have_last_save=0

# show-options quotes values that need it; strip one layer of surrounding
# double quotes from the ones we use as data (the separators are single
# glyphs and the timestamps are integers, so no escape handling is needed
# beyond this).
unquote() {
  local v="$1"
  v="${v#\"}"
  v="${v%\"}"
  printf '%s' "$v"
}

while IFS= read -r line; do
  case "$line" in
    "status-right "*)
      status_right="${line#status-right }"
      have_status_right=1
      ;;
    "@continuum-save-interval "*)
      interval_min="$(unquote "${line#@continuum-save-interval }")"
      have_interval=1
      ;;
    "@continuum-save-last-timestamp "*)
      last_save="$(unquote "${line#@continuum-save-last-timestamp }")"
      have_last_save=1
      ;;
    "@catppuccin_status_left_separator "*)
      lsep="$(unquote "${line#@catppuccin_status_left_separator }")"
      ;;
    "@catppuccin_status_right_separator "*)
      rsep="$(unquote "${line#@catppuccin_status_right_separator }")"
      ;;
  esac
done <<< "$opts"

# The one failure mode this indicator exists to catch: continuum's own save
# interpolation missing from status-right (disarmed autosave). This check
# must win even when the last save timestamp still looks recent.
if [ "$have_status_right" -eq 0 ]; then
  exit 0
fi
case "$status_right" in
  *continuum_save.sh*) ;;
  *)
    chip "$STALE_COLOR" "OFF"
    exit 0
    ;;
esac

if [ "$have_interval" -eq 0 ] || ! is_uint "$interval_min"; then
  interval_min="$DEFAULT_INTERVAL_MIN"
fi
[ "$interval_min" -gt 0 ] || interval_min="$DEFAULT_INTERVAL_MIN"

now="$(date +%s)" || exit 0
interval_sec=$((interval_min * 60))
fresh_max=$((interval_sec + GRACE_SECONDS))
stale_min=$((interval_sec * 3))

if [ "$have_last_save" -eq 0 ] || ! is_uint "$last_save"; then
  # Empty on first plugin load until the first save fires. Treat as Late
  # (armed, just not saved yet) within one interval+grace of server start;
  # beyond that, an empty timestamp is suspicious rather than benign.
  start_time="$(tmux display-message -p -F '#{start_time}' 2>/dev/null)"
  is_uint "$start_time" || exit 0
  since_start=$((now - start_time))
  [ "$since_start" -lt 0 ] && since_start=0
  if [ "$since_start" -le "$fresh_max" ]; then
    chip "$LATE_COLOR" "$((since_start / 60))m"
  else
    chip "$STALE_COLOR" "NO SAVE"
  fi
  exit 0
fi

age=$((now - last_save))
[ "$age" -lt 0 ] && age=0
age_min=$((age / 60))

if [ "$age" -ge "$stale_min" ]; then
  chip "$STALE_COLOR" "${age_min}m"
elif [ "$age" -gt "$fresh_max" ]; then
  chip "$LATE_COLOR" "${age_min}m"
else
  chip "$FRESH_COLOR" "${age_min}m"
fi
