#!/usr/bin/env bash
# Keep Homebrew formulae at the same versions on this machine and every macOS
# worker in the rw config (tmux/local-plugins/tmux-remote-workspaces/config.json):
# `brew update && brew upgrade --formula` here, then on each worker over ssh,
# then list the formulae both have at different versions. Pinned formulae
# (tmux) are held by brew itself. Casks are left alone: upgrading a running
# GUI app (Ghostty) under the user is a manual step.
#
#   setup/brew-upgrade.sh          upgrade everywhere, then diff
#   setup/brew-upgrade.sh --diff   only the diff
set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$DOTFILES_DIR/tmux/local-plugins/tmux-remote-workspaces/config.json"
REMOTE_PATH='export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH;'
workers="$(jq -r '.workers[] | select(.platform == "darwin") | .alias' "$CONFIG")"
status=0

if [ "${1:-}" != "--diff" ]; then
  echo "== $(hostname -s)"
  { brew update && brew upgrade --formula; } || status=1
  for w in $workers; do
    echo "== $w"
    ssh "$w" "$REMOTE_PATH brew update && brew upgrade --formula" || status=1
  done
fi

# "name version" per installed formula (the linked keg, so leftover old kegs
# brew cleanup has not removed yet don't count), sorted for join.
VERSIONS="brew info --json=v2 --installed | jq -r '.formulae[] | \"\\(.name) \\(.linked_keg // .installed[-1].version)\"' | sort"
local_versions="$(eval "$VERSIONS")"
for w in $workers; do
  echo "== formulae installed on both $(hostname -s) and $w at different versions"
  remote_versions="$(ssh "$w" "$REMOTE_PATH $VERSIONS")" || {
    status=1
    continue
  }
  join <(echo "$local_versions") <(echo "$remote_versions") | awk '$2 != $3 { print "  " $1 ": " $2 " (here) vs " $3 " (" w ")"; n++ } END { if (!n) print "  none" }' w="$w"
done
exit "$status"
