#!/bin/bash

set -euo pipefail

NVIM_MIN_MAJOR=0
NVIM_MIN_MINOR=10

if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

# Ubuntu 24.04 supplies Neovim 0.9.5. That satisfies a command-existence
# check, but not this repository's config (vim.uv) or the Treemux stack,
# which both need Neovim >= 0.10.
export PATH="$HOME/.local/bin:$PATH"

nvim_version() {
    "$1" --version 2>/dev/null | sed -n '1s/^NVIM v\([0-9][0-9.]*\).*$/\1/p'
}

nvim_version_supported() {
    local nvim_bin="$1"
    local version major minor

    version="$(nvim_version "$nvim_bin")"
    [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"

    (( major > NVIM_MIN_MAJOR || (major == NVIM_MIN_MAJOR && minor >= NVIM_MIN_MINOR) ))
}

cleanup_nvim_download() {
    if [[ -n "${NVIM_DOWNLOAD_TEMP:-}" && -d "$NVIM_DOWNLOAD_TEMP" ]]; then
        rm -rf "$NVIM_DOWNLOAD_TEMP"
    fi
}

install_supported_linux_nvim() {
    local machine release_arch asset url archive extracted
    local installed_version install_dir link_temp

    machine="$(uname -m)"
    case "$machine" in
        x86_64 | amd64) release_arch="x86_64" ;;
        aarch64 | arm64) release_arch="arm64" ;;
        *)
            echo "Error: no official Neovim stable tarball mapping for Linux architecture: $machine" >&2
            exit 1
            ;;
    esac

    asset="nvim-linux-$release_arch"
    url="https://github.com/neovim/neovim/releases/download/stable/$asset.tar.gz"
    NVIM_DOWNLOAD_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-nvim.XXXXXX")"
    archive="$NVIM_DOWNLOAD_TEMP/$asset.tar.gz"
    extracted="$NVIM_DOWNLOAD_TEMP/$asset"
    trap cleanup_nvim_download EXIT

    echo "Installing official Neovim stable build for Linux $machine..."
    curl --fail --location --retry 3 --output "$archive" "$url"
    tar -xzf "$archive" -C "$NVIM_DOWNLOAD_TEMP"

    if [[ ! -x "$extracted/bin/nvim" ]] || ! nvim_version_supported "$extracted/bin/nvim"; then
        echo "Error: downloaded Neovim does not satisfy >= $NVIM_MIN_MAJOR.$NVIM_MIN_MINOR." >&2
        exit 1
    fi

    installed_version="$(nvim_version "$extracted/bin/nvim")"
    install_dir="$HOME/.local/opt/$asset-$installed_version"
    mkdir -p "$HOME/.local/opt" "$HOME/.local/bin"

    if [[ ! -d "$install_dir" ]]; then
        mv "$extracted" "$install_dir"
    fi

    # Replace the command atomically without deleting an existing distro
    # package. ~/.local/bin precedes /usr/bin in the managed worker PATH.
    link_temp="$NVIM_DOWNLOAD_TEMP/nvim-link"
    ln -s "$install_dir/bin/nvim" "$link_temp"
    mv -f "$link_temp" "$HOME/.local/bin/nvim"

    trap - EXIT
    cleanup_nvim_download
    NVIM_DOWNLOAD_TEMP=""
}

if ! command -v nvim >/dev/null 2>&1 || ! nvim_version_supported "$(command -v nvim)"; then
    if [[ "$(uname -s)" = "Linux" ]]; then
        install_supported_linux_nvim
        hash -r
    elif command -v nvim >/dev/null 2>&1; then
        echo "Error: Neovim $(nvim_version "$(command -v nvim)") is too old; >= $NVIM_MIN_MAJOR.$NVIM_MIN_MINOR is required." >&2
        exit 1
    else
        echo "Error: nvim not found. Install Neovim >= $NVIM_MIN_MAJOR.$NVIM_MIN_MINOR first." >&2
        exit 1
    fi
fi

if ! nvim_version_supported "$(command -v nvim)"; then
    echo "Error: Neovim >= $NVIM_MIN_MAJOR.$NVIM_MIN_MINOR is still unavailable after installation." >&2
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
