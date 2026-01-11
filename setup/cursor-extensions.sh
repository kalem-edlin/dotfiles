#!/bin/bash

# Install Cursor extensions from Brewfile
# This script extracts vscode extension IDs from the Brewfile and installs them to Cursor

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BREWFILE="$DOTFILES_DIR/Brewfile"

# Cursor CLI path
CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"

# Check if Cursor is installed
if [ ! -f "$CURSOR_CLI" ]; then
    echo "⚠ Cursor is not installed. Skipping extension installation."
    exit 0
fi

# Extract extension IDs from Brewfile (lines starting with vscode)
extensions=$(grep -E '^\s*vscode\s+"[^"]+"' "$BREWFILE" | awk -F'"' '{print $2}')

if [ -z "$extensions" ]; then
    echo "⚠ No extensions found in Brewfile"
    exit 0
fi

echo "Installing Cursor extensions..."

# Install each extension
installed=0
failed=0

for ext in $extensions; do
    if "$CURSOR_CLI" --install-extension "$ext" &>/dev/null; then
        echo "  ✓ $ext"
        ((installed++))
    else
        # Check if already installed (exit code might be non-zero but extension is there)
        if "$CURSOR_CLI" --list-extensions 2>/dev/null | grep -q "^${ext}$"; then
            echo "  → $ext (already installed)"
            ((installed++))
        else
            echo "  ✗ $ext (failed)"
            ((failed++))
        fi
    fi
done

echo ""
if [ $failed -eq 0 ]; then
    echo "✓ All Cursor extensions installed successfully! ($installed total)"
else
    echo "⚠ Installed $installed extensions, $failed failed"
fi
