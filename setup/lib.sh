#!/usr/bin/env bash
#
# setup/lib.sh — shared install layer for the Makefile-driven install targets
# (`install`, `install-headless`) and, from a later wave, for
# setup/linux-headless.sh. This file is SOURCED, never executed directly.
#
# Bash 3.2 compatible (macOS stock bash: no associative arrays, no ${var,,},
# no mapfile/readarray, no `local -n`). Kept dependency-free — no sourcing of
# other setup/*.sh files — so it is safe to source early from any script or
# from an inline Makefile recipe.
#
# Contract: the caller MUST set DOTFILES_DIR (absolute path to this repo)
# before sourcing this file. All functions below act relative to that
# variable and to $HOME; none of them infer the repo location themselves.
#
# Public functions (see docs/headless-vs-local.md for the shared local vs.
# headless setup contract design rationale):
#
#   activate_fnm
#     Idempotently put fnm on PATH (Homebrew locations on macOS,
#     ~/.local/share/fnm on Linux) and `eval "$(fnm env)"` if fnm is
#     available. Silent on success. Returns nonzero (no output) if fnm
#     cannot be found at all. Safe to call repeatedly/redundantly.
#
#   link_config_package <package>
#     Idempotent symlink of "$DOTFILES_DIR/<package>" to
#     "$HOME/.config/<package>". No-ops if the package directory doesn't
#     exist in this repo. Replaces a stale (non-repo) symlink; warns and
#     skips a real pre-existing file/directory rather than clobbering it.
#
#   backup_conflicts <package> [<package> ...]
#     For every file stow would place under $HOME for each named package,
#     move a real (non-repo-symlink) conflict aside before stowing.
#     FIRST-.bak protection: if "$target.bak" already exists from a prior
#     run, it is preserved untouched and the new conflict is moved to a
#     timestamp-suffixed "$target.bak.<epoch>" instead of overwriting it.
#     Relative symlinks that resolve into $DOTFILES_DIR are left alone;
#     absolute symlinks (which stow refuses to adopt) and symlinks pointing
#     elsewhere are removed, so stow can recreate them relative.
#
#   stow_packages <package> [<package> ...]
#     Runs `stow --no-folding --restow -d "$DOTFILES_DIR" -t "$HOME"` for
#     each named package that exists in this repo. Fails (nonzero return)
#     on the first stow error — never swallowed.
#
#   install_tmux_plugins
#     Clones/updates TPM, then pins tmux-sessionx to commit
#     $TMUX_SESSIONX_PIN and tmux-resurrect to commit $TMUX_RESURRECT_PIN
#     (single authority for each pin) BEFORE running TPM's install_plugins
#     — TPM's own clone helper runs `git clone -b <ref> --single-branch`,
#     and -b never accepts a raw commit SHA, so on a fresh install TPM's
#     attempt to clone either plugin always fails and install_plugins exits
#     nonzero before ever reaching a fallback placed after it. Pre-cloning/
#     checking out each pin first makes TPM's plugin_already_installed
#     check short-circuit its own broken clone attempt for those two
#     plugins, while every other plugin still goes through TPM normally and
#     install_plugins FAILS (nonzero return) — same as before — if it exits
#     nonzero for any genuine reason. Immediately after pinning
#     tmux-resurrect, idempotently applies
#     setup/patches/tmux-resurrect-tmux37-delimiter.patch (tmux >= 3.7
#     sanitizes the literal-tab field delimiter resurrect's save.sh sends
#     through `-F`/`display-message -p` format strings, silently corrupting
#     every save with no upstream fix) — detected via
#     $TMUX_RESURRECT_PATCH_MARKER already being present in save.sh, so a
#     rerun neither fails nor double-applies; any genuine apply failure is
#     FATAL, since a worker with unpatched tmux-resurrect on tmux >= 3.7 has
#     a silently broken save/restore safety net. Afterwards asserts
#     ~/.config/tmux/plugins/tmux-resurrect/scripts/save.sh exists and is
#     executable, and that the repo-owned local-plugins entrypoints
#     ($DOTFILES_DIR/tmux/local-plugins/*/*.tmux) are readable. Requires
#     $HOME/.config/tmux to already be linked into the repo (call
#     link_config_package tmux first).
#
#   link_rw
#     Idempotent `ln -sf` of this repo's rw entrypoint
#     (tmux/local-plugins/tmux-remote-workspaces/scripts/rw) into
#     ~/.local/bin/rw.
#
#   seed_codex_config
#     Seed-if-missing: copies setup/templates/codex-config.toml to
#     ~/.codex/config.toml ONLY if that file does not already exist. Never
#     overwrites an existing config.toml. codex/.codex/ (the stowed package)
#     deliberately ships no config.toml of its own — codex writes
#     machine-specific state (project trust entries, model migration/
#     availability caches, marketplace timestamps) straight into that exact
#     file, so symlinking it would guarantee permanent working-tree dirt.
#     This is the only way codex gets its default theme/model/status-line
#     settings on a fresh machine instead of running its first-run wizard.
#
#   ensure_ssh_dirs
#     Creates ~/.ssh and ~/.ssh/sockets (mkdir -p, then chmod 700 each —
#     deliberately not `mkdir -m`, which only guarantees the mode on the
#     deepest created directory).

if [ -z "${DOTFILES_DIR:-}" ]; then
  echo "setup/lib.sh: DOTFILES_DIR must be set before sourcing this file." >&2
  # shellcheck disable=SC2317 # reachable when this file is executed directly instead of sourced
  return 1 2>/dev/null || exit 1
fi

# Single authority for the tmux-sessionx pin. TPM can install unpinned
# plugins on a fresh machine but cannot clone a specific commit, so this repo
# manages that one plugin's checkout manually. Keep in sync with the
# `@plugin 'omerxx/tmux-sessionx#...'` line in tmux/tmux.conf.
TMUX_SESSIONX_PIN="3a1911e"

# Single authority for the tmux-resurrect pin and its local patch. tmux >=
# 3.7 sanitizes C0 control characters — including the literal tab
# tmux-resurrect's save.sh uses as a field delimiter inside `-F`/
# `display-message -p` format strings — to "_" in command output, with no
# off-switch. That silently corrupts every resurrect save on tmux 3.7+
# (confirmed on the mini worker, tmux 3.7b: an 8-byte "state__" file and
# zero-byte pane/window dumps). Upstream has no fix, so this repo carries
# its own patch (setup/patches/tmux-resurrect-tmux37-delimiter.patch),
# generated against — and only guaranteed to apply cleanly against —
# $TMUX_RESURRECT_PIN. Keep the pin in sync with the
# `@plugin 'tmux-plugins/tmux-resurrect#...'` line in tmux/tmux.conf, and
# regenerate the patch if the pin ever moves.
TMUX_RESURRECT_PIN="cff343cf9e81983d3da0c8562b01616f12e8d548"
TMUX_RESURRECT_PATCH="$DOTFILES_DIR/setup/patches/tmux-resurrect-tmux37-delimiter.patch"
# String unique to the applied patch (the helper function it adds to
# save.sh). `git apply` is not idempotent — reapplying an already-applied
# patch fails — so this marker, not exit-code alone, is what makes patch
# application idempotent across reruns.
TMUX_RESURRECT_PATCH_MARKER="resurrect_detokenize"

activate_fnm() {
  if [ -d /opt/homebrew/bin ]; then
    case ":$PATH:" in
      *":/opt/homebrew/bin:"*) ;;
      *) PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH" ;;
    esac
  elif [ -d /usr/local/bin ]; then
    case ":$PATH:" in
      *":/usr/local/bin:"*) ;;
      *) PATH="/usr/local/bin:/usr/local/sbin:$PATH" ;;
    esac
  fi

  if [ -d "$HOME/.local/share/fnm" ]; then
    case ":$PATH:" in
      *":$HOME/.local/share/fnm:"*) ;;
      *) PATH="$HOME/.local/share/fnm:$PATH" ;;
    esac
  fi

  export PATH

  command -v fnm >/dev/null 2>&1 || return 1

  eval "$(fnm env --use-on-cd --shell bash)" 2>/dev/null
}

link_config_package() {
  package="$1"
  target="$HOME/.config/$package"

  [ -d "$DOTFILES_DIR/$package" ] || return 0

  mkdir -p "$HOME/.config"

  if [ -L "$target" ]; then
    case "$(readlink "$target")" in
      "$DOTFILES_DIR"*) echo "  -> $package already linked" ;;
      *)
        echo "  -> replacing stale $package symlink"
        rm "$target"
        ln -s "$DOTFILES_DIR/$package" "$target"
        ;;
    esac
  elif [ -e "$target" ]; then
    echo "  (warn) ~/.config/$package exists (skipping)"
  else
    echo "  -> linking $package -> $target"
    ln -s "$DOTFILES_DIR/$package" "$target"
  fi
}

backup_conflicts() {
  for package in "$@"; do
    [ -d "$DOTFILES_DIR/$package" ] || continue

    while IFS= read -r file; do
      [ -n "$file" ] || continue
      relpath="${file#"$DOTFILES_DIR/$package/"}"
      target="$HOME/$relpath"

      if [ -L "$target" ]; then
        link_text="$(readlink "$target")"
        case "$link_text" in
          /*)
            # Absolute symlink. stow only ever CREATES relative links and
            # refuses to adopt an absolute one -- it prints "Ignoring an
            # absolute symlink" and then fails the whole package with
            # "existing target is not owned by stow". Crucially it aborts
            # *after* this function has already moved every other conflict
            # aside, which leaves $HOME stripped of the very dotfiles the run
            # was meant to install. Observed 2026-08-02 on the laptop: two
            # absolute links (~/.claude/keybindings.json, .claude/commands/
            # plan.md) aborted `make install` and ~/.zshrc, ~/.gitconfig,
            # ~/.ssh/config and ~/.vimrc were all left missing.
            # Remove it regardless of where it points: if it targets this
            # repo, stow recreates it correctly as a relative link; if it
            # targets anywhere else it was stale and had to go anyway.
            echo "  -> removing absolute symlink $relpath (stow requires relative)"
            rm "$target"
            ;;
          *)
            # Relative symlink -- stow's own format. Resolve it and keep it
            # only when it genuinely points back into this repo.
            link_dest="$(cd -P "$(dirname "$target")/$(dirname "$link_text")" 2>/dev/null && pwd)"
            case "$link_dest" in
              "$DOTFILES_DIR"*) ;;
              *)
                echo "  -> removing stale symlink $relpath"
                rm "$target"
                ;;
            esac
            ;;
        esac
      elif [ -e "$target" ]; then
        if [ -e "$target.bak" ]; then
          suffix="$(date +%Y%m%d%H%M%S)"
          echo "  -> backing up $relpath (existing .bak preserved; using .bak.$suffix)"
          mv "$target" "$target.bak.$suffix"
        else
          echo "  -> backing up $relpath"
          mv "$target" "$target.bak"
        fi
      fi
    done <<EOF
$(find "$DOTFILES_DIR/$package" -type f 2>/dev/null)
EOF
  done
}

stow_packages() {
  for package in "$@"; do
    if [ -d "$DOTFILES_DIR/$package" ]; then
      echo "  -> stowing $package"
      stow --no-folding --restow -d "$DOTFILES_DIR" -t "$HOME" "$package"
    fi
  done
}

install_tmux_plugins() {
  tpm_dir="$HOME/.config/tmux/plugins/tpm"
  sessionx_dir="$HOME/.config/tmux/plugins/tmux-sessionx"
  resurrect_dir="$HOME/.config/tmux/plugins/tmux-resurrect"
  resurrect_save="$resurrect_dir/scripts/save.sh"

  if [ ! -d "$tpm_dir" ]; then
    echo "  -> installing TPM (tmux plugin manager)"
    git clone https://github.com/tmux-plugins/tpm "$tpm_dir"
  else
    echo "  -> TPM already installed"
  fi

  # TPM can't clone commit-pinned plugins on a fresh install (its clone
  # helper does `git clone -b <ref> --single-branch`, and -b never accepts a
  # raw SHA) — handle tmux-sessionx's pin manually, and do it BEFORE calling
  # TPM's install_plugins below so TPM's plugin_already_installed check sees
  # the directory already present and skips its own (always-failing) clone
  # attempt for this plugin. Every other plugin still goes through TPM
  # untouched.
  if [ ! -d "$sessionx_dir" ]; then
    echo "  -> installing tmux-sessionx (pinned commit $TMUX_SESSIONX_PIN)"
    if ! git clone https://github.com/omerxx/tmux-sessionx "$sessionx_dir"; then
      echo "ERROR: failed to clone tmux-sessionx." >&2
      return 1
    fi
    if ! (cd "$sessionx_dir" && git checkout "$TMUX_SESSIONX_PIN"); then
      echo "ERROR: failed to check out tmux-sessionx pin $TMUX_SESSIONX_PIN." >&2
      return 1
    fi
  else
    # Idempotent re-pin: a prior run (or a manual/TPM update-all) may have
    # left this checkout on a different commit or in a detached HEAD past
    # the pin. Re-check-out the pin only if we're not already sitting on it
    # — cheap on the common case, and detached HEAD is fine either way
    # since we always check out a commit, never a branch.
    current_rev="$(cd "$sessionx_dir" && git rev-parse HEAD 2>/dev/null)"
    pinned_rev="$(cd "$sessionx_dir" && git rev-parse "$TMUX_SESSIONX_PIN" 2>/dev/null)"
    if [ -z "$pinned_rev" ]; then
      echo "  -> fetching tmux-sessionx (pin $TMUX_SESSIONX_PIN not present locally)"
      if ! (cd "$sessionx_dir" && git fetch --quiet origin "$TMUX_SESSIONX_PIN"); then
        echo "ERROR: failed to fetch tmux-sessionx pin $TMUX_SESSIONX_PIN." >&2
        return 1
      fi
      pinned_rev="$(cd "$sessionx_dir" && git rev-parse "$TMUX_SESSIONX_PIN" 2>/dev/null)"
    fi
    if [ "$current_rev" != "$pinned_rev" ] || [ -z "$current_rev" ]; then
      echo "  -> checking out tmux-sessionx pin $TMUX_SESSIONX_PIN (was $current_rev)"
      if ! (cd "$sessionx_dir" && git checkout "$TMUX_SESSIONX_PIN"); then
        echo "ERROR: failed to check out tmux-sessionx pin $TMUX_SESSIONX_PIN." >&2
        return 1
      fi
    else
      echo "  -> tmux-sessionx already at pin $TMUX_SESSIONX_PIN"
    fi
  fi

  # Same TPM limitation, same workaround, for tmux-resurrect: pin it to the
  # exact commit setup/patches/tmux-resurrect-tmux37-delimiter.patch was
  # generated against, BEFORE calling TPM's install_plugins below, so TPM's
  # plugin_already_installed check skips its own (always-failing) clone
  # attempt for this plugin too.
  if [ ! -d "$resurrect_dir" ]; then
    echo "  -> installing tmux-resurrect (pinned commit $TMUX_RESURRECT_PIN)"
    if ! git clone https://github.com/tmux-plugins/tmux-resurrect "$resurrect_dir"; then
      echo "ERROR: failed to clone tmux-resurrect." >&2
      return 1
    fi
    if ! (cd "$resurrect_dir" && git checkout "$TMUX_RESURRECT_PIN"); then
      echo "ERROR: failed to check out tmux-resurrect pin $TMUX_RESURRECT_PIN." >&2
      return 1
    fi
  else
    # Idempotent re-pin — see the identical tmux-sessionx comment above for
    # rationale (detached HEAD is fine; we always check out a commit).
    current_rev="$(cd "$resurrect_dir" && git rev-parse HEAD 2>/dev/null)"
    pinned_rev="$(cd "$resurrect_dir" && git rev-parse "$TMUX_RESURRECT_PIN" 2>/dev/null)"
    if [ -z "$pinned_rev" ]; then
      echo "  -> fetching tmux-resurrect (pin $TMUX_RESURRECT_PIN not present locally)"
      if ! (cd "$resurrect_dir" && git fetch --quiet origin "$TMUX_RESURRECT_PIN"); then
        echo "ERROR: failed to fetch tmux-resurrect pin $TMUX_RESURRECT_PIN." >&2
        return 1
      fi
      pinned_rev="$(cd "$resurrect_dir" && git rev-parse "$TMUX_RESURRECT_PIN" 2>/dev/null)"
    fi
    if [ "$current_rev" != "$pinned_rev" ] || [ -z "$current_rev" ]; then
      echo "  -> checking out tmux-resurrect pin $TMUX_RESURRECT_PIN (was $current_rev)"
      if ! (cd "$resurrect_dir" && git checkout "$TMUX_RESURRECT_PIN"); then
        echo "ERROR: failed to check out tmux-resurrect pin $TMUX_RESURRECT_PIN." >&2
        return 1
      fi
    else
      echo "  -> tmux-resurrect already at pin $TMUX_RESURRECT_PIN"
    fi
  fi

  # Apply the tmux 3.7 delimiter-sanitization patch. A worker running with
  # an unpatched tmux-resurrect on tmux >= 3.7 has a silently broken safety
  # net (saves produce a corrupt/empty resurrect file with no error), so
  # any failure here is FATAL, matching this repo's doctrine of never
  # leaving that failure mode silent.
  if grep -q "$TMUX_RESURRECT_PATCH_MARKER" "$resurrect_save" 2>/dev/null; then
    echo "  -> tmux-resurrect tmux37 delimiter patch already applied"
  else
    if [ ! -f "$TMUX_RESURRECT_PATCH" ]; then
      echo "ERROR: tmux-resurrect patch not found: $TMUX_RESURRECT_PATCH" >&2
      return 1
    fi
    if ! (cd "$resurrect_dir" && git apply --check "$TMUX_RESURRECT_PATCH") 2>/dev/null; then
      echo "ERROR: tmux-resurrect tmux37 delimiter patch does not apply cleanly against pin $TMUX_RESURRECT_PIN (checked out at $resurrect_dir). A worker with unpatched tmux-resurrect on tmux >= 3.7 has a silently broken save/restore safety net — refusing to continue." >&2
      return 1
    fi
    if ! (cd "$resurrect_dir" && git apply "$TMUX_RESURRECT_PATCH"); then
      echo "ERROR: tmux-resurrect tmux37 delimiter patch check passed but apply failed." >&2
      return 1
    fi
    if ! grep -q "$TMUX_RESURRECT_PATCH_MARKER" "$resurrect_save" 2>/dev/null; then
      echo "ERROR: tmux-resurrect tmux37 delimiter patch applied but marker '$TMUX_RESURRECT_PATCH_MARKER' not found in $resurrect_save afterwards." >&2
      return 1
    fi
    echo "  -> tmux-resurrect tmux37 delimiter patch applied"
  fi

  echo "  -> installing tmux plugins via TPM"
  if ! TMUX_PLUGIN_MANAGER_PATH="$HOME/.config/tmux/plugins/" "$tpm_dir/bin/install_plugins"; then
    echo "ERROR: TPM install_plugins failed (see output above)." >&2
    return 1
  fi

  if [ ! -x "$resurrect_save" ]; then
    echo "ERROR: tmux-resurrect save entrypoint missing or not executable: $resurrect_save" >&2
    return 1
  fi

  entrypoint_found=0
  for entry in "$DOTFILES_DIR"/tmux/local-plugins/*/*.tmux; do
    [ -e "$entry" ] || continue
    entrypoint_found=1
    if [ ! -r "$entry" ]; then
      echo "ERROR: repo-owned local-plugins entrypoint not readable: $entry" >&2
      return 1
    fi
  done
  if [ "$entrypoint_found" -eq 0 ]; then
    echo "ERROR: no repo-owned local-plugins entrypoints found under $DOTFILES_DIR/tmux/local-plugins/*/*.tmux" >&2
    return 1
  fi

  echo "  -> tmux plugins OK (TPM, tmux-resurrect save entrypoint, local-plugins entrypoints)"
}

link_rw() {
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DOTFILES_DIR/tmux/local-plugins/tmux-remote-workspaces/scripts/rw" "$HOME/.local/bin/rw"
  echo "  -> linked rw -> ~/.local/bin/rw"
}

seed_codex_config() {
  template="$DOTFILES_DIR/setup/templates/codex-config.toml"
  target="$HOME/.codex/config.toml"

  if [ ! -f "$template" ]; then
    echo "  (warn) codex config template not found: $template (skipping seed)"
    return 0
  fi

  mkdir -p "$HOME/.codex"

  if [ -e "$target" ]; then
    echo "  -> ~/.codex/config.toml already exists, leaving it alone"
  else
    cp "$template" "$target"
    echo "  -> seeded ~/.codex/config.toml from template (codex owns this file from now on)"
  fi
}

ensure_ssh_dirs() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  mkdir -p "$HOME/.ssh/sockets"
  chmod 700 "$HOME/.ssh/sockets"
}
