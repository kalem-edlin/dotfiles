# Deduplicate PATH entries (nested shells — tmux panes inside SSH inside
# tmux, scripts sourcing this repeatedly, etc. — re-source this file often).
# Zero-cost idiom; must run before any PATH mutation below to take effect.
typeset -U path PATH

# Sourced for every zsh invocation — interactive, noninteractive, login, and
# non-login (unlike .zshrc, which noninteractive shells such as SSH hooks,
# scp, and remote tmux commands never source). This is the only place that
# reliably puts ~/.local/bin on PATH for those noninteractive contexts, so
# hook-invoked executables (worktree-claim, provider hooks) resolve.
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# Homebrew's bin/sbin aren't on PATH for noninteractive SSH sessions (sshd
# hands the command a minimal PATH), so e.g. `ssh worker 'command -v tmux
# git-lfs'` fails to find Homebrew-installed tools even though an
# interactive login shell (which sources /etc/zprofile's brew shellenv, or
# similar) would find them fine. Guarded on directory existence only, kept
# cheap: two stat calls, no subshells. Apple Silicon uses /opt/homebrew;
# Intel Homebrew uses /usr/local — don't assume /usr/local/bin is already on
# PATH under a stripped-down noninteractive shell just because it usually is
# under a normal one.
if [[ -d /opt/homebrew/bin ]]; then
  path=(/opt/homebrew/bin /opt/homebrew/sbin $path)
elif [[ -d /usr/local/bin ]]; then
  path=(/usr/local/bin /usr/local/sbin $path)
fi

# fnm's Linux bootstrap location (setup/node.sh installs fnm itself here when
# it isn't already available via Homebrew, which is covered above). Needed so
# `command -v fnm` resolves at all before fnm's own env init runs below.
[[ -d "$HOME/.local/share/fnm" ]] && path=("$HOME/.local/share/fnm" $path)

# pyenv's bin directory. setup/python.sh installs pyenv to ~/.pyenv on both
# macOS and Linux (via pyenv.run on Linux; see setup/python.sh). Previously
# PYENV_ROOT/PATH were only exported in zsh/.zshrc, which noninteractive
# shells (ssh worker 'pyenv ...', hooks, scp) never source -- so the pyenv
# binary existed on disk but never resolved outside an interactive shell
# (confirmed: ~/.pyenv/bin/pyenv present but unresolved under `ssh agents-
# roll 'command -v pyenv'`, 2026-08-02). Exported here, same pattern as
# ~/.local/bin and fnm above, so it resolves noninteractively too.
# zsh/.zshrc still does the interactive-only `eval "$(pyenv init -)"` shims
# (shell function wrapping, completion) — that part is deliberately
# interactive-only and does not belong in this file. No output, no TTY
# assumptions: PATH/env only.
export PYENV_ROOT="$HOME/.pyenv"
[[ -d "$PYENV_ROOT/bin" ]] && path=("$PYENV_ROOT/bin" $path)

# Rust toolchain env (PATH etc.). The pre-dotfiles ~/.zshenv sourced this;
# stow replaces that file, so it must be preserved here or cargo/rustc
# silently drop off PATH.
[[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"

# Claude Code envoy CLI (originally added to the laptop's pre-dotfiles
# ~/.zshenv by allhands). Preserved here for the same reason as .cargo/env
# above: stow replaces that file, and dropping this would silently remove
# envoy from PATH. Guarded on the relative path, so it only ever applies in a
# directory that actually ships one.
[[ -f ".claude/envoy/envoy" ]] && export PATH="$PWD/.claude/envoy:$PATH"

# Initialize fnm for noninteractive shells only. This is what puts the
# selected default Node/npm and npm-global CLIs (pi, codex) on PATH for
# `ssh worker 'command'` invocations, which never source .zshrc. Interactive
# shells get the fuller `--use-on-cd` setup from .zshrc's own fnm block
# (zsh/.zshrc); skipping here when interactive avoids spawning fnm and
# re-evaling its env a second time on every interactive shell startup.
# FNM_DIR is also checked so nested noninteractive shells that already
# inherited it from a parent process don't redo the (cheap but nonzero)
# subprocess spawn. Must stay silent — no output, no TTY assumptions.
if [[ ! -o interactive ]] && [[ -z "$FNM_DIR" ]] && command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env)" 2>/dev/null
fi

# ssh/.ssh/config points ControlPath at ~/.ssh/sockets/, but ssh never
# creates that directory itself. Created here (cheap, guarded stat check)
# rather than in Makefile/setup so it exists before any ssh invocation,
# including noninteractive ones (this file runs for every zsh shell).
# `mkdir -p -m 700` only guarantees that mode on the deepest directory it
# creates — under umask 022 a freshly created ~/.ssh would be left 755 here,
# only ~/.ssh/sockets would end up 700. mkdir both, then chmod both
# explicitly instead.
if [[ ! -d "$HOME/.ssh/sockets" ]]; then
  mkdir -p "$HOME/.ssh" "$HOME/.ssh/sockets" 2>/dev/null
  chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets" 2>/dev/null
fi
