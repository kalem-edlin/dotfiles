#!/bin/bash

set -euo pipefail

# Icon font for the tmux-agent-sessions picker's status chips: the four
# status glyphs from Lucide, rescaled and centred on a Hack cell by
# setup/lucide-font-derive.py. ghostty/config maps only those codepoints to
# it. macOS only: Linux workers need no font, because the glyphs render in
# Ghostty on the laptop.
LUCIDE_VERSION=1.52.0
# sha256 of the npm tarball (cross-checked against the registry's
# dist.shasum and dist.integrity) and of the font inside it.
LUCIDE_TARBALL_SHA256=4d2aa079171e4eba4c704844b8b0c9edb6e4cfb2fb8bd86f7b14353994f04a87
LUCIDE_TTF_SHA256=124ecc64b91a158fc519eefdaaead89a2d9e2c39b6f9c8429c5584c93a0be451
# The derive script's output is byte-identical for these inputs.
FONTTOOLS_VERSION=4.62.1
DERIVED_TTF_SHA256=450ed54246e95052436ca3de87e5170ba8df49ae31f6bb4875499290ce112cce

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FONT_DIR="$HOME/Library/Fonts"
FONT_PATH="$FONT_DIR/lucide-picker.ttf"
# The unmodified font this script installed before the derived one.
OLD_FONT_PATH="$FONT_DIR/lucide.ttf"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: setup/lucide-font.sh is only for macOS." >&2
    exit 1
fi

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

remove_old_font() {
    if [[ -f "$OLD_FONT_PATH" && "$(sha256_of "$OLD_FONT_PATH")" = "$LUCIDE_TTF_SHA256" ]]; then
        rm -f "$OLD_FONT_PATH"
        echo "  -> removed the unmodified Lucide font (replaced by lucide-picker.ttf)"
    fi
}

if [[ -f "$FONT_PATH" && "$(sha256_of "$FONT_PATH")" = "$DERIVED_TTF_SHA256" ]]; then
    remove_old_font
    echo "✓ Lucide picker font $LUCIDE_VERSION already installed"
    exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "Error: uv is required to derive the Lucide picker font (make brew)." >&2
    exit 1
fi

LUCIDE_DOWNLOAD_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-lucide.XXXXXX")"
trap 'rm -rf "$LUCIDE_DOWNLOAD_TEMP"' EXIT
archive="$LUCIDE_DOWNLOAD_TEMP/lucide-static-$LUCIDE_VERSION.tgz"

echo "Installing Lucide font $LUCIDE_VERSION..."
curl --fail --location --retry 3 --output "$archive" \
    "https://registry.npmjs.org/lucide-static/-/lucide-static-$LUCIDE_VERSION.tgz"
(cd "$LUCIDE_DOWNLOAD_TEMP" && echo "$LUCIDE_TARBALL_SHA256  $(basename "$archive")" | shasum -a 256 -c -)
tar -xzf "$archive" -C "$LUCIDE_DOWNLOAD_TEMP" package/font/lucide.ttf

if [[ "$(sha256_of "$LUCIDE_DOWNLOAD_TEMP/package/font/lucide.ttf")" != "$LUCIDE_TTF_SHA256" ]]; then
    echo "Error: lucide.ttf inside the verified tarball has an unexpected sha256." >&2
    exit 1
fi

derived="$LUCIDE_DOWNLOAD_TEMP/lucide-picker.ttf"
uv run --quiet --no-project --with "fonttools==$FONTTOOLS_VERSION" \
    python3 "$DOTFILES_DIR/setup/lucide-font-derive.py" \
    "$LUCIDE_DOWNLOAD_TEMP/package/font/lucide.ttf" "$derived"
if [[ "$(sha256_of "$derived")" != "$DERIVED_TTF_SHA256" ]]; then
    echo "Error: the derived Lucide picker font has an unexpected sha256." >&2
    exit 1
fi

# Replace atomically so a running app never sees a partial font file.
mkdir -p "$FONT_DIR"
cp "$derived" "$FONT_PATH.tmp.$$"
mv -f "$FONT_PATH.tmp.$$" "$FONT_PATH"
remove_old_font

echo "✓ Lucide picker font installed: $FONT_PATH (restart Ghostty to pick it up)"
