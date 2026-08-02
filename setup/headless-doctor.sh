#!/usr/bin/env bash
#
# headless-doctor.sh - READ-ONLY postflight validator for the worker contract
# documented in docs/headless-workers.md ("Required worker contract").
#
# This script never installs, edits, or repairs anything. It only inspects
# the current machine and reports PASS/FAIL/WARN per check, then exits 0 iff
# every REQUIRED check passed (WARN/optional checks never affect exit status).
#
# Usage:
#   setup/headless-doctor.sh [--profile local|headless-macos|headless-linux] [--quiet]
#
# Default profile is auto-detected: headless-macos on Darwin, headless-linux
# on Linux. "local" is only ever used when explicitly passed with --profile.
#
# Portability: must run on macOS's stock bash 3.2 and on Linux bash/dash-ish
# environments. No associative arrays, no ${var,,}, no mapfile/readarray, no
# `local -n` namerefs.

set -u

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PROFILE=""
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      shift
      PROFILE="${1:-}"
      ;;
    --profile=*)
      PROFILE="${1#--profile=}"
      ;;
    --quiet)
      QUIET=1
      ;;
    -h | --help)
      printf '%s\n' \
        "usage: setup/headless-doctor.sh [--profile local|headless-macos|headless-linux] [--quiet]" \
        "" \
        "Read-only postflight validator for the headless worker contract." \
        "Exit 0 when all REQUIRED checks pass; exit 1 otherwise." \
        "Optional checks print WARN and never affect exit status."
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

OS_UNAME="$(uname -s 2>/dev/null || echo unknown)"

if [ -z "$PROFILE" ]; then
  case "$OS_UNAME" in
    Darwin) PROFILE="headless-macos" ;;
    Linux) PROFILE="headless-linux" ;;
    *)
      printf 'FAIL  profile-detect              could not auto-detect a profile for uname=%s -- remediation: pass --profile explicitly\n' "$OS_UNAME"
      exit 1
      ;;
  esac
fi

case "$PROFILE" in
  local | headless-macos | headless-linux) ;;
  *)
    printf 'unknown profile: %s (expected local, headless-macos, or headless-linux)\n' "$PROFILE" >&2
    exit 2
    ;;
esac

# PLATFORM_FAMILY selects which OS-flavored checks run (launchd vs systemd,
# brew vs a Linux package manager). Explicit headless-* profiles pin the
# family; "local" falls back to the real host OS.
case "$PROFILE" in
  headless-macos) PLATFORM_FAMILY="macos" ;;
  headless-linux) PLATFORM_FAMILY="linux" ;;
  local)
    case "$OS_UNAME" in
      Darwin) PLATFORM_FAMILY="macos" ;;
      Linux) PLATFORM_FAMILY="linux" ;;
      *) PLATFORM_FAMILY="unknown" ;;
    esac
    ;;
esac

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_SOURCE="${BASH_SOURCE:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd -P)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

TARGET_USER="${USER:-$(id -un 2>/dev/null)}"
TARGET_HOME="${HOME:-}"

if [ "$PROFILE" = "local" ]; then
  SETUP_REMEDIATION="run make install"
else
  SETUP_REMEDIATION="run make setup-headless"
fi

# This doctor is invoked directly by `make` (a plain bash process inheriting
# the caller's bare PATH), which never sources zsh/.zshenv. fnm-managed
# tools (node/npm/pi/codex/ob) and ~/.local/bin-installed tools (claude) are
# genuinely on disk after a successful install, but this process's PATH has
# no way to see them unless it activates fnm and adds ~/.local/bin itself —
# exactly what setup/lib.sh's activate_fnm does for setup/linux-headless.sh
# after setup/node.sh runs as a separate child process (see lib.sh's
# activate_fnm doc comment). Doing the same here keeps section 2 below an
# honest check of "is this actually installed", not an artifact of make's
# minimal PATH. This is still read-only: it only mutates this process's own
# PATH/env, never touches disk. If fnm/the tools genuinely aren't installed,
# activate_fnm silently no-ops and the checks below still fail honestly.
if [ -n "$TARGET_HOME" ]; then
  case ":$PATH:" in
    *":$TARGET_HOME/.local/bin:"*) ;;
    *) PATH="$TARGET_HOME/.local/bin:$PATH" ;;
  esac
  export PATH

  if [ -f "$DOTFILES_DIR/setup/lib.sh" ]; then
    # shellcheck source=setup/lib.sh
    . "$DOTFILES_DIR/setup/lib.sh"
    activate_fnm >/dev/null 2>&1 || true
  fi
fi

# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------

REQUIRED_PASS=0
REQUIRED_FAIL=0
OPTIONAL_PASS=0
OPTIONAL_WARN=0
EXIT_CODE=0

# c_pass <id> <message>
c_pass() {
  REQUIRED_PASS=$((REQUIRED_PASS + 1))
  if [ "$QUIET" -eq 0 ]; then
    printf 'PASS  %-28s %s\n' "$1" "$2"
  fi
}

# c_fail <id> <message> <remediation>
c_fail() {
  REQUIRED_FAIL=$((REQUIRED_FAIL + 1))
  EXIT_CODE=1
  printf 'FAIL  %-28s %s -- remediation: %s\n' "$1" "$2" "$3"
}

# c_optpass <id> <message>   (optional check that passed)
c_optpass() {
  OPTIONAL_PASS=$((OPTIONAL_PASS + 1))
  if [ "$QUIET" -eq 0 ]; then
    printf 'PASS  %-28s %s [optional]\n' "$1" "$2"
  fi
}

# c_warn <id> <message> [remediation]   (optional check that did not pass)
c_warn() {
  OPTIONAL_WARN=$((OPTIONAL_WARN + 1))
  if [ -n "${3:-}" ]; then
    printf 'WARN  %-28s %s -- remediation: %s [optional]\n' "$1" "$2" "$3"
  else
    printf 'WARN  %-28s %s [optional]\n' "$1" "$2"
  fi
}

# c_info <id> <message>   (not counted toward pass/fail totals)
c_info() {
  if [ "$QUIET" -eq 0 ]; then
    printf 'INFO  %-28s %s\n' "$1" "$2"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# resolve_link <path> -> prints best-effort absolute, symlink-resolved path
resolve_link() {
  path="$1"
  if has_cmd realpath; then
    realpath "$path" 2>/dev/null && return 0
  fi
  if [ -L "$path" ]; then
    target="$(readlink "$path" 2>/dev/null)"
    case "$target" in
      /*) : ;;
      *) target="$(dirname "$path")/$target" ;;
    esac
    path="$target"
  fi
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if resolved_dir="$(cd "$dir" >/dev/null 2>&1 && pwd -P)"; then
    printf '%s/%s\n' "$resolved_dir" "$base"
    return 0
  fi
  return 1
}

# under_dotfiles <path> -> 0 if the resolved path lives under DOTFILES_DIR
under_dotfiles() {
  resolved="$(resolve_link "$1" 2>/dev/null)" || return 1
  case "$resolved" in
    "$DOTFILES_DIR"/*) return 0 ;;
    "$DOTFILES_DIR") return 0 ;;
    *) return 1 ;;
  esac
}

# get_perms <path> -> octal perms, portable across BSD/GNU stat
#
# Try GNU's -c form FIRST, not BSD's -f form: GNU stat treats -f as "report
# on the containing filesystem" (a different, always-succeeding mode) rather
# than rejecting it, so `stat -f "%Lp" path` on Linux exits 0 but prints
# garbled filesystem info instead of falling through to the -c branch. BSD
# stat has no -c flag at all and reliably exits nonzero for it, so trying -c
# first and falling back to -f is safe in both directions.
get_perms() {
  stat -c "%a" "$1" 2>/dev/null || stat -f "%Lp" "$1" 2>/dev/null
}

if [ "$QUIET" -eq 0 ]; then
  printf 'headless-doctor: profile=%s platform=%s dotfiles=%s\n' "$PROFILE" "$PLATFORM_FAMILY" "$DOTFILES_DIR"
  printf '%s\n' "----------------------------------------------------------------------"
fi

# ===========================================================================
# 1. Environment: OS, package manager, init system, user, home, shell
# ===========================================================================

c_info "os" "uname=$OS_UNAME"

case "$PLATFORM_FAMILY" in
  macos)
    if has_cmd brew; then
      c_pass "package-manager" "brew found at $(command -v brew)"
    else
      c_fail "package-manager" "Homebrew (brew) not found" "install Homebrew: https://brew.sh"
    fi
    ;;
  linux)
    PKG_MGR=""
    for candidate in apt-get dnf pacman zypper apk; do
      if has_cmd "$candidate"; then
        PKG_MGR="$candidate"
        break
      fi
    done
    if [ -n "$PKG_MGR" ]; then
      c_pass "package-manager" "$PKG_MGR found"
    else
      c_fail "package-manager" "no supported package manager found (apt/dnf/pacman/zypper/apk)" "install a supported Linux distribution or package manager"
    fi
    ;;
  *)
    c_warn "package-manager" "unrecognized platform family; cannot detect a package manager"
    ;;
esac

case "$PLATFORM_FAMILY" in
  macos)
    if has_cmd launchctl; then
      c_pass "init-system" "launchd available (launchctl found)"
    else
      c_fail "init-system" "launchctl not found on macOS" "unexpected: confirm this is a real macOS environment"
    fi
    ;;
  linux)
    if has_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1; then
      c_pass "init-system" "systemd --user instance reachable"
    else
      if [ "$PROFILE" = "headless-linux" ]; then
        c_fail "init-system" "systemctl --user show-environment could not connect" "enable a systemd user instance (loginctl enable-linger \$USER, and ensure a user manager is running)"
      else
        c_warn "init-system" "systemctl --user show-environment could not connect (not required for profile=$PROFILE)"
      fi
    fi
    ;;
esac

c_info "target-user" "USER=${TARGET_USER:-<unset>}"

if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] && [ -w "$TARGET_HOME" ]; then
  c_pass "home-dir" "\$HOME=$TARGET_HOME exists and is writable"
else
  c_fail "home-dir" "\$HOME (${TARGET_HOME:-<unset>}) missing or not writable" "verify \$HOME is set and points at a writable directory for $TARGET_USER"
fi

LOGIN_SHELL=""
case "$OS_UNAME" in
  Darwin)
    LOGIN_SHELL="$(dscl . -read "/Users/$TARGET_USER" UserShell 2>/dev/null | awk '{print $2}')"
    ;;
  Linux)
    LOGIN_SHELL="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f7)"
    ;;
esac
[ -n "$LOGIN_SHELL" ] || LOGIN_SHELL="${SHELL:-}"

case "$LOGIN_SHELL" in
  */zsh)
    c_pass "login-shell" "login shell is $LOGIN_SHELL"
    ;;
  *)
    if [ "$PROFILE" = "local" ]; then
      c_info "login-shell" "login shell is ${LOGIN_SHELL:-<unknown>} (not enforced for profile=local)"
    else
      c_fail "login-shell" "login shell is ${LOGIN_SHELL:-<unknown>}, expected zsh" "chsh -s \$(command -v zsh)"
    fi
    ;;
esac

# ===========================================================================
# 2. Required commands in the current environment
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- required commands (current environment) --"
fi

REQUIRED_CMDS="bash zsh ssh git git-lfs stow tmux jq rsync tar curl node npm pi codex claude nvim ob gh delta"
for cmd in $REQUIRED_CMDS; do
  if has_cmd "$cmd"; then
    c_pass "cmd:$cmd" "$(command -v "$cmd")"
  else
    if [ "$cmd" = "gh" ]; then
      # gh (GitHub CLI): Brewfile.headless already installs it on macOS, and
      # setup/linux-headless.sh now installs it on Linux too (apt/dnf/pacman
      # required, zypper/apk optional). A worker provisioned before that fix
      # will FAIL this check until re-provisioned -- that is intentional,
      # not a false positive; it is exactly the parity gap this check exists
      # to catch. See docs/headless-vs-local.md, "Known parity gaps".
      c_fail "cmd:$cmd" "not found on PATH" "$SETUP_REMEDIATION (installs gh on Linux/macOS; on unsupported distros install gh manually: https://cli.github.com)"
    elif [ "$cmd" = "delta" ]; then
      # delta (git-delta): git/.gitconfig unconditionally sets `pager =
      # delta` and a [delta] diffFilter, so a missing delta breaks ordinary
      # `git log`/`git diff`, not just a cosmetic gap -- REQUIRED, not
      # optional, same severity class as gh above. Brewfile.headless already
      # installs "git-delta" on macOS; setup/linux-headless.sh installs it
      # as a required package on apt/dnf/pacman/zypper (apk stays optional).
      # A worker provisioned before this fix will FAIL this check until
      # re-provisioned -- intentional, see docs/headless-vs-local.md, "Known
      # parity gaps".
      c_fail "cmd:$cmd" "not found on PATH" "$SETUP_REMEDIATION (installs git-delta on Linux/macOS; on unsupported distros install delta manually: https://github.com/dandavison/delta)"
    else
      c_fail "cmd:$cmd" "not found on PATH" "$SETUP_REMEDIATION"
    fi
  fi
done

if has_cmd uuidgen || [ -e /proc/sys/kernel/random/uuid ]; then
  c_pass "cmd:uuid-source" "uuidgen or /proc/sys/kernel/random/uuid available"
else
  c_fail "cmd:uuid-source" "no UUID source found (no uuidgen, no /proc/sys/kernel/random/uuid)" "install uuid-runtime/util-linux, or use a kernel providing /proc/sys/kernel/random/uuid"
fi

if has_cmd tailscale; then
  if [ "$PROFILE" = "local" ]; then
    c_optpass "cmd:tailscale" "$(command -v tailscale)"
  else
    c_pass "cmd:tailscale" "$(command -v tailscale)"
  fi
else
  if [ "$PROFILE" = "local" ]; then
    c_warn "cmd:tailscale" "tailscale not found" "install Tailscale if this machine needs the shared network"
  else
    c_fail "cmd:tailscale" "tailscale not found" "$SETUP_REMEDIATION (Tailscale is installed by default on headless workers)"
  fi
fi

if has_cmd stripe; then
  c_optpass "cmd:stripe" "$(command -v stripe)"
else
  c_warn "cmd:stripe" "stripe CLI not found"
fi

# ===========================================================================
# 3. Required commands under a minimal noninteractive environment
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- required commands (minimal noninteractive shell, simulates sshd) --"
fi

ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
NONINTERACTIVE_CMDS="tmux git git-lfs jq node npm pi codex claude rsync"

if [ -z "$ZSH_BIN" ]; then
  c_fail "noninteractive:zsh" "zsh not found; cannot simulate the sshd noninteractive shell" "$SETUP_REMEDIATION"
else
  for cmd in $NONINTERACTIVE_CMDS; do
    if env -i HOME="$TARGET_HOME" USER="$TARGET_USER" TERM=dumb "$ZSH_BIN" -c "command -v $cmd" >/dev/null 2>&1; then
      c_pass "noninteractive:$cmd" "resolves under env -i zsh -c"
    else
      c_fail "noninteractive:$cmd" "does not resolve under a minimal noninteractive zsh" "fix zsh/.zshenv noninteractive PATH"
    fi
  done
fi

# ===========================================================================
# 4. Dotfile links
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- dotfile links --"
fi

check_config_link() {
  # check_config_link <id> <path>
  id="$1"
  path="$2"
  if [ -L "$path" ] && under_dotfiles "$path"; then
    c_pass "$id" "$path -> $(readlink "$path")"
  elif [ -L "$path" ]; then
    c_fail "$id" "$path is a symlink but does not resolve into $DOTFILES_DIR" "$SETUP_REMEDIATION"
  else
    c_fail "$id" "$path is not a symlink into the dotfiles repo" "$SETUP_REMEDIATION"
  fi
}

check_config_link "link:tmux" "$TARGET_HOME/.config/tmux"
check_config_link "link:nvim" "$TARGET_HOME/.config/nvim"

# check_stow_target <id> <path...> - all paths must be symlinks into the repo
check_stow_target() {
  id="$1"
  shift
  ok=1
  detail=""
  for path in "$@"; do
    if [ -L "$path" ] && under_dotfiles "$path"; then
      detail="$detail $path=ok"
    else
      ok=0
      detail="$detail $path=missing"
    fi
  done
  if [ "$ok" -eq 1 ]; then
    c_pass "$id" "stowed:$detail"
  else
    c_fail "$id" "not fully stowed:$detail" "$SETUP_REMEDIATION"
  fi
}

check_stow_target "stow:claude" "$TARGET_HOME/.claude/CLAUDE.md"
check_stow_target "stow:codex" "$TARGET_HOME/.codex/AGENTS.md"
check_stow_target "stow:git" "$TARGET_HOME/.gitconfig"
check_stow_target "stow:pi" "$TARGET_HOME/.pi/agent/AGENTS.md"
check_stow_target "stow:ssh" "$TARGET_HOME/.ssh/config"
check_stow_target "stow:vim" "$TARGET_HOME/.vimrc"
check_stow_target "stow:zsh" "$TARGET_HOME/.zshrc" "$TARGET_HOME/.zshenv"
check_stow_target "stow:worktrees" "$TARGET_HOME/.local/bin/worktree-slot"

# ===========================================================================
# 5. Executables: rw, worktree-slot, worktree-claim
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- rw / worktree executables --"
fi

check_executable() {
  # check_executable <id> <path>
  id="$1"
  path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -x "$path" ]; then
      c_pass "$id" "$path exists and is executable"
    else
      c_fail "$id" "$path exists but is not executable" "chmod +x $path, or $SETUP_REMEDIATION"
    fi
  else
    c_fail "$id" "$path does not exist" "$SETUP_REMEDIATION"
  fi
}

check_executable "exe:rw" "$TARGET_HOME/.local/bin/rw"
check_executable "exe:worktree-slot" "$TARGET_HOME/.local/bin/worktree-slot"
check_executable "exe:worktree-claim" "$TARGET_HOME/.local/bin/worktree-claim"

if [ -n "$ZSH_BIN" ]; then
  if env -i HOME="$TARGET_HOME" USER="$TARGET_USER" TERM=dumb "$ZSH_BIN" -c "command -v rw" >/dev/null 2>&1; then
    c_pass "exe:rw-noninteractive" "rw resolves under a minimal noninteractive zsh"
  else
    c_fail "exe:rw-noninteractive" "rw does not resolve under a minimal noninteractive zsh" "fix zsh/.zshenv noninteractive PATH, or $SETUP_REMEDIATION"
  fi

  # Harmless usage probe. rw's own help path (-h|--help|help) prints usage
  # text; guard against a nonzero exit from an unrecognized flag being
  # mistaken for a real failure by matching on output, not exit status.
  rw_help_output="$(env -i HOME="$TARGET_HOME" USER="$TARGET_USER" TERM=dumb "$ZSH_BIN" -c 'command -v rw >/dev/null 2>&1 && rw --help' 2>&1 || true)"
  case "$rw_help_output" in
    *usage*|*Usage*|*USAGE*)
      c_optpass "exe:rw-help" "rw --help emitted usage output"
      ;;
    *)
      c_warn "exe:rw-help" "rw --help did not emit recognizable usage output (or rw is unavailable)"
      ;;
  esac
else
  c_fail "exe:rw-noninteractive" "zsh not found; cannot probe rw under a minimal noninteractive shell" "$SETUP_REMEDIATION"
fi

# ===========================================================================
# 6. Tmux plugins
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- tmux plugins --"
fi

TMUX_CFG_DIR="$TARGET_HOME/.config/tmux"

if [ -f "$TMUX_CFG_DIR/plugins/tpm/tpm" ] && [ -x "$TMUX_CFG_DIR/plugins/tpm/tpm" ]; then
  c_pass "tmux:tpm" "$TMUX_CFG_DIR/plugins/tpm/tpm present and executable"
else
  c_fail "tmux:tpm" "$TMUX_CFG_DIR/plugins/tpm/tpm missing or not executable" "$SETUP_REMEDIATION"
fi

RESURRECT_SAVE="$TMUX_CFG_DIR/plugins/tmux-resurrect/scripts/save.sh"
if [ -f "$RESURRECT_SAVE" ] && [ -x "$RESURRECT_SAVE" ]; then
  c_pass "tmux:resurrect-save" "$RESURRECT_SAVE present and executable"
else
  c_fail "tmux:resurrect-save" "$RESURRECT_SAVE missing or not executable" "$SETUP_REMEDIATION"
fi

# tmux >= 3.7 sanitizes the literal-tab field delimiter tmux-resurrect's
# save.sh sends through `-F`/`display-message -p` format strings, silently
# corrupting every save with no upstream fix (see
# setup/patches/tmux-resurrect-tmux37-delimiter.patch). install_tmux_plugins
# (setup/lib.sh) always applies that patch regardless of the installed tmux
# version, so its marker should always be present here -- this is a
# required check, not a version-gated one, because an unpatched
# tmux-resurrect on tmux >= 3.7 is a silently broken safety net.
if [ -f "$RESURRECT_SAVE" ] && grep -q "resurrect_detokenize" "$RESURRECT_SAVE" 2>/dev/null; then
  c_pass "tmux:resurrect-tmux37-patch" "$RESURRECT_SAVE has the tmux37 delimiter patch applied"
else
  c_fail "tmux:resurrect-tmux37-patch" "$RESURRECT_SAVE missing the tmux37 delimiter patch (resurrect_detokenize marker not found)" "$SETUP_REMEDIATION"
fi

# save_all()'s only gate for repointing `last` -- the file restore.sh
# actually reads -- was "did the new save differ from the previous one",
# which a 0-byte or truncated save trivially satisfies, silently making a
# failed save the authoritative restore source (see
# setup/patches/tmux-resurrect-save-validity-gate.patch). install_tmux_plugins
# always applies this patch too, so its marker should always be present
# here -- also a required check, not version-gated, since an unguarded
# `last` symlink is a silently broken safety net on any tmux version.
if [ -f "$RESURRECT_SAVE" ] && grep -q "resurrect_file_looks_sane" "$RESURRECT_SAVE" 2>/dev/null; then
  c_pass "tmux:resurrect-save-validity-patch" "$RESURRECT_SAVE has the save-validity gate patch applied"
else
  c_fail "tmux:resurrect-save-validity-patch" "$RESURRECT_SAVE missing the save-validity gate patch (resurrect_file_looks_sane marker not found)" "$SETUP_REMEDIATION"
fi

# glob_has <pattern> -> 0 if at least one file matches
glob_has() {
  for f in $1; do
    if [ -e "$f" ]; then
      return 0
    fi
    break
  done
  return 1
}

if glob_has "$TMUX_CFG_DIR/local-plugins/tmux-workspace-resurrect/"*.tmux; then
  c_pass "tmux:workspace-resurrect-entrypoint" "$TMUX_CFG_DIR/local-plugins/tmux-workspace-resurrect/*.tmux readable"
else
  c_fail "tmux:workspace-resurrect-entrypoint" "no *.tmux file found under $TMUX_CFG_DIR/local-plugins/tmux-workspace-resurrect/" "$SETUP_REMEDIATION"
fi

if glob_has "$TMUX_CFG_DIR/local-plugins/tmux-remote-workspaces/"*.tmux; then
  c_pass "tmux:remote-workspaces-entrypoint" "$TMUX_CFG_DIR/local-plugins/tmux-remote-workspaces/*.tmux readable"
else
  c_fail "tmux:remote-workspaces-entrypoint" "no *.tmux file found under $TMUX_CFG_DIR/local-plugins/tmux-remote-workspaces/" "$SETUP_REMEDIATION"
fi

# ===========================================================================
# 7. Durability timer (headless profiles only; local relies on the laptop's
#    rendering client + Continuum instead - a deliberate platform alternative)
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- durability timer --"
fi

if [ "$PROFILE" = "local" ]; then
  c_info "timer" "skipped for profile=local (laptop rendering client + Continuum covers this instead)"
elif [ "$PROFILE" = "headless-macos" ]; then
  PLIST_PATH="$TARGET_HOME/Library/LaunchAgents/com.kalem.tmux-resurrect-save.plist"

  if launchctl print "gui/$(id -u)/com.kalem.tmux-resurrect-save" >/dev/null 2>&1; then
    c_pass "timer:launchd-loaded" "launchctl print gui/\$UID/com.kalem.tmux-resurrect-save succeeded"
  else
    c_fail "timer:launchd-loaded" "launchctl print gui/\$UID/com.kalem.tmux-resurrect-save failed" "$SETUP_REMEDIATION"
  fi

  if [ -f "$PLIST_PATH" ]; then
    c_pass "timer:plist-exists" "$PLIST_PATH exists"

    tmux_bin_value="$(sed -n '/<key>TMUX_RESURRECT_SAVE_TMUX_BIN<\/key>/{n;s#.*<string>\(.*\)</string>.*#\1#p;}' "$PLIST_PATH" 2>/dev/null)"
    if [ -n "$tmux_bin_value" ]; then
      if [ -x "$tmux_bin_value" ]; then
        c_pass "timer:plist-tmux-bin" "TMUX_RESURRECT_SAVE_TMUX_BIN=$tmux_bin_value is executable"
      else
        c_fail "timer:plist-tmux-bin" "TMUX_RESURRECT_SAVE_TMUX_BIN=$tmux_bin_value is not executable" "re-run setup: launchd job lacks absolute tmux path"
      fi
    else
      c_fail "timer:plist-tmux-bin" "plist does not declare TMUX_RESURRECT_SAVE_TMUX_BIN" "re-run setup: launchd job lacks absolute tmux path"
    fi

    wrapper_path="$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/{s#.*<string>\(.*\)</string>.*#\1#p;}' "$PLIST_PATH" 2>/dev/null | head -1)"
    if [ -n "$wrapper_path" ] && [ -f "$wrapper_path" ]; then
      if grep -q -- '--check' "$wrapper_path" 2>/dev/null; then
        # Pass the plist's rendered tmux path exactly as launchd would —
        # without it the wrapper's --check fails on Homebrew-only tmux and
        # this check reports a false negative for a correctly installed job.
        if env -i HOME="$TARGET_HOME" PATH=/usr/bin:/bin \
          TMUX_RESURRECT_SAVE_TMUX_BIN="$tmux_bin_value" \
          "$wrapper_path" --check >/dev/null 2>&1; then
          c_pass "timer:wrapper-check" "$wrapper_path --check succeeded"
        else
          c_fail "timer:wrapper-check" "$wrapper_path --check failed" "$SETUP_REMEDIATION"
        fi
      else
        c_warn "timer:wrapper-check" "$wrapper_path has no --check flag support; skipping direct invocation test"
      fi
    else
      c_warn "timer:wrapper-check" "could not determine the save wrapper path from the plist; skipping direct invocation test"
    fi
  else
    c_fail "timer:plist-exists" "$PLIST_PATH does not exist" "$SETUP_REMEDIATION"
  fi
elif [ "$PROFILE" = "headless-linux" ]; then
  if has_cmd systemctl; then
    if enabled_state="$(systemctl --user is-enabled tmux-resurrect-save.timer 2>/dev/null)" && [ "$enabled_state" = "enabled" ]; then
      c_pass "timer:systemd-enabled" "tmux-resurrect-save.timer is enabled"
    else
      c_fail "timer:systemd-enabled" "tmux-resurrect-save.timer is not enabled (state=${enabled_state:-unknown})" "$SETUP_REMEDIATION"
    fi

    if systemctl --user is-active --quiet tmux-resurrect-save.timer 2>/dev/null; then
      c_pass "timer:systemd-active" "tmux-resurrect-save.timer is active"
    else
      c_fail "timer:systemd-active" "tmux-resurrect-save.timer is not active" "$SETUP_REMEDIATION"
    fi
  else
    c_fail "timer:systemd-enabled" "systemctl not found" "$SETUP_REMEDIATION"
    c_fail "timer:systemd-active" "systemctl not found" "$SETUP_REMEDIATION"
  fi

  if has_cmd loginctl; then
    linger_value="$(loginctl show-user "$TARGET_USER" -p Linger 2>/dev/null)"
    case "$linger_value" in
      Linger=yes)
        c_pass "timer:linger" "loginctl show-user reports Linger=yes"
        ;;
      *)
        c_fail "timer:linger" "loginctl show-user reports ${linger_value:-<unknown>}, expected Linger=yes" "loginctl enable-linger $TARGET_USER"
        ;;
    esac
  else
    c_fail "timer:linger" "loginctl not found" "$SETUP_REMEDIATION"
  fi
fi

# ===========================================================================
# 8. SSH
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- ssh --"
fi

SSH_DIR="$TARGET_HOME/.ssh"

if [ -d "$SSH_DIR" ]; then
  perms="$(get_perms "$SSH_DIR")"
  if [ "$perms" = "700" ]; then
    c_pass "ssh:dir-perms" "$SSH_DIR is 700"
  else
    c_fail "ssh:dir-perms" "$SSH_DIR perms are ${perms:-unknown}, expected 700" "chmod 700 $SSH_DIR"
  fi
else
  c_fail "ssh:dir-perms" "$SSH_DIR does not exist" "$SETUP_REMEDIATION"
fi

if [ "$PROFILE" = "local" ]; then
  c_info "ssh:key" "key existence/permissions not enforced for profile=local (partial SSH checks)"
else
  SSH_KEY=""
  for candidate in "$SSH_DIR/id_ed25519" "$SSH_DIR/id_rsa"; do
    if [ -f "$candidate" ]; then
      SSH_KEY="$candidate"
      break
    fi
  done

  if [ -n "$SSH_KEY" ]; then
    c_pass "ssh:key" "found $SSH_KEY"
    key_perms="$(get_perms "$SSH_KEY")"
    if [ "$key_perms" = "600" ]; then
      c_pass "ssh:key-perms" "$SSH_KEY is 600"
    else
      c_fail "ssh:key-perms" "$SSH_KEY perms are ${key_perms:-unknown}, expected 600" "chmod 600 $SSH_KEY"
    fi
  else
    c_fail "ssh:key" "no SSH key found (~/.ssh/id_ed25519 or ~/.ssh/id_rsa)" "manual: ssh-keygen -t ed25519 -f $SSH_DIR/id_ed25519"
  fi
fi

if [ -d "$SSH_DIR/sockets" ]; then
  c_pass "ssh:sockets-dir" "$SSH_DIR/sockets exists"
else
  c_fail "ssh:sockets-dir" "$SSH_DIR/sockets does not exist" "start a zsh shell once (zsh/.zshenv creates it), or mkdir -p -m 700 $SSH_DIR/sockets"
fi

c_info "ssh:manual-git-host" "Git-host key registration (GitHub/GitLab) is a MANUAL verification this doctor does not attempt"
c_info "ssh:manual-provider-auth" "claude/codex/pi provider authentication is a MANUAL verification this doctor does not attempt"
c_info "ssh:manual-tailscale-up" "\`tailscale up\` authentication is a MANUAL verification this doctor does not attempt"

# ===========================================================================
# 9. Locale
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- locale --"
fi

EFFECTIVE_LOCALE="${LC_ALL:-${LANG:-}}"
c_info "locale:effective" "LANG=${LANG:-<unset>} LC_ALL=${LC_ALL:-<unset>}"

if [ -z "$EFFECTIVE_LOCALE" ]; then
  c_warn "locale:available" "no LANG/LC_ALL configured in this environment"
elif has_cmd locale; then
  normalized_target="$(printf '%s' "$EFFECTIVE_LOCALE" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  found=0
  # shellcheck disable=SC2046 # word-splitting over `locale -a` output is intended
  for available in $(locale -a 2>/dev/null); do
    normalized_available="$(printf '%s' "$available" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
    if [ "$normalized_available" = "$normalized_target" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 1 ]; then
    c_pass "locale:available" "$EFFECTIVE_LOCALE is available per locale -a"
  else
    c_warn "locale:available" "$EFFECTIVE_LOCALE not found in locale -a" "install/generate the locale, or switch to an available UTF-8 locale such as C.UTF-8"
  fi
else
  c_warn "locale:available" "locale command not found; cannot verify $EFFECTIVE_LOCALE is generated"
fi

# ===========================================================================
# 10. git lfs
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- git lfs --"
fi

if has_cmd git && git lfs env >/dev/null 2>&1; then
  c_pass "git:lfs-env" "git lfs env succeeded"
else
  c_fail "git:lfs-env" "git lfs env failed (git-lfs missing or not initialized)" "install git-lfs then run: git lfs install --skip-repo"
fi

# ===========================================================================
# 11. Provider settings write-back drift (informational / non-fatal)
# ===========================================================================
#
# claude and pi stow their settings files straight into $HOME, so each
# CLI's own runtime writes (theme changes, defaultModel updates, etc.) go
# THROUGH the symlink and land back in this tracked repo as uncommitted
# changes. That is expected CLI behavior, not a broken install, so this
# check is a WARN via c_warn (optional_warned), never a c_fail — a worker
# where someone simply launched claude must not go doctor-red over it. It
# asks git about the repo's own tracked files rather than diffing symlink
# targets by hand, and degrades to a WARN (not a crash) when git is
# unavailable or $DOTFILES_DIR is not a git repository.

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "-- provider settings write-back drift --"
fi

PROVIDER_SETTINGS_PATHS="claude/.claude/settings.json pi/.pi/agent/settings.json"
PROVIDER_SETTINGS_REMEDIATION="git -C $DOTFILES_DIR checkout -- $PROVIDER_SETTINGS_PATHS"

if ! has_cmd git; then
  c_warn "drift:provider-settings" "git not found; cannot check provider settings write-back drift"
elif ! git -C "$DOTFILES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  c_warn "drift:provider-settings" "$DOTFILES_DIR is not a git repository; cannot check provider settings write-back drift"
else
  # shellcheck disable=SC2086 # PROVIDER_SETTINGS_PATHS is an intentional word-split pathspec list
  DRIFT_STATUS="$(git -C "$DOTFILES_DIR" status --porcelain -- $PROVIDER_SETTINGS_PATHS 2>/dev/null)"
  if [ -z "$DRIFT_STATUS" ]; then
    c_optpass "drift:provider-settings" "no drift in tracked provider settings ($PROVIDER_SETTINGS_PATHS)"
  else
    DRIFT_FILES="$(printf '%s\n' "$DRIFT_STATUS" | awk '{print $2}' | tr '\n' ' ')"
    c_warn "drift:provider-settings" "provider CLI runtime writes modified tracked settings: $DRIFT_FILES" "$PROVIDER_SETTINGS_REMEDIATION"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================

if [ "$QUIET" -eq 0 ]; then
  printf '%s\n' "----------------------------------------------------------------------"
fi

if [ "$EXIT_CODE" -eq 0 ]; then
  RESULT="PASS"
else
  RESULT="FAIL"
fi

printf 'SUMMARY profile=%s required=%d/%d optional_passed=%d optional_warned=%d result=%s\n' \
  "$PROFILE" "$REQUIRED_PASS" "$((REQUIRED_PASS + REQUIRED_FAIL))" "$OPTIONAL_PASS" "$OPTIONAL_WARN" "$RESULT"

exit "$EXIT_CODE"
