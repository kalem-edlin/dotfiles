#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# E: installing a claude transcript marks the destination folder trusted in
# ~/.claude.json (projects[<path>].hasTrustDialogAccepted = true), on the
# worker (over ssh) and locally, keeping every other key; so a resumed
# claudef never stops at the "trust this folder" dialog.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

CL="$RW_PLUGIN/libexec/adapters/claude"
snap="$SANDBOX/snap"
mkdir -p "$snap"
echo '{"type":"user","cwd":"/old","message":"hi"}' >"$snap/session.jsonl"
echo '{"provider":"claude","session_id":"s-1"}' >"$snap/manifest.json"

# Worker: no ~/.claude.json yet.
wdest="$FAKE_WORKER_HOME/Developer/never opened"
mkdir -p "$wdest"
"$CL" install --snapshot "$snap" --dest-path "$wdest" --worker fakeworker >/dev/null 2>&1
eq "E: worker folder trusted" "$(jq -r --arg p "$wdest" '.projects[$p].hasTrustDialogAccepted' "$FAKE_WORKER_HOME/.claude.json")" "true"
eq "E: worker ~/.claude.json stays private" "$(stat -f %Lp "$FAKE_WORKER_HOME/.claude.json" 2>/dev/null || stat -c %a "$FAKE_WORKER_HOME/.claude.json")" "600"

# Laptop: an existing ~/.claude.json with other state that must survive.
ldest="$HOME/Developer/proj"
mkdir -p "$ldest"
jq -n --arg p "$ldest" '{oauthAccount: {x: 1}, numStartups: 9,
  projects: {"/elsewhere": {hasTrustDialogAccepted: false}, ($p): {allowedTools: ["Bash"], lastSessionId: "z"}}}' >"$HOME/.claude.json"
"$CL" install --snapshot "$snap" --dest-path "$ldest" >/dev/null 2>&1
j="$HOME/.claude.json"
eq "E: local folder trusted" "$(jq -r --arg p "$ldest" '.projects[$p].hasTrustDialogAccepted' "$j")" "true"
eq "E: its other project keys kept" "$(jq -c --arg p "$ldest" '.projects[$p] | [.allowedTools, .lastSessionId]' "$j")" '[["Bash"],"z"]'
eq "E: other projects untouched" "$(jq -r '.projects["/elsewhere"].hasTrustDialogAccepted' "$j")" "false"
eq "E: global state untouched" "$(jq -c '[.oauthAccount, .numStartups]' "$j")" '[{"x":1},9]'
before="$(cksum <"$j")"
"$CL" install --snapshot "$snap" --dest-path "$ldest" >/dev/null 2>&1
eq "E: an already trusted folder leaves the file byte-for-byte alone" "$(cksum <"$j")" "$before"

finish
