#!/usr/bin/env bash
#
# setup/check-tool-parity.sh — READ-ONLY maintenance guard against the bug
# class found in the 2026-08-02 forensic audit: Brewfile.headless,
# setup/linux-headless.sh, and setup/headless-doctor.sh each hand-maintain
# their own independent list of tools, so nothing forces them to agree.
# `gh` was installed on macOS headless but absent from every Linux package
# list and never checked by the doctor — the doctor still reported 61/61.
# This script extracts tool names from all three sources and fails loudly on
# any divergence not explicitly recorded in setup/tool-parity-exceptions.txt.
#
# This script never installs, edits, or repairs anything — it only reads the
# three source files and the exceptions file, then reports. Not wired into
# `setup`/`setup-headless` as a hard gate (see the Makefile's
# `check-tool-parity` target comment): this is a maintenance check for the
# person editing these files, not a worker-provisioning gate. Failing a real
# provisioning run over e.g. a missing convenience-tool doctor check would be
# worse than the disease it prevents.
#
# Usage: setup/check-tool-parity.sh
# Exit 0 if every divergence is either absent or explicitly allowlisted;
# exit 1 if any UN-allowlisted divergence is found.
#
# Portability: written for bash (uses [[ ]], =~, arrays) — this is a
# developer-machine maintenance script, not part of the noninteractive
# worker-provisioning path, so it does not need setup/headless-doctor.sh's
# bash-3.2/POSIX-sh portability constraints. Still avoids bash 4+-only
# features (associative arrays, ${var,,}) so it also runs fine under macOS's
# stock /bin/bash 3.2.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

BREWFILE="$DOTFILES_DIR/Brewfile.headless"
LINUX_HEADLESS="$DOTFILES_DIR/setup/linux-headless.sh"
DOCTOR="$DOTFILES_DIR/setup/headless-doctor.sh"
EXCEPTIONS="$DOTFILES_DIR/setup/tool-parity-exceptions.txt"

for f in "$BREWFILE" "$LINUX_HEADLESS" "$DOCTOR" "$EXCEPTIONS"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: expected file not found: $f" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Name-mapping table: formula/package name -> canonical tool identity.
#
# The three sources name the same tool differently depending on ecosystem
# (Homebrew formula name, distro package name, or the binary the doctor
# actually invokes), so raw string comparison would report false positives
# on every one of these. This is the ONE place that mapping is encoded —
# extend it here, not by adding an allowlist entry, whenever a real gap
# turns out to just be a naming difference.
#
#   git-delta (apt/dnf/pacman/zypper), delta (apk, and the brew formula's
#     own binary name)                                -> delta
#   neovim (brew formula and every distro package)      -> nvim (the binary,
#     and what headless-doctor.sh/REQUIRED_CMDS actually checks)
#   universal-ctags (apt, brew formula), ctags
#     (dnf/pacman/zypper/apk)                           -> ctags
#   trash-cli (brew formula)                            -> trash (the binary;
#     zsh/.zshrc's rm() wrapper also accepts trash-put, a different package
#     entirely, not aliased here)
#   ripgrep (brew formula and every distro package)     -> rg (the binary)
#   fd-find (apt/dnf package name; binary is `fdfind` on Debian/Ubuntu
#     specifically, aliased in zsh/.zshrc), fd (brew formula, pacman/zypper/
#     apk package name, and the binary everywhere else) -> fd
#   bat (brew formula and every distro package name; binary is `batcat` on
#     Debian/Ubuntu specifically, aliased in zsh/.zshrc, because a different
#     Debian package already owns the name `bat`) -> bat
#   openssh-client (apt/apk), openssh-clients (dnf), openssh (pacman/zypper)
#                                                        -> ssh (the binary;
#     headless-doctor.sh's REQUIRED_CMDS checks `ssh`, not a package name)
#   g++ (apt/apk), gcc-c++ (dnf/zypper)                 -> g++
#   pkg-config (apt/zypper), pkgconf-pkg-config (dnf),
#     pkgconf (pacman/apk)                               -> pkg-config
#   libpq (brew formula), postgresql-client + libpq-dev (apt), postgresql +
#     postgresql-devel (dnf), postgresql-libs (pacman), postgresql-devel
#     (zypper), postgresql-dev (apk)                     -> libpq
#   python@3.12 (brew formula), python3 (apt/dnf/zypper/apk package/binary),
#     python (pacman package)                            -> python3
#   docker.io (apt docker binary package), docker (brew formula, dnf/pacman/
#     zypper/apk package)                                -> docker
#   docker-compose-plugin (apt/dnf), docker-compose (brew formula, pacman/
#     zypper), docker-cli-compose (apk)                  -> docker-compose
#
# Tap-prefixed brew lines (e.g. "jesseduffield/lazydocker/lazydocker",
# "supabase/tap/supabase", "zippoxer/tap/recall") are reduced to their last
# path segment BEFORE reaching this function (see extract_brewfile below),
# since the tap prefix is a Homebrew-only concept with no Linux analog.
canonicalize() {
  case "$1" in
    git-delta | delta) echo "delta" ;;
    neovim) echo "nvim" ;;
    universal-ctags | ctags) echo "ctags" ;;
    trash-cli) echo "trash" ;;
    ripgrep) echo "rg" ;;
    fd-find | fd) echo "fd" ;;
    bat) echo "bat" ;;
    openssh-client | openssh-clients | openssh) echo "ssh" ;;
    "g++" | gcc-c++) echo "g++" ;;
    pkg-config | pkgconf-pkg-config | pkgconf) echo "pkg-config" ;;
    libpq | postgresql-client | libpq-dev | postgresql | postgresql-devel | postgresql-libs | postgresql-dev)
      echo "libpq"
      ;;
    python3 | python | python@*) echo "python3" ;;
    docker.io) echo "docker" ;;
    docker-compose-plugin | docker-cli-compose) echo "docker-compose" ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Source A: every `brew "..."` line in Brewfile.headless.
# ---------------------------------------------------------------------------
extract_brewfile() {
  local raw base
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    base="${raw##*/}" # strip any tap prefix (owner/tap/formula -> formula)
    canonicalize "$base"
  done < <(grep -oE '^brew "[^"]+"' "$BREWFILE" | sed -E 's/^brew "//; s/"$//')
}

# ---------------------------------------------------------------------------
# Source B: the required=(...) / optional=(...) arrays in
# setup/linux-headless.sh, across every package manager branch. Deliberately
# scoped to ONLY these two array literals (not verify_commands()'s unrelated
# required_commands=(...) array, and not the separate install_optional_
# packages calls in the INSTALL_DOCKER block or install_stripe_cli/
# install_tailscale, which install by a different mechanism — see
# tool-parity-exceptions.txt for docker/docker-compose/tailscale/stripe-cli).
# ---------------------------------------------------------------------------
extract_linux_headless() {
  local line in_array=0 stripped tok
  while IFS= read -r line; do
    if [[ "$in_array" -eq 0 ]]; then
      if [[ "$line" =~ ^[[:space:]]*(required|optional)=\($ ]]; then
        in_array=1
      fi
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\)[[:space:]]*$ ]]; then
      in_array=0
      continue
    fi
    stripped="${line%%#*}" # drop inline comments before splitting on words
    for tok in $stripped; do
      canonicalize "$tok"
    done
  done <"$LINUX_HEADLESS"
}

# ---------------------------------------------------------------------------
# Source C: REQUIRED_CMDS in setup/headless-doctor.sh.
# ---------------------------------------------------------------------------
extract_doctor() {
  local raw tok
  raw="$(grep -m1 '^REQUIRED_CMDS=' "$DOCTOR" | sed -E 's/^REQUIRED_CMDS="//; s/"$//')"
  for tok in $raw; do
    canonicalize "$tok"
  done
}

# ---------------------------------------------------------------------------
# Allowlist: "<name> <reason...>" per line, name canonicalized on load so it
# matches the same domain the checks below compare in.
# ---------------------------------------------------------------------------
declare -a ALLOW_NAMES=()
declare -a ALLOW_REASONS=()
load_exceptions() {
  local line name rest canon
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    name="${line%%[[:space:]]*}"
    rest="${line#"$name"}"
    rest="${rest#"${rest%%[![:space:]]*}"}" # trim leading whitespace
    canon="$(canonicalize "$name")"
    ALLOW_NAMES+=("$canon")
    ALLOW_REASONS+=("$rest")
  done <"$EXCEPTIONS"
}

is_allowed() {
  local target="$1" i
  for i in "${!ALLOW_NAMES[@]}"; do
    [[ "${ALLOW_NAMES[$i]}" == "$target" ]] && return 0
  done
  return 1
}

allow_reason() {
  local target="$1" i
  for i in "${!ALLOW_NAMES[@]}"; do
    if [[ "${ALLOW_NAMES[$i]}" == "$target" ]]; then
      printf '%s' "${ALLOW_REASONS[$i]}"
      return 0
    fi
  done
}

# unique_sorted -> reads names on stdin (one per line), prints them
# deduplicated and sorted. Also drops blank lines so a canonicalize() case
# that ever produced an empty string can't silently pollute a set.
unique_sorted() {
  sed '/^$/d' | sort -u
}

# contains <needle> <haystack-array-name...> — pass haystack as remaining args
contains() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Build the three canonicalized sets. Populated via process substitution
# (`< <(...)`), NOT a trailing pipe (`... | while read ...`) — a pipe's
# right-hand side runs in a subshell under bash 3.2 (no `lastpipe`, that's
# bash 4.2+), so array appends inside it would silently vanish once the
# pipeline exits. Process substitution keeps the while loop in THIS shell.
# ---------------------------------------------------------------------------
declare -a A_LIST=()
declare -a B_LIST=()
declare -a C_LIST=()

while IFS= read -r __name; do
  [[ -n "$__name" ]] && A_LIST+=("$__name")
done < <(extract_brewfile | unique_sorted)

while IFS= read -r __name; do
  [[ -n "$__name" ]] && B_LIST+=("$__name")
done < <(extract_linux_headless | unique_sorted)

while IFS= read -r __name; do
  [[ -n "$__name" ]] && C_LIST+=("$__name")
done < <(extract_doctor | unique_sorted)

load_exceptions

echo "Tool parity check"
echo "  Source A (Brewfile.headless \"brew\" lines):            ${#A_LIST[@]} tools"
echo "  Source B (linux-headless.sh required()+optional()):    ${#B_LIST[@]} tools"
echo "  Source C (headless-doctor.sh REQUIRED_CMDS):            ${#C_LIST[@]} tools"
echo "  Allowlist (tool-parity-exceptions.txt):                 ${#ALLOW_NAMES[@]} entries"
echo "----------------------------------------------------------------------"

VIOLATIONS=0
SKIPPED=0

# ---------------------------------------------------------------------------
# Check 1 (A - B): every Homebrew tool should have SOME Linux representation
# (required OR optional) — this is the exact shape of the eza/zsh-
# autosuggestions bug the forensic audit found: promised in Brewfile/README,
# absent from every Linux list.
# ---------------------------------------------------------------------------
echo "-- Check 1: Brewfile.headless tools with no Linux package-list entry --"
check1_hits=0
for name in "${A_LIST[@]}"; do
  if contains "$name" "${B_LIST[@]}"; then
    continue
  fi
  check1_hits=$((check1_hits + 1))
  if is_allowed "$name"; then
    SKIPPED=$((SKIPPED + 1))
    echo "  SKIP (allowlisted) $name -- $(allow_reason "$name")"
  else
    VIOLATIONS=$((VIOLATIONS + 1))
    echo "  FAIL $name is in Brewfile.headless but not in any setup/linux-headless.sh required()/optional() array, and is not in tool-parity-exceptions.txt"
  fi
done
[[ "$check1_hits" -eq 0 ]] && echo "  (none)"

# ---------------------------------------------------------------------------
# Check 2 (B required - C): this is the exact shape of the gh/delta bug —
# a package REQUIRED on Linux (meaning its absence is fatal to the worker
# contract) that headless-doctor.sh's REQUIRED_CMDS never actually verifies.
# Only "required" tokens are checked here; optional/convenience packages are
# never expected in REQUIRED_CMDS by design (see the Makefile comment and
# docs/headless-vs-local.md).
# ---------------------------------------------------------------------------
echo "-- Check 2: Linux REQUIRED packages with no headless-doctor.sh REQUIRED_CMDS check --"
extract_linux_required() {
  local line in_array=0 stripped tok
  while IFS= read -r line; do
    if [[ "$in_array" -eq 0 ]]; then
      if [[ "$line" =~ ^[[:space:]]*required=\($ ]]; then
        in_array=1
      fi
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\)[[:space:]]*$ ]]; then
      in_array=0
      continue
    fi
    stripped="${line%%#*}"
    for tok in $stripped; do
      canonicalize "$tok"
    done
  done <"$LINUX_HEADLESS"
}
declare -a B_REQUIRED_LIST=()
while IFS= read -r __name; do
  [[ -n "$__name" ]] && B_REQUIRED_LIST+=("$__name")
done < <(extract_linux_required | unique_sorted)
check2_hits=0
for name in "${B_REQUIRED_LIST[@]}"; do
  if contains "$name" "${C_LIST[@]}"; then
    continue
  fi
  check2_hits=$((check2_hits + 1))
  if is_allowed "$name"; then
    SKIPPED=$((SKIPPED + 1))
    echo "  SKIP (allowlisted) $name -- $(allow_reason "$name")"
  else
    VIOLATIONS=$((VIOLATIONS + 1))
    echo "  FAIL $name is REQUIRED in setup/linux-headless.sh but not in headless-doctor.sh's REQUIRED_CMDS, and is not in tool-parity-exceptions.txt"
  fi
done
[[ "$check2_hits" -eq 0 ]] && echo "  (none)"

# ---------------------------------------------------------------------------
# Check 3 (C - (A union B)): a doctor REQUIRED_CMDS entry that cannot be
# traced back to either Brewfile.headless or setup/linux-headless.sh is
# either installed by some other mechanism (allowlist it, category
# "installed by a mechanism other than the package arrays") or is a stale/
# orphaned check with no real install path behind it.
# ---------------------------------------------------------------------------
echo "-- Check 3: headless-doctor.sh REQUIRED_CMDS entries untraceable to Brewfile.headless or linux-headless.sh --"
check3_hits=0
for name in "${C_LIST[@]}"; do
  if contains "$name" "${A_LIST[@]}" || contains "$name" "${B_LIST[@]}"; then
    continue
  fi
  check3_hits=$((check3_hits + 1))
  if is_allowed "$name"; then
    SKIPPED=$((SKIPPED + 1))
    echo "  SKIP (allowlisted) $name -- $(allow_reason "$name")"
  else
    VIOLATIONS=$((VIOLATIONS + 1))
    echo "  FAIL $name is checked by headless-doctor.sh's REQUIRED_CMDS but traces to no brew formula or Linux package, and is not in tool-parity-exceptions.txt"
  fi
done
[[ "$check3_hits" -eq 0 ]] && echo "  (none)"

echo "----------------------------------------------------------------------"
if [[ "$VIOLATIONS" -eq 0 ]]; then
  echo "PASS: no un-allowlisted tool-parity divergences ($SKIPPED allowlisted divergence(s) skipped)."
  exit 0
else
  echo "FAIL: $VIOLATIONS un-allowlisted tool-parity divergence(s) found ($SKIPPED allowlisted divergence(s) skipped)."
  echo "Fix by adding the tool to the missing source(s), or, if the divergence is intentional, add a one-line reason to $EXCEPTIONS."
  exit 1
fi
