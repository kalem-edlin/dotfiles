#!/bin/bash

set -euo pipefail

# Pinned Go toolchain for Linux workers. tmux-agent-sessions builds its
# picker (bin/agent-picker) with it during install_tmux_plugins. Not apt:
# Ubuntu 24.04's golang-go is 1.22, older than the picker module needs.
# macOS gets Go from the Brewfiles instead.
GO_VERSION=1.26.3
# From https://go.dev/dl/?mode=json&include=all, cross-checked against the
# dl.google.com .sha256 files and the downloaded tarballs.
GO_SHA256_LINUX_AMD64=2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556
GO_SHA256_LINUX_ARM64=9d89a3ea57d141c2b22d70083f2c8459ba3890f2d9e818e7e933b75614936565

# ~/.local/bin precedes /usr/bin in the managed worker PATH, so a distro
# golang-go never shadows the pinned toolchain.
export PATH="$HOME/.local/bin:$PATH"

go_pinned() {
    command -v go >/dev/null 2>&1 || return 1
    [[ "$(go version 2>/dev/null)" == "go version go$GO_VERSION "* ]]
}

cleanup_go_download() {
    if [[ -n "${GO_DOWNLOAD_TEMP:-}" && -d "$GO_DOWNLOAD_TEMP" ]]; then
        rm -rf "$GO_DOWNLOAD_TEMP"
    fi
}

install_pinned_linux_go() {
    local machine release_arch sha256 asset url archive
    local install_dir tool link_temp

    machine="$(uname -m)"
    case "$machine" in
        x86_64 | amd64)
            release_arch="amd64"
            sha256="$GO_SHA256_LINUX_AMD64"
            ;;
        aarch64 | arm64)
            release_arch="arm64"
            sha256="$GO_SHA256_LINUX_ARM64"
            ;;
        *)
            echo "Error: no pinned Go tarball for Linux architecture: $machine" >&2
            exit 1
            ;;
    esac

    asset="go$GO_VERSION.linux-$release_arch.tar.gz"
    url="https://go.dev/dl/$asset"
    install_dir="$HOME/.local/opt/go-$GO_VERSION"
    GO_DOWNLOAD_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-go.XXXXXX")"
    archive="$GO_DOWNLOAD_TEMP/$asset"
    trap cleanup_go_download EXIT

    if [[ ! -x "$install_dir/bin/go" ]]; then
        echo "Installing Go $GO_VERSION for Linux $machine..."
        curl --fail --location --retry 3 --output "$archive" "$url"
        (cd "$GO_DOWNLOAD_TEMP" && echo "$sha256  $asset" | sha256sum -c -)
        tar -xzf "$archive" -C "$GO_DOWNLOAD_TEMP"

        mkdir -p "$HOME/.local/opt"
        rm -rf "$install_dir"
        mv "$GO_DOWNLOAD_TEMP/go" "$install_dir"
    fi

    # Replace the commands atomically without deleting an existing distro
    # package.
    mkdir -p "$HOME/.local/bin"
    for tool in go gofmt; do
        link_temp="$GO_DOWNLOAD_TEMP/$tool-link"
        ln -s "$install_dir/bin/$tool" "$link_temp"
        mv -f "$link_temp" "$HOME/.local/bin/$tool"
    done

    trap - EXIT
    cleanup_go_download
    GO_DOWNLOAD_TEMP=""
}

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Error: setup/go.sh is only for Linux; macOS gets Go from the Brewfile." >&2
    exit 1
fi

if go_pinned; then
    echo "✓ Go $GO_VERSION already installed"
    exit 0
fi

install_pinned_linux_go
hash -r

if ! go_pinned; then
    echo "Error: Go $GO_VERSION is still unavailable after installation (found: $(go version 2>/dev/null || echo none))." >&2
    exit 1
fi

go version
