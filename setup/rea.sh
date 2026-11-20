#!/usr/bin/env bash
#
# setup/rea.sh - the pinned tools under ~/Developer/tools that the REA and
# idol-app workflows drive, for focus machines and headless workers alike
# (`make rea`; wired into `make setup` and both headless lanes). No git
# checkout of REA is made.
#
#   ~/Developer/tools/jdk-<JDK_RELEASE>      Temurin JDK 21, pinned sha256
#   ~/Developer/tools/ghidra_<VER>_PUBLIC    Ghidra release zip, pinned sha256
#   ~/Developer/tools/ipatool/ipatool        ipatool <IPATOOL_VERSION>, pinned sha256,
#                                            symlinked from the versioned binary
#
# Take JAVA_HOME and GHIDRA_INSTALL_DIR from zsh/.zshenv. ipatool needs a
# one-time `ipatool auth login` per machine (Apple ID, 2FA, keychain); this
# script never handles credentials.
#
# Rerun is the update contract, and every step is idempotent: the JDK and
# Ghidra directories are left alone once they exist; a new pin installs side
# by side under a new directory name. ipatool's versioned binary is likewise
# kept once present, and the `ipatool` symlink is repointed at it.
#
# Ghidra's public zip ships the decompiler native only for linux_x86_64 and
# Windows. On macOS (both arches) and Linux aarch64 this script builds it
# from the zip's own sources (make + a C++ compiler: Xcode CLT on macOS, the
# build toolchain setup/linux-headless.sh already requires on Linux) and
# installs it as Ghidra/Features/Decompiler/os/<platform>/decompile.
#
# Downloads land in a temporary directory inside ~/Developer/tools (not
# /tmp, which is RAM-backed on some Linux hosts) and are moved into place
# only after the checksum and layout checks pass, so an interrupted run
# never leaves a half-installed tool under its final name.
#
# REA_TOOLS_DIR overrides the tools root (tests only).

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup/lib.sh
. "$DOTFILES_DIR/setup/lib.sh"

TOOLS_DIR="${REA_TOOLS_DIR:-$HOME/Developer/tools}"

# Eclipse Temurin, github.com/adoptium/temurin21-binaries release
# jdk-$JDK_RELEASE. sha256 from the release's .sha256.txt files, cross-checked
# against the GitHub asset digests and the downloaded tarballs (2026-11-18).
# headless-doctor.sh and zsh/.zshenv read the directory name from this pin;
# keep zsh/.zshenv in sync when it changes.
JDK_RELEASE=21.0.12.1+1
JDK_SHA256_MAC_AARCH64=3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998
JDK_SHA256_MAC_X64=44db0f08196daf19a47f90d13388b0c943b67663cb537f998fe29e836fa842ce
JDK_SHA256_LINUX_AARCH64=23e37e026f12f3e706f18938ff611db3032d075b09d0879a25d06718c773e223
JDK_SHA256_LINUX_X64=ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94

# github.com/NationalSecurityAgency/ghidra release Ghidra_${GHIDRA_VERSION}_build.
# sha256 from the release notes, cross-checked against the GitHub asset
# digest and the downloaded zip (2026-11-18). One zip for every platform.
GHIDRA_VERSION=12.1.4
GHIDRA_BUILD_DATE=20260921
GHIDRA_SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db

# github.com/majd/ipatool release v$IPATOOL_VERSION, one tar.gz per platform
# (each holds bin/ipatool-$IPATOOL_VERSION-<os>-<arch>). sha256 from the
# release's GitHub asset digests, cross-checked against the downloaded
# archives and the macOS arm64 binary already in use (2026-11-20).
IPATOOL_VERSION=2.7.0
IPATOOL_SHA256_MAC_ARM64=5ae100d4520cf4b3f4374239e5925a9ad9a8dc02abc16bae27479e7ae99aca33
IPATOOL_SHA256_MAC_X64=05f48994d8b3cfefe7ea1172a0ac0b28715888e9df0af38cf3e490d2ed592263
IPATOOL_SHA256_LINUX_X64=68372de9743d468296f2dba5b413a3e7df56ad0c85b8d0f4f0f6c9b8b53a54e8
IPATOOL_SHA256_LINUX_ARM64=133c3fb754bafcd61698ba6047b48096c7033345529f57d7a83d281f8a403c23

OS_NAME="$(uname -s)"
MACHINE="$(uname -m)"

case "$OS_NAME" in
    Darwin | Linux) ;;
    *)
        echo "Error: setup/rea.sh supports macOS and Linux only (uname -s: $OS_NAME)." >&2
        exit 1
        ;;
esac

DOWNLOAD_TEMP=""
cleanup_download() {
    if [[ -n "$DOWNLOAD_TEMP" && -d "$DOWNLOAD_TEMP" ]]; then
        rm -rf "$DOWNLOAD_TEMP"
    fi
    DOWNLOAD_TEMP=""
}
trap cleanup_download EXIT

new_download_temp() {
    cleanup_download
    mkdir -p "$TOOLS_DIR"
    DOWNLOAD_TEMP="$(mktemp -d "$TOOLS_DIR/.rea-download.XXXXXX")"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# fetch_verified <url> <sha256> <dest>
fetch_verified() {
    local url="$1" expected="$2" dest="$3" actual
    curl --fail --location --retry 3 --silent --show-error --output "$dest" "$url"
    actual="$(sha256_of "$dest")"
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: sha256 mismatch for $url" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# JDK
# ---------------------------------------------------------------------------

jdk_home_of() {
    if [[ "$OS_NAME" = "Darwin" ]]; then
        printf '%s/Contents/Home\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

install_jdk() {
    local dir="$TOOLS_DIR/jdk-$JDK_RELEASE"
    local os arch sha256 asset url extracted

    if [[ -d "$dir" ]]; then
        if [[ -x "$(jdk_home_of "$dir")/bin/java" ]]; then
            echo "✓ JDK $JDK_RELEASE already installed: $dir"
            return
        fi
        echo "Error: $dir exists but has no bin/java; remove it and rerun." >&2
        exit 1
    fi

    case "$OS_NAME:$MACHINE" in
        Darwin:arm64) os=mac arch=aarch64 sha256="$JDK_SHA256_MAC_AARCH64" ;;
        Darwin:x86_64) os=mac arch=x64 sha256="$JDK_SHA256_MAC_X64" ;;
        Linux:aarch64 | Linux:arm64) os=linux arch=aarch64 sha256="$JDK_SHA256_LINUX_AARCH64" ;;
        Linux:x86_64 | Linux:amd64) os=linux arch=x64 sha256="$JDK_SHA256_LINUX_X64" ;;
        *)
            echo "Error: no pinned JDK archive for $OS_NAME $MACHINE." >&2
            exit 1
            ;;
    esac

    asset="OpenJDK21U-jdk_${arch}_${os}_hotspot_${JDK_RELEASE/+/_}.tar.gz"
    url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_RELEASE/+/%2B}/$asset"

    echo "Installing JDK $JDK_RELEASE ($os $arch)..."
    new_download_temp
    fetch_verified "$url" "$sha256" "$DOWNLOAD_TEMP/$asset"
    mkdir "$DOWNLOAD_TEMP/x"
    tar -xzf "$DOWNLOAD_TEMP/$asset" -C "$DOWNLOAD_TEMP/x"
    extracted="$DOWNLOAD_TEMP/x/jdk-$JDK_RELEASE"
    if ! "$(jdk_home_of "$extracted")/bin/java" -version >/dev/null 2>&1; then
        echo "Error: the extracted JDK does not run ($extracted)." >&2
        exit 1
    fi
    mv "$extracted" "$dir"
    cleanup_download
    echo "✓ JDK $JDK_RELEASE installed: $dir"
}

# ---------------------------------------------------------------------------
# Ghidra
# ---------------------------------------------------------------------------

# Prints "<os dir> <compiler arch flags>" for a platform whose decompiler
# native must be built, nothing for one the zip already covers.
ghidra_native_build_target() {
    case "$OS_NAME:$MACHINE" in
        Darwin:arm64) echo "mac_arm_64 -arch arm64" ;;
        Darwin:x86_64) echo "mac_x86_64 -arch x86_64" ;;
        Linux:aarch64 | Linux:arm64) echo "linux_arm_64" ;;
        Linux:x86_64 | Linux:amd64) ;;
        *)
            echo "Error: no Ghidra decompiler build recipe for $OS_NAME $MACHINE." >&2
            exit 1
            ;;
    esac
}

# ensure_ghidra_decompiler <ghidra root>
ensure_ghidra_decompiler() {
    local root="$1" target osdir arch_flags cpp jobs tool
    local -a flags

    target="$(ghidra_native_build_target)"
    [[ -n "$target" ]] || return 0
    osdir="${target%% *}"
    arch_flags=""
    [[ "$target" = *" "* ]] && arch_flags="${target#* }"

    if [[ -x "$root/Ghidra/Features/Decompiler/os/$osdir/decompile" ]]; then
        return 0
    fi

    for tool in make g++; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: $tool is required to build Ghidra's $osdir decompiler (Xcode CLT on macOS, the build toolchain on Linux)." >&2
            exit 1
        fi
    done

    cpp="$root/Ghidra/Features/Decompiler/src/decompile/cpp"
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    echo "Building Ghidra's decompiler for $osdir (no prebuilt native in the release zip)..."
    # The Makefile hard-codes x86_64 for Darwin and -m32 for non-x86_64
    # Linux; ARCH_TYPE and ADDITIONAL_FLAGS on the command line override both.
    flags=("ARCH_TYPE=$arch_flags")
    [[ "$OS_NAME" = "Darwin" ]] && flags+=("ADDITIONAL_FLAGS=-w")
    # stderr's "ghi_opt/depend: No such file or directory" on a first build is
    # make reporting the dependency file it is about to generate.
    make -C "$cpp" -j "$jobs" "${flags[@]}" ghidra_opt >/dev/null
    mkdir -p "$root/Ghidra/Features/Decompiler/os/$osdir"
    cp "$cpp/ghidra_opt" "$root/Ghidra/Features/Decompiler/os/$osdir/decompile.tmp.$$"
    chmod 755 "$root/Ghidra/Features/Decompiler/os/$osdir/decompile.tmp.$$"
    mv -f "$root/Ghidra/Features/Decompiler/os/$osdir/decompile.tmp.$$" \
        "$root/Ghidra/Features/Decompiler/os/$osdir/decompile"
    rm -rf "$cpp/ghi_opt" "$cpp/ghidra_opt"
    echo "✓ Ghidra decompiler built: Ghidra/Features/Decompiler/os/$osdir/decompile"
}

install_ghidra() {
    local dir="$TOOLS_DIR/ghidra_${GHIDRA_VERSION}_PUBLIC"
    local asset="ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_BUILD_DATE}.zip"
    local url="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/$asset"
    local extracted

    if [[ -d "$dir" ]]; then
        if [[ ! -x "$dir/support/analyzeHeadless" ]]; then
            echo "Error: $dir exists but has no support/analyzeHeadless; remove it and rerun." >&2
            exit 1
        fi
        ensure_ghidra_decompiler "$dir"
        echo "✓ Ghidra $GHIDRA_VERSION already installed: $dir"
        return
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        echo "Error: unzip is required to install Ghidra." >&2
        exit 1
    fi

    echo "Installing Ghidra $GHIDRA_VERSION..."
    new_download_temp
    fetch_verified "$url" "$GHIDRA_SHA256" "$DOWNLOAD_TEMP/$asset"
    mkdir "$DOWNLOAD_TEMP/x"
    unzip -q "$DOWNLOAD_TEMP/$asset" -d "$DOWNLOAD_TEMP/x"
    rm -f "$DOWNLOAD_TEMP/$asset"
    extracted="$DOWNLOAD_TEMP/x/ghidra_${GHIDRA_VERSION}_PUBLIC"
    if [[ ! -x "$extracted/support/analyzeHeadless" ]]; then
        echo "Error: the Ghidra zip did not unpack to the expected layout ($extracted)." >&2
        exit 1
    fi
    ensure_ghidra_decompiler "$extracted"
    mv "$extracted" "$dir"
    cleanup_download
    echo "✓ Ghidra $GHIDRA_VERSION installed: $dir"
}

# ---------------------------------------------------------------------------
# ipatool
# ---------------------------------------------------------------------------

install_ipatool() {
    local dir="$TOOLS_DIR/ipatool"
    local os arch sha256 asset url name extracted link_temp version_out

    case "$OS_NAME:$MACHINE" in
        Darwin:arm64) os=macos arch=arm64 sha256="$IPATOOL_SHA256_MAC_ARM64" ;;
        Darwin:x86_64) os=macos arch=amd64 sha256="$IPATOOL_SHA256_MAC_X64" ;;
        Linux:aarch64 | Linux:arm64) os=linux arch=arm64 sha256="$IPATOOL_SHA256_LINUX_ARM64" ;;
        Linux:x86_64 | Linux:amd64) os=linux arch=amd64 sha256="$IPATOOL_SHA256_LINUX_X64" ;;
        *)
            echo "Error: no pinned ipatool archive for $OS_NAME $MACHINE." >&2
            exit 1
            ;;
    esac

    name="ipatool-$IPATOOL_VERSION-$os-$arch"
    asset="$name.tar.gz"
    url="https://github.com/majd/ipatool/releases/download/v$IPATOOL_VERSION/$asset"

    if [[ -x "$dir/$name" ]]; then
        echo "✓ ipatool $IPATOOL_VERSION already installed: $dir/$name"
    else
        echo "Installing ipatool $IPATOOL_VERSION ($os $arch)..."
        new_download_temp
        fetch_verified "$url" "$sha256" "$DOWNLOAD_TEMP/$asset"
        mkdir "$DOWNLOAD_TEMP/x"
        tar -xzf "$DOWNLOAD_TEMP/$asset" -C "$DOWNLOAD_TEMP/x"
        extracted="$DOWNLOAD_TEMP/x/bin/$name"
        if [[ ! -f "$extracted" ]]; then
            echo "Error: the ipatool archive did not contain bin/$name." >&2
            exit 1
        fi
        chmod 755 "$extracted"
        version_out="$("$extracted" --version 2>/dev/null || true)"
        if [[ "$version_out" != *"$IPATOOL_VERSION"* ]]; then
            echo "Error: the extracted ipatool does not report version $IPATOOL_VERSION." >&2
            exit 1
        fi
        mkdir -p "$dir"
        mv -f "$extracted" "$dir/$name"
        cleanup_download
        echo "✓ ipatool $IPATOOL_VERSION installed: $dir/$name"
    fi

    # Repoint the stable name atomically; the versioned binary stays in place.
    mkdir -p "$TOOLS_DIR"
    link_temp="$dir/.ipatool-link.$$"
    ln -s "$name" "$link_temp"
    mv -f "$link_temp" "$dir/ipatool"
    echo "✓ ipatool: $dir/ipatool -> $name"
}

install_jdk
install_ghidra
install_ipatool

echo "✓ JDK $JDK_RELEASE, Ghidra $GHIDRA_VERSION and ipatool $IPATOOL_VERSION ready"
