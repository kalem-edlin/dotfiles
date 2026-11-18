#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Agent detection inputs:
#   A  the pane's agent state is read from the CURRENT server's scoped file
#      (agents/server-<pid>-<start>/pane-N.json), never the legacy flat
#      agents/pane-N.json, which names a stale session from an older server
#   B  the claude process pattern matches claudef's patched build
#      (~/.cache/claudef/bin/<version>) and the native versioned install, as
#      well as bare `claude`

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

export TMUX_WORKSPACE_RESURRECT_STATE_DIR="$SANDBOX/wr-state"
export FAKE_TMUX_SERVER="5151:1790000000"
agents="$TMUX_WORKSPACE_RESURRECT_STATE_DIR/agents"
mkdir -p "$agents/server-5151-1790000000"
echo '{"tool":"claude","session_id":"stale-august","cwd":"/old"}' >"$agents/pane-7.json"
echo '{"tool":"claude","session_id":"current-1","cwd":"/now"}' >"$agents/server-5151-1790000000/pane-7.json"

read_state() { # <pane> <provider>
  bash -c "source '$RW_PLUGIN/libexec/adapters/common-adapter.sh'; ca_read_pane_agent_state '$1' '$2'" 2>/dev/null
}
eq "A: the current server's record wins over a stale flat file" "$(read_state %7 claude | jq -r .session_id)" "current-1"
rm "$agents/server-5151-1790000000/pane-7.json"
eq "A: a flat file alone is never used" "$(read_state %7 claude)" ""
echo '{"tool":"claude","session_id":"other-server"}' >"$agents/pane-8.json"
mkdir -p "$agents/server-1-1"
echo '{"tool":"claude","session_id":"older-server"}' >"$agents/server-1-1/pane-8.json"
eq "A: another server's scoped record is not this pane's" "$(read_state %8 claude)" ""
echo '{"tool":"pi","session_id":"p"}' >"$agents/server-5151-1790000000/pane-9.json"
eq "A: tool must match the provider" "$(read_state %9 claude)" ""

# --- B ---------------------------------------------------------------------------
# shellcheck source=../scripts/common.sh
source "$RW_PLUGIN/scripts/common.sh"
rw_pat="$(rw_provider_pattern claude)"
ca_pats="$(bash -c "source '$RW_PLUGIN/libexec/adapters/common-adapter.sh'; ca_patterns_claude")"
matches() { # <command line> -- both pattern sets must agree
  local rw=no ca=no p
  printf '%s\n' "$1" | grep -Eq "$rw_pat" && rw=yes
  while IFS= read -r p; do printf '%s\n' "$1" | grep -Eq "$p" && ca=yes; done <<<"$ca_pats"
  [ "$rw" = "$ca" ] || { echo "disagree:$rw/$ca"; return; }
  echo "$rw"
}
eq "B: claudef's patched build" "$(matches "/Users/x/.cache/claudef/bin/2.1.327 --dangerously-skip-permissions --resume abc")" "yes"
eq "B: the patched build with no arguments" "$(matches "/Users/x/.cache/claudef/bin/2.1.327")" "yes"
eq "B: the native versioned install" "$(matches "/Users/x/.local/share/claude/versions/2.1.326 --resume abc")" "yes"
eq "B: bare claude" "$(matches "claude --resume abc")" "yes"
eq "B: not claudefoo" "$(matches "claudefoo --x")" "no"
eq "B: not a file named claude.md" "$(matches "nvim claude.md")" "no"
eq "B: not the claudef launcher script itself" "$(matches "/bin/sh /Users/x/.local/bin/claudef --resume abc")" "no"

# The process-tree check rw uses to verify a (local or remote) resume.
printf '300 1 -zsh\n301 300 /Users/x/.cache/claudef/bin/2.1.327 --resume abc\n' >"$SANDBOX/ps"
check "B: the resume check finds claudef's build under the pane" bash -c "source '$RW_PLUGIN/scripts/common.sh'; rw_ps_tree_matches \"\$(rw_provider_pattern claude)\" 300 <'$SANDBOX/ps'"

finish
