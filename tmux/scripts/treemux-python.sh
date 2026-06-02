#!/bin/bash

PYNVIM_PYTHON="$HOME/.local/share/nvim/pynvim-venv/bin/python"

if [[ -x "$PYNVIM_PYTHON" ]]; then
    exec "$PYNVIM_PYTHON" "$@"
fi

if command -v python3.12 >/dev/null 2>&1; then
    exec python3.12 "$@"
fi

exec python3 "$@"
