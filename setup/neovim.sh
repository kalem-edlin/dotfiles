#!/bin/bash

set -euo pipefail

if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

if ! command -v nvim &> /dev/null; then
    echo "Error: nvim not found. Install Neovim first."
    exit 1
fi

if ! command -v tmux &> /dev/null; then
    echo "Error: tmux not found. Install tmux first."
    exit 1
fi

if command -v brew >/dev/null 2>&1 && brew list --versions python@3.12 >/dev/null 2>&1; then
    PYTHON_PREFIX="$(brew --prefix python@3.12)"
    PYTHON_BIN="$PYTHON_PREFIX/bin/python3.12"
else
    PYTHON_BIN=""
fi
PYNVIM_VENV="$HOME/.local/share/nvim/pynvim-venv"

python_usable() {
    local python_bin="$1"

    "$python_bin" - <<'PY' >/dev/null 2>&1
import venv
from xml.parsers import expat
PY
}

add_python_candidate() {
    local candidate="$1"

    if [[ -x "$candidate" ]]; then
        case " ${PYTHON_CANDIDATES_SEEN:-} " in
            *" $candidate "*) return ;;
        esac

        PYTHON_CANDIDATES+=("$candidate")
        PYTHON_CANDIDATES_SEEN="${PYTHON_CANDIDATES_SEEN:-} $candidate"
    fi
}

PYTHON_CANDIDATES=()
PYTHON_CANDIDATES_SEEN=""
add_python_candidate "$PYTHON_BIN"
if command -v pyenv >/dev/null 2>&1; then
    PYENV_PYTHON="$(pyenv which python3 2>/dev/null || true)"
    add_python_candidate "$PYENV_PYTHON"
fi
if command -v python3.12 >/dev/null 2>&1; then
    add_python_candidate "$(command -v python3.12)"
fi
if command -v python3 >/dev/null 2>&1; then
    add_python_candidate "$(command -v python3)"
fi
add_python_candidate "/usr/bin/python3"

SELECTED_PYTHON=""
for candidate in "${PYTHON_CANDIDATES[@]}"; do
    if python_usable "$candidate"; then
        SELECTED_PYTHON="$candidate"
        break
    fi

    echo "Warning: skipping unusable Python: $candidate"
done

if [[ -z "$SELECTED_PYTHON" ]]; then
    echo "Error: no usable Python interpreter found for Neovim."
    exit 1
fi

TMP_VENV="$PYNVIM_VENV.tmp.$$"
trap 'rm -rf "$TMP_VENV"' EXIT

echo "Creating Neovim Python provider venv with $SELECTED_PYTHON..."
"$SELECTED_PYTHON" -m venv "$TMP_VENV"
"$TMP_VENV/bin/python" -m pip install --upgrade pip pynvim

rm -rf "$PYNVIM_VENV"
mv "$TMP_VENV" "$PYNVIM_VENV"
trap - EXIT

echo "Verifying Neovim and tmux..."
nvim --version | head -n 1
tmux -V

echo "Neovim Python provider: $PYNVIM_VENV/bin/python"
echo "Neovim support configured."
