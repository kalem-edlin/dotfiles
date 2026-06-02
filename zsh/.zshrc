# Fix broken stdout (can happen if shell was exec'd with redirected fd)
if [[ ! -t 1 ]]; then
  exec > /dev/tty
fi

# Terminal settings (fixes backspace over SSH, ensures color support)
# Force xterm-256color if current TERM isn't in local terminfo (e.g. xterm-ghostty over SSH)
if ! infocmp "$TERM" &>/dev/null 2>&1; then
  export TERM="xterm-256color"
fi
stty erase '^?' 2>/dev/null

# Dotfiles directory (derived from this symlinked file)
if [[ -L ~/.zshrc ]]; then
  export DOTFILES="$(dirname "$(dirname "$(realpath ~/.zshrc)")")"
fi

# pyenv initialization
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

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

source $ZSH/oh-my-zsh.sh

# Homebrew zsh plugins (loaded after oh-my-zsh)
source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source $(brew --prefix)/opt/zsh-vi-mode/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh
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
alias brwe="brew"
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
alias nvm="fnm"
alias la=tree
alias find="fd"
alias cat="bat --style=plain"
alias ls="eza --no-user --icons=auto --group-directories-first --color-scale=age"
alias mkcd='mkdir -p "$1" && cd "$1"'
alias ll='eza -la --icons --git'
alias lt='eza --tree --level=2 --icons'
alias lsa="ls -a"
alias lt="ls --tree --level=2 --long --header --git --git-ignore"
alias lta="lt -a"
alias top="btop"
alias ping="prettyping --nolegend"
alias get="curl -O -L"
alias path='echo -e ${PATH//:/\\n}'


alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

# Clear screen and reload dotfiles configs
alias clear='make -C $DOTFILES reload && command clear'
alias cl='clear'


# Open Code editor at current directory
function cursor {
  open -a "/Applications/Cursor.app" "$@"
}
alias c='cursor'

# Notifier command (Jamf Notifier)
function notifier {
  /Applications/Utilities/Notifier.app/Contents/MacOS/Notifier "$@"
}

alias ld="lazydocker"
alias zshconfig="vi ~/.zshrc"
alias ohmyzsh="vi ~/.oh-my-zsh"

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
  if [ $1 = "clone" ];
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
  local args=()
  for arg in "$@"; do
    case "$arg" in
      -r|-f|-rf|-fr|-R|-Rf|-fR) ;;  # trash doesn't need these
      *) args+=("$arg") ;;
    esac
  done
  trash "${args[@]}"
}

# Cd into the directory shown by the front-most Finder window
# Based on https://scriptingosx.com/2017/02/terminal-finder-interaction/
cdf() {
  cd "$(osascript -e 'tell app "Finder" to POSIX path of (insertion location as alias)')"
}

# Make a new directory and cd into it
take() {
  \mkdir -p "$1" && cd "$1"
}


# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='vi'
fi
export VISUAL="$EDITOR"

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

eval "$(zoxide init zsh)"

# ============================================================================
# FZF Configuration
# ============================================================================

# Use fd instead of find (respects .gitignore, includes hidden, excludes .git)
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'

# CTRL-T: Paste selected files onto command-line
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {}'"

# ALT-C: cd into selected directory
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

# CTRL-R: Search command history
export FZF_CTRL_R_OPTS="
  --preview 'echo {}' --preview-window down:3:hidden:wrap
  --bind 'ctrl-/:toggle-preview'
  --bind 'ctrl-y:execute-silent(echo -n {2..} | pbcopy)+abort'
  --color header:italic
  --header 'Press CTRL-Y to copy command into clipboard'"

# Completion settings
export FZF_COMPLETION_TRIGGER='**'
export FZF_COMPLETION_OPTS='--border --info=inline'

# Catppuccin Mocha theme for fzf
export FZF_DEFAULT_OPTS=" \
--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
--color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8 \
--color=selected-bg:#45475a \
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
  fd --hidden --exclude ".git" . "$1"
}

_fzf_compgen_dir() {
  fd --type d --hidden --exclude ".git" . "$1"
}

# Advanced customization of fzf options via _fzf_comprun function
_fzf_comprun() {
  local command=$1
  shift

  case "$command" in
    cd)      fzf --preview 'eza --tree --color=always {} | head -200' "$@" ;;
    export|unset) fzf --preview "eval 'echo \$'{}" "$@" ;;
    ssh)     fzf --preview 'dig {}' "$@" ;;
    *)       fzf --preview 'bat -n --color=always {}' "$@" ;;
  esac
}

# Set up fzf key bindings (Ctrl+R history, Ctrl+T files)
source <(fzf --zsh)

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
eval "$(fnm env --use-on-cd --version-file-strategy=recursive)"

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
alias fig-start='/Users/kalemedlin/Developer/figma-cli/figma-cli/bin/fig-start'
