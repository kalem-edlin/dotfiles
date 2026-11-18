#!/usr/bin/env bash
#
# setup/rea.sh - REA checkout plus the JDK and Ghidra it drives, for focus
# machines and headless workers alike (`make rea`; wired into `make setup`
# and both headless lanes).
#
#   ~/Developer/rea                          git@github.com:morluto/rea.git
#                                            with submodules, npm ci, build
#   ~/Developer/tools/jdk-<JDK_RELEASE>      Temurin JDK 21, pinned sha256
#   ~/Developer/tools/ghidra_<VER>_PUBLIC    Ghidra release zip, pinned sha256
#
# Deliberately NOT run: REA's install.sh (global npm install), its global
# agent skills, and .mcp.json rendering. Consumers spawn REA from the
# checkout (`node dist/main.js` with cwd ~/Developer/rea) and take JAVA_HOME
# and GHIDRA_INSTALL_DIR from zsh/.zshenv.
#
# Rerun is the update contract, and every step is idempotent:
#   - An existing checkout is only fetched and has its submodules initialized
#     and synced to the recorded commits. Its branch, HEAD and working tree
#     are never reset, merged or rebased: on a focus machine it is a live
#     checkout. Pull it yourself to move it forward.
#   - `npm ci` runs only when node_modules is missing or package-lock.json is
#     newer than npm's install record (node_modules/.package-lock.json), under
#     the Node version in REA's .nvmrc (fnm, installed by setup/node.sh).
#     `npm run build` (tsc into dist/, gitignored) runs after any npm ci, or
#     when dist/main.js is missing.
#   - The JDK and Ghidra directories are left alone once they exist; a new
#     pin installs side by side under a new directory name.
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
# REA_DIR and REA_TOOLS_DIR override the two roots (tests only).

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup/lib.sh
. "$DOTFILES_DIR/setup/lib.sh"

REA_REPO_URL="git@github.com:morluto/rea.git"
REA_DIR="${REA_DIR:-$HOME/Developer/rea}"
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
# REA checkout
# ---------------------------------------------------------------------------

# BatchMode: fail fast with a clear error instead of hanging on a host-key or
# passphrase prompt when setup runs over a noninteractive ssh session.
rea_git() {
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git "$@"
}

rea_git_failed() {
    echo "Error: $1 failed for $REA_REPO_URL." >&2
    echo "  This machine's SSH key must be registered with GitHub and github.com" >&2
    echo "  must be in ~/.ssh/known_hosts. Check with: ssh -T git@github.com" >&2
    exit 1
}

sync_rea_checkout() {
    local origin

    mkdir -p "$(dirname "$REA_DIR")"

    if [[ ! -e "$REA_DIR" ]]; then
        echo "Cloning REA into $REA_DIR..."
        rea_git clone --recurse-submodules "$REA_REPO_URL" "$REA_DIR" ||
            rea_git_failed "git clone"
        return
    fi

    if ! git -C "$REA_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        [[ "$(git -C "$REA_DIR" rev-parse --show-toplevel)" != "$(cd "$REA_DIR" && pwd -P)" ]]; then
        echo "Error: $REA_DIR exists but is not a git checkout; move it aside and rerun." >&2
        exit 1
    fi

    origin="$(git -C "$REA_DIR" remote get-url origin 2>/dev/null || true)"
    case "$origin" in
        *morluto/rea | *morluto/rea.git) ;;
        *)
            echo "Error: $REA_DIR has origin '${origin:-<none>}', expected $REA_REPO_URL." >&2
            exit 1
            ;;
    esac

    # Fetch only: the branch and working tree belong to whoever uses this
    # checkout, so nothing here merges, resets or switches branches.
    echo "Fetching REA in $REA_DIR (branch and working tree left as they are)..."
    rea_git -C "$REA_DIR" fetch origin || rea_git_failed "git fetch"
    rea_git -C "$REA_DIR" submodule update --init --recursive ||
        rea_git_failed "git submodule update"
}

# npm writes node_modules/.package-lock.json on every install; it is a better
# freshness stamp than the node_modules directory's own mtime.
rea_needs_npm_ci() {
    local stamp="$REA_DIR/node_modules/.package-lock.json"
    [[ -d "$REA_DIR/node_modules" ]] || return 0
    [[ -f "$stamp" ]] || stamp="$REA_DIR/node_modules"
    [[ "$REA_DIR/package-lock.json" -nt "$stamp" ]]
}

sync_rea_node_modules() {
    local ran_ci=0

    cd "$REA_DIR"
    if rea_needs_npm_ci || [[ ! -f dist/main.js ]]; then
        if ! activate_fnm; then
            echo "Error: fnm not found; run make node first." >&2
            exit 1
        fi
        # Reads REA's .nvmrc; installs that Node under fnm if it is missing.
        fnm use --install-if-missing --silent-if-unchanged
        echo "Using Node $(node --version) for REA (.nvmrc: $(cat .nvmrc 2>/dev/null || echo none))"
    fi

    if rea_needs_npm_ci; then
        echo "Installing REA dependencies (npm ci)..."
        npm ci
        ran_ci=1
    else
        echo "✓ REA node_modules up to date with package-lock.json"
    fi

    if [[ "$ran_ci" -eq 1 || ! -f dist/main.js ]]; then
        echo "Building REA (npm run build -> dist/)..."
        npm run build
    else
        echo "✓ REA dist/main.js present"
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

sync_rea_checkout
sync_rea_node_modules
install_jdk
install_ghidra

echo "✓ REA, JDK $JDK_RELEASE and Ghidra $GHIDRA_VERSION ready"
