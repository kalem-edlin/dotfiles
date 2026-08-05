# Fix broken stdout (can happen if shell was exec'd with redirected fd)
# Only for interactive shells with a real tty available — noninteractive SSH
# shells (hooks, scp, remote tmux commands) must not have stdout redirected.
if [[ -o interactive ]] && [[ ! -t 1 ]] && [[ -e /dev/tty ]]; then
  exec > /dev/tty
fi

# Terminal settings (fixes backspace over SSH, ensures color support)
# Force xterm-256color if current TERM isn't in local terminfo (e.g. xterm-ghostty over SSH)
if ! infocmp "$TERM" &>/dev/null 2>&1; then
  export TERM="xterm-256color"
fi
stty erase '^?' 2>/dev/null

# Ensure ~/.local/bin is on PATH (also set in .zshenv for noninteractive
# shells, which never source this file; guard avoids duplicate entries here)
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# Dotfiles directory (derived from this symlinked file)
if [[ -L ~/.zshrc ]]; then
  export DOTFILES="$(dirname "$(dirname "$(realpath ~/.zshrc)")")"
fi

# pyenv initialization
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init -)"
fi

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"


ZSH_THEME="robbyrussell"
zstyle ':omz:update' mode auto      # update automatically without asking

# Enable command auto-correction.
ENABLE_CORRECTION="true"

# Don't suggest corrections for dotfiles (.*) or underscore-prefixed files (_*)
export CORRECT_IGNORE_FILE=".*"
export CORRECT_IGNORE="_*"
export SPROMPT="Correct '%F{red}%R%f' to '%F{green}%r%f' [nyae]?"

ZVM_SYSTEM_CLIPBOARD_ENABLED=true
ZVM_VI_HIGHLIGHT_BACKGROUND=#A8A8A8

# zsh-vi-mode cursor configuration
function zvm_config() {
  # Insert mode: use default terminal cursor
  ZVM_INSERT_MODE_CURSOR=$ZVM_CURSOR_USER_DEFAULT
}

# Patch for zsh-vi-mode: fix lingering visual highlight
# Must be defined BEFORE sourcing the plugin
function zvm_after_lazy_keybindings() {
  # Override functions to add zvm_exit_visual_mode false
  function zvm_insert_bol() {
    ZVM_INSERT_MODE='I'
    zle vi-first-non-blank
    zvm_exit_visual_mode false
    zvm_select_vi_mode $ZVM_MODE_INSERT
    zvm_reset_repeat_commands $ZVM_MODE_NORMAL $ZVM_INSERT_MODE
  }

  function zvm_append_eol() {
    ZVM_INSERT_MODE='A'
    zle vi-end-of-line
    zvm_exit_visual_mode false
    zvm_select_vi_mode $ZVM_MODE_INSERT
    zvm_reset_repeat_commands $ZVM_MODE_NORMAL $ZVM_INSERT_MODE
  }
}

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

if [[ -r "$ZSH/oh-my-zsh.sh" ]]; then
  source "$ZSH/oh-my-zsh.sh"
fi

source_if_exists() {
  [[ -r "$1" ]] && source "$1"
}

# zsh plugins (Homebrew on macOS/Linuxbrew, distro packages on Linux).
# zsh-autosuggestions IS distro-packaged on Linux and setup/linux-headless.sh
# installs it as a guarded OPTIONAL convenience (apt/dnf/pacman/zypper: pkg
# "zsh-autosuggestions"; confirmed available via `apt-cache policy
# zsh-autosuggestions` on agents-roll, Ubuntu 24.04, 2026-08-02). zsh-vi-mode
# (jeffreytse/zsh-vi-mode) is NOT packaged by any mainstream distro's default
# repos (confirmed absent from apt on Ubuntu 24.04 via both `apt-cache
# policy` and `apt-cache search`) -- setup/linux-headless.sh does not attempt
# to install it, so on Linux it only activates if manually cloned to
# ~/.zsh/zsh-vi-mode (the last source_if_exists below) or otherwise placed at
# one of the paths checked here. Every source_if_exists guard below is a
# silent no-op when its target is absent, on every platform -- an unmet
# plugin never breaks shell startup.
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
  source_if_exists "$BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
  source_if_exists "$BREW_PREFIX/opt/zsh-vi-mode/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
fi
source_if_exists /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source_if_exists /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source_if_exists /usr/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
source_if_exists /usr/share/zsh/plugins/zsh-vi-mode/zsh-vi-mode.plugin.zsh
source_if_exists "$HOME/.zsh/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
# zsh-autocomplete disabled — conflicts with autosuggestions and fzf tab handling
# source $(brew --prefix)/opt/zsh-autocomplete/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh


# export MANPATH="/usr/local/man:$MANPATH"

# Language environment
export LANG=en_US.UTF-8
export LC_ALL="en_US.UTF-8"
export LANGUAGE="en_US.UTF-8"

# Hide the "default interactive shell is now zsh" warning on macOS
export BASH_SILENCE_DEPRECATION_WARNING=1

# ZSH History (100k lines, persisted across sessions)
export HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
export HISTSIZE=100000
export SAVEHIST="$HISTSIZE"

# Typos
alias gut="git"
alias gti="git"
alias mdkir="mkdir"
if command -v brew >/dev/null 2>&1; then
  alias brwe="brew"
fi
alias pmpm="pnpm"
alias pmpn="pnpm"

# Sane defaults for built-ins (verbose and interactive)
alias cp='cp -iv'
alias mv='mv -iv'
# rm is aliased to 'trash' below - use \rm for real rm
alias grep="grep -i --color=auto"
alias mkdir="mkdir -p"

# Enhancements
alias python="python3"
alias vi="nvim"
alias vim="nvim"
alias view="nvim -R"
alias vimdiff="nvim -d"
alias nvm="fnm"
command -v tree >/dev/null 2>&1 && alias la=tree
if command -v fd >/dev/null 2>&1; then
  alias find="fd"
elif command -v fdfind >/dev/null 2>&1; then
  alias find="fdfind"
fi
if command -v bat >/dev/null 2>&1; then
  alias cat="bat --style=plain"
elif command -v batcat >/dev/null 2>&1; then
  alias cat="batcat --style=plain"
fi
if command -v eza >/dev/null 2>&1; then
  alias ls="eza --no-user --icons=auto --group-directories-first --color-scale=age"
fi
alias mkcd='mkdir -p "$1" && cd "$1"'
command -v eza >/dev/null 2>&1 && alias ll='eza -la --icons --git'
command -v eza >/dev/null 2>&1 && alias lt='eza --tree --level=2 --icons'
alias lsa="ls -a"
if command -v eza >/dev/null 2>&1; then
  alias lt="ls --tree --level=2 --long --header --git --git-ignore"
fi
alias lta="lt -a"
command -v btop >/dev/null 2>&1 && alias top="btop"
command -v prettyping >/dev/null 2>&1 && alias ping="prettyping --nolegend"
alias get="curl -O -L"
alias path='echo -e ${PATH//:/\\n}'


alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

reload-dotfiles() {
  if [[ -n "${DOTFILES:-}" ]] && command -v make >/dev/null 2>&1; then
    make -C "$DOTFILES" reload
  fi
}

# Clear screen and reload dotfiles configs when make is available
alias clear='reload-dotfiles; command clear'
alias cl='clear'


# Open Code editor at current directory
function cursor {
  if (( $+commands[cursor] )); then
    command cursor "$@"
  elif [[ "$OSTYPE" == darwin* ]]; then
    open -a "/Applications/Cursor.app" "$@"
  else
    echo "Cursor GUI is not available in this headless shell."
    return 127
  fi
}
alias c='cursor'

# Notifier command (Jamf Notifier)
function notifier {
  if [[ "$OSTYPE" == darwin* ]]; then
    /Applications/Utilities/Notifier.app/Contents/MacOS/Notifier "$@"
  else
    echo "Notifier is only available on macOS."
    return 127
  fi
}

alias ld="lazydocker"
alias zshconfig='$EDITOR ~/.zshrc'
alias ohmyzsh='$EDITOR ~/.oh-my-zsh'

# Git
alias gc="git commit -m"
alias gca="git commit -a -m"
alias gp="git push origin HEAD"
alias gpu="git pull origin"
alias gst="git status"
alias glog="git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit"
alias gdiff="git diff"
alias gco="git checkout"
alias gb='git branch'
alias gba='git branch -a'
alias gadd='git add'
alias ga='git add -p'
alias gcoall='git checkout -- .'
alias gr='git remote'
alias gre='git reset'

function git() {
  # Clone a GitHub repo and cd into the created directory
  if [[ "${1:-}" = "clone" ]];
  then
    command git clone "${@:2}"

    if [ "$3" ]; then
      cd "$3"
    else
      cd $(basename "$2" .git)
    fi

    if [[ -r "./yarn.lock" ]]; then
      yarn
    elif [[ -r "./pnpm-lock.yaml" ]]; then
      pnpm install
    elif [[ -r "./package-lock.json" ]]; then
      npm install
    elif [[ -r "./bun.lock" ]]; then
      bun install
    fi
  else
    command git $@
  fi
}

unalias rm 2>/dev/null  # Remove any existing alias before defining function
function rm() {
  local trash_cmd=""

  if command -v trash >/dev/null 2>&1; then
    trash_cmd="trash"
  elif command -v trash-put >/dev/null 2>&1; then
    trash_cmd="trash-put"
  else
    command rm "$@"
    return
  fi

  local args=()
  for arg in "$@"; do
    case "$arg" in
      -r|-f|-rf|-fr|-R|-Rf|-fR) ;;  # trash doesn't need these
      *) args+=("$arg") ;;
    esac
  done
  "$trash_cmd" "${args[@]}"
}

# Cd into the directory shown by the front-most Finder window
# Based on https://scriptingosx.com/2017/02/terminal-finder-interaction/
cdf() {
  if [[ "$OSTYPE" == darwin* ]]; then
    cd "$(osascript -e 'tell app "Finder" to POSIX path of (insertion location as alias)')"
  else
    echo "cdf is only available on macOS."
    return 127
  fi
}

# Make a new directory and cd into it
take() {
  \mkdir -p "$1" && cd "$1"
}


# Preferred editor for local and remote sessions
export EDITOR="nvim"
export VISUAL="$EDITOR"
export SUDO_EDITOR="$EDITOR"
export FCEDIT="$EDITOR"

# Compilation flags
# export ARCHFLAGS="-arch x86_64"



export XDG_CONFIG_HOME="$HOME/.config"

# Bat theme (used by bat and cat alias)
export BAT_THEME="Catppuccin Mocha"

# Privacy: disable telemetry
export NEXT_TELEMETRY_DISABLED=1
export VERCEL_TELEMETRY_DISABLED=1

# NPM defaults
export NPM_CONFIG_INIT_AUTHOR_NAME="Kalem Edlin"
export NPM_CONFIG_INIT_LICENSE="MIT"
export NPM_CONFIG_INIT_VERSION="0.1.0"
export NPM_CONFIG_SAVE="true"
export NPM_CONFIG_UPDATE_NOTIFIER="false"

# Claude Code LSP Tools
export ENABLE_LSP_TOOLS=1

if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# ============================================================================
# FZF Configuration
# ============================================================================

if command -v fd >/dev/null 2>&1; then
  FZF_FD_CMD="fd"
elif command -v fdfind >/dev/null 2>&1; then
  FZF_FD_CMD="fdfind"
fi

if command -v bat >/dev/null 2>&1; then
  FZF_BAT_CMD="bat"
elif command -v batcat >/dev/null 2>&1; then
  FZF_BAT_CMD="batcat"
fi

if [[ -n "${FZF_BAT_CMD:-}" ]]; then
  FZF_FILE_PREVIEW="$FZF_BAT_CMD -n --color=always {}"
else
  FZF_FILE_PREVIEW="sed -n 1,200p {}"
fi

if command -v eza >/dev/null 2>&1; then
  FZF_TREE_PREVIEW='eza --tree --color=always {} | head -200'
else
  FZF_TREE_PREVIEW='find {} -maxdepth 2 -print | head -200'
fi

if command -v pbcopy >/dev/null 2>&1; then
  FZF_COPY_CMD='pbcopy'
elif command -v wl-copy >/dev/null 2>&1; then
  FZF_COPY_CMD='wl-copy'
elif command -v xclip >/dev/null 2>&1; then
  FZF_COPY_CMD='xclip -selection clipboard'
elif command -v xsel >/dev/null 2>&1; then
  FZF_COPY_CMD='xsel --clipboard --input'
fi

# Use fd instead of find (respects .gitignore, includes hidden, excludes .git)
if [[ -n "${FZF_FD_CMD:-}" ]]; then
  export FZF_DEFAULT_COMMAND="$FZF_FD_CMD --type f --hidden --exclude .git"
else
  export FZF_DEFAULT_COMMAND="find . -path '*/.git' -prune -o -type f -print"
fi

# CTRL-T: Paste selected files onto command-line
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_CTRL_T_OPTS="--preview '$FZF_FILE_PREVIEW'"

# ALT-C: cd into selected directory
export FZF_ALT_C_OPTS="--preview '$FZF_TREE_PREVIEW'"

# CTRL-R: Search command history
export FZF_CTRL_R_OPTS="
  --preview 'echo {}' --preview-window down:3:hidden:wrap
  --bind 'ctrl-/:toggle-preview'
  --color header:italic
  --header 'Press CTRL-Y to copy command into clipboard'"
if [[ -n "${FZF_COPY_CMD:-}" ]]; then
  export FZF_CTRL_R_OPTS="$FZF_CTRL_R_OPTS
  --bind 'ctrl-y:execute-silent(echo -n {2..} | $FZF_COPY_CMD)+abort'"
fi

# Completion settings
export FZF_COMPLETION_TRIGGER='**'
export FZF_COMPLETION_OPTS='--border --info=inline'

# selected-fg/selected-bg colors landed in fzf 0.55.0 -- the apt-installed
# fzf on the Linux worker predates that and errors "invalid color
# specification" on EVERY interactive shell when it's passed unconditionally
# (2026-08-05). Gate just that one color spec on the installed version:
# cheap (one `fzf --version` call), zsh-native compare via `sort -V` (no
# bc/python needed, portable to the worker's coreutils too).
FZF_SELECTED_BG_OPT=""
if command -v fzf >/dev/null 2>&1; then
  fzf_version="$(fzf --version 2>/dev/null | awk '{print $1}')"
  if [[ -n "$fzf_version" ]] &&
    [[ "$(printf '%s\n%s\n' "$fzf_version" "0.55.0" | sort -V | head -n1)" == "0.55.0" ]]; then
    FZF_SELECTED_BG_OPT=" --color=selected-bg:#45475a"
  fi
  unset fzf_version
fi

# Catppuccin Mocha theme for fzf
export FZF_DEFAULT_OPTS=" \
--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
--color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8${FZF_SELECTED_BG_OPT} \
--height 60% \
--border rounded \
--layout reverse \
--prompt '▶ ' \
--pointer '▪︎' \
--marker '✔ ' \
--bind 'ctrl-/:change-preview-window(hidden|)' \
--preview-window='border-rounded' \
--info right"

# Use fd for path/directory completion (respects .gitignore)
_fzf_compgen_path() {
  if [[ -n "${FZF_FD_CMD:-}" ]]; then
    "$FZF_FD_CMD" --hidden --exclude ".git" . "$1"
  else
    find "$1" -path "*/.git" -prune -o -type f -print
  fi
}

_fzf_compgen_dir() {
  if [[ -n "${FZF_FD_CMD:-}" ]]; then
    "$FZF_FD_CMD" --type d --hidden --exclude ".git" . "$1"
  else
    find "$1" -path "*/.git" -prune -o -type d -print
  fi
}

# Advanced customization of fzf options via _fzf_comprun function
_fzf_comprun() {
  local command=$1
  shift

  case "$command" in
    cd)      fzf --preview "$FZF_TREE_PREVIEW" "$@" ;;
    export|unset) fzf --preview "eval 'echo \$'{}" "$@" ;;
    ssh)     fzf --preview 'dig {}' "$@" ;;
    *)       fzf --preview "$FZF_FILE_PREVIEW" "$@" ;;
  esac
}

# Set up fzf key bindings (Ctrl+R history, Ctrl+T files). `--zsh` needs
# fzf >= 0.48; older distro packages (Debian 0.44) ship the same script as
# a doc example instead.
if command -v fzf >/dev/null 2>&1; then
  if fzf --zsh >/dev/null 2>&1; then
    source <(fzf --zsh)
  elif [ -r /usr/share/doc/fzf/examples/key-bindings.zsh ]; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh
  fi
fi

# Tab completion with visual menu
zmodload zsh/complist
zstyle ':completion:*' menu select
_tab_accept() {
  zle autosuggest-clear
  zle expand-or-complete
}
zle -N _tab_accept
bindkey '\t' _tab_accept
# Inside the menu: tab accepts, Ctrl+N/P cycle laterally
bindkey -M menuselect '\t' .accept-line
bindkey -M menuselect '\r' .accept-line
bindkey -M menuselect '^N' menu-complete
bindkey -M menuselect '^P' reverse-menu-complete


# fnm (Node version manager)
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --version-file-strategy=recursive)"
fi

export PATH="$HOME/.bun/bin:$PATH"

# Claude Code envoy CLI (added by allhands)
[[ -f ".claude/envoy/envoy" ]] && export PATH="$PWD/.claude/envoy:$PATH"

# AllHands envoy command - resolves to .claude/envoy/envoy from current directory
envoy() {
  "$PWD/.claude/envoy/envoy" "$@"
}

# Incremental builds for xcodemake enabled
export INCREMENTAL_BUILDS_ENABLED=1
[[ -f "$HOME/.daytona.completion_script.zsh" ]] && source "$HOME/.daytona.completion_script.zsh"
export GIT_WORKTREE_PARENT="$HOME/Developer/content-engine-trees"

# qlty completions
[ -s "/opt/homebrew/share/zsh/site-functions/_qlty" ] && source "/opt/homebrew/share/zsh/site-functions/_qlty"

# qlty
export QLTY_INSTALL="$HOME/.qlty"
export PATH="$QLTY_INSTALL/bin:$PATH"

# Continuous-Claude OPC directory (for skills to find scripts)
export CLAUDE_OPC_DIR="$HOME/Developer/Agentic/Continuous-Claude-v3/opc"

# The next line updates PATH for the Google Cloud SDK.
if [ -f "$HOME/Developer/utils/google-cloud-sdk/path.zsh.inc" ]; then . "$HOME/Developer/utils/google-cloud-sdk/path.zsh.inc"; fi

# The next line enables shell command completion for gcloud.
if [ -f "$HOME/Developer/utils/google-cloud-sdk/completion.zsh.inc" ]; then . "$HOME/Developer/utils/google-cloud-sdk/completion.zsh.inc"; fi


# Figma CLI
if [[ -x "/Users/kalemedlin/Developer/figma-cli/figma-cli/bin/fig-start" ]]; then
  alias fig-start='/Users/kalemedlin/Developer/figma-cli/figma-cli/bin/fig-start'
fi

# Persist each tmux pane's last submitted command and current ZLE edit buffer.
source_if_exists "$HOME/.zsh/tmux-workspace-resurrect.zsh"
