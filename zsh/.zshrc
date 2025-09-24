# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Configure where vim config lies
export VIMINIT='source $MYVIMRC'
export MYVIMRC='~/.config/vim/.vimrc' 

ZSH_THEME="robbyrussell"
zstyle ':omz:update' mode auto      # update automatically without asking

# Enable command auto-correction.
ENABLE_CORRECTION="true"

eval "$(starship init zsh)"
# export STARSHIP_CONFIG=~/.config/starship/starship.toml

source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh


# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

source $ZSH/oh-my-zsh.sh

# User configuration

alias la=tree
alias cat=bat

# export MANPATH="/usr/local/man:$MANPATH"

You may need to manually set your language environment
export LANG=en_US.UTF-8

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

alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

alias cl='clear'

# VI Mode
bindkey '^C' vi-cmd-mode
bindkey '^X' send-break 

# Open Code editor at current directory
function cursor {
  open -a "/Applications/Cursor.app" "$@"
}
alias c='cursor'

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# Set personal aliases, overriding those provided by Oh My Zsh libs,
# plugins, and themes. Aliases can be placed here, though Oh My Zsh
# users are encouraged to define aliases within a top-level file in
# the $ZSH_CUSTOM folder, with .zsh extension. Examples:
# - $ZSH_CUSTOM/aliases.zsh
# - $ZSH_CUSTOM/macos.zsh
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"
alias mkcd='mkdir -p "$1" && cd "$1"'
alias ll='ls -al'

export XDG_CONFIG_HOME="/Users/kedlin/.config"

# Kafka in cli
export PATH=/usr/local/kafka/bin:$PATH

eval "$(zoxide init zsh)"
