#!/bin/bash
# shellcheck disable=SC2016 # $names inside single quotes are jq variables

set -u

# Applies helium/settings.json to Helium's Chromium state files:
#   local_state  -> "<user data dir>/Local State" (enabled_labs_experiments
#                   entries are added; other entries for the same flag, e.g.
#                   "name@2", are dropped; unrelated flags are kept)
#   preferences  -> deep-merged into every profile's Preferences
# Idempotent: a file is only rewritten when the merge changes it, via temp
# file + mv, after a one-time "<file>.bak" copy.
#
# HELIUM_USER_DATA_DIR overrides the data dir (for testing against a copy).

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$DOTFILES_DIR/helium/settings.json"
DEFAULT_DATA_DIR="$HOME/Library/Application Support/net.imput.helium"
DATA_DIR="${HELIUM_USER_DATA_DIR:-$DEFAULT_DATA_DIR}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Skipping Helium settings (macOS only)"
  exit 0
fi

if ! command -v jq &> /dev/null; then
  echo "⚠ jq not found. Run 'make brew' first."
  exit 1
fi

# Helium rewrites Local State/Preferences from memory on exit, so edits made
# while it runs are lost. Only guards the real data dir (tests use a copy).
if [ "$DATA_DIR" = "$DEFAULT_DATA_DIR" ] && pgrep -x Helium &> /dev/null; then
  echo "⚠ Helium is running; quit it and rerun 'make helium' to apply settings"
  exit 0
fi

# write_json <file> <jq filter> [jq args...]
# Runs the filter over <file> (or {} if missing) and replaces <file> only if
# the result differs.
write_json() {
  local file="$1" filter="$2" tmp
  shift 2
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  if [ -f "$file" ]; then
    jq -c "$@" "$filter" "$file" > "$tmp"
  else
    echo '{}' | jq -c "$@" "$filter" > "$tmp"
  fi || { rm -f "$tmp"; echo "⚠ Failed to merge settings into $file"; return 1; }

  if [ -f "$file" ] && cmp -s <(jq -cS . "$file") <(jq -cS . "$tmp"); then
    rm -f "$tmp"
    echo "  ✓ ${file#"$DATA_DIR"/} already up to date"
    return 0
  fi
  if [ -f "$file" ] && [ ! -e "$file.bak" ]; then
    cp -p "$file" "$file.bak"
  fi
  mv "$tmp" "$file"
  echo "  → Updated ${file#"$DATA_DIR"/}"
}

echo "Applying Helium settings..."

# A pre-seeded Local State is safe (first run is keyed off the "First Run"
# sentinel, and absent keys take defaults), so create it if needed.
mkdir -p "$DATA_DIR"
write_json "$DATA_DIR/Local State" '
  def base: split("@")[0];
  ($want | map(base)) as $wanted_bases
  | (.browser.enabled_labs_experiments // []) as $cur
  | ($cur | map(select(. as $e
      | ($want | index([$e])) != null
        or ($wanted_bases | index([$e | base])) == null))) as $kept
  | .browser.enabled_labs_experiments = $kept + ($want - $kept)
' --argjson want "$(jq -c '.local_state.enabled_labs_experiments' "$SETTINGS")" \
  || exit 1

# Preferences are NOT pre-seeded: Chromium treats a profile whose Preferences
# file already exists as not new and skips new-profile initialization.
found_profile=0
for prefs in "$DATA_DIR/Default/Preferences" "$DATA_DIR"/Profile\ */Preferences; do
  [ -f "$prefs" ] || continue
  found_profile=1
  write_json "$prefs" '. * $prefs' \
    --argjson prefs "$(jq -c '.preferences' "$SETTINGS")" || exit 1
done

if [ "$found_profile" -eq 0 ]; then
  echo "⚠ No Helium profile yet. Launch Helium once, quit it, and rerun 'make helium'"
  exit 0
fi

echo "✓ Helium settings applied (takes effect on next Helium launch)"
