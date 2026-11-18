#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Ownership records (C1): write/read, rw_owned_root_for_path (worker-owned
# only, longest match), overlap, endpoints, held index, worker mirror over
# the exec wrapper, `rw status --json`.

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox
# shellcheck source=../scripts/roots.sh
source "$RW_PLUGIN/scripts/roots.sh"

ce="$HOME/Developer/content-engine"
mkdir -p "$ce/wt-a/src/deep" "$ce/wt-b" "$HOME/Developer/idol-app/scripts" "$HOME/Developer/other"

new_record() { # root_local owner
  local rel id
  rel="$(rw_root_rel "$1")"
  id="$(rw_root_id "$rel")"
  rw_owned_record_write "$id" "$(rw_record_new "$id" "$rel" "$1" plain fakeworker "/w/$rel" | jq -c --arg o "$2" '.owner = $o')"
  printf '%s\n' "$id"
}

id_ce="$(new_record "$ce" worker)"
id_a="$(new_record "$ce/wt-a" worker)"
new_record "$HOME/Developer/idol-app" focus >/dev/null

rec="$(rw_owned_record_read "$id_a")"
eq "record round-trips root_rel" "$(jq -r .root_rel <<<"$rec")" "Developer/content-engine/wt-a"
eq "record has the C1 field set" "$(jq -c 'keys' <<<"$rec")" \
  '["endpoints","focus_machine_id","kind","owner","root_id","root_local","root_rel","since","worker","worker_root"]'
check "record file is private (0600)" bash -c "[ \"\$(stat -f %Lp '$(rw_owned_record_file "$id_a")' 2>/dev/null || stat -c %a '$(rw_owned_record_file "$id_a")')\" = 600 ]"

eq "path at a root resolves to it" "$(rw_owned_root_for_path "$ce/wt-a")" "$id_a"
eq "deep path: longest (nearest) root wins" "$(rw_owned_root_for_path "$ce/wt-a/src/deep")" "$id_a"
eq "sibling falls back to the enclosing root" "$(rw_owned_root_for_path "$ce/wt-b")" "$id_ce"
rw_owned_root_for_path "$HOME/Developer/idol-app/scripts" >/dev/null
eq "a focus-owned record never matches (exit 1)" "$?" "1"
rw_owned_root_for_path "$HOME/Developer/other" >/dev/null
eq "an unowned path does not match (exit 1)" "$?" "1"
rw_owned_root_for_path "$ce-extra" >/dev/null 2>&1
eq "a name-prefix sibling (content-engine-extra) does not match" "$?" "1"

eq "overlap: a root inside a remote root" "$(rw_owned_overlap "$ce/wt-b")" "$ce"
eq "overlap: a root enclosing a remote root" "$(rw_owned_overlap "$HOME/Developer" | head -n1)" "$ce"
rw_owned_overlap "$HOME/Developer/other" >/dev/null
eq "overlap: unrelated root" "$?" "1"

rw_record_add_endpoint "$id_a" aaaa1111
rw_record_add_endpoint "$id_a" bbbb2222
rw_record_add_endpoint "$id_a" aaaa1111
eq "endpoints are a set" "$(rw_owned_record_read "$id_a" | jq -c .endpoints)" '["aaaa1111","bbbb2222"]'
rw_record_remove_endpoint "$id_a" aaaa1111
eq "endpoint removal" "$(rw_owned_record_read "$id_a" | jq -c .endpoints)" '["bbbb2222"]'

eq "status --json lists every record" "$("$RW_PLUGIN/scripts/rw" status --json | jq -r 'map(.root_rel) | join(",")')" \
  "Developer/content-engine,Developer/content-engine/wt-a,Developer/idol-app"

rw_owned_record_remove "$id_ce"
check "record removal deletes the directory" test ! -e "$(rw_owned_record_dir "$id_ce")"

rw_held_mark fakeworker "$id_a" "Developer/content-engine/wt-a" "/w/x"
eq "held index names the worker" "$(rw_held_workers "$id_a")" "fakeworker"
rw_held_unmark fakeworker "$id_a"
eq "held index unmark" "$(rw_held_workers "$id_a")" ""

# Worker mirror over the (fake) ssh exec wrapper, into the worker override.
printf 'a\t1\t2\n' >"$(rw_owned_record_dir "$id_a")/manifest.worker.tsv"
check "mirror push succeeds" rw_mirror_push_from_record fakeworker "$FAKE_WORKER_HOME" "$id_a"
mirror="$TMUX_REMOTE_WORKSPACES_WORKER_STATE_DIR/owned/$id_a"
eq "mirror record's root_local is the worker path" "$(jq -r .root_local "$mirror/record.json")" "/w/Developer/content-engine/wt-a"
eq "mirror carries the manifest" "$(cat "$mirror/manifest.worker.tsv")" "$(printf 'a\t1\t2')"
check "focus state dir untouched by the mirror" test ! -e "$TMUX_REMOTE_WORKSPACES_STATE_DIR/owned/$id_a/.incoming"
rw_worker_mirror_fetch fakeworker "$FAKE_WORKER_HOME" "$id_a" manifest.worker.tsv "$SANDBOX/fetched.tsv"
eq "mirror fetch returns the file" "$(cat "$SANDBOX/fetched.tsv")" "$(printf 'a\t1\t2')"
rw_worker_mirror_fetch fakeworker "$FAKE_WORKER_HOME" "$id_a" manifest.focus.tsv "$SANDBOX/absent.tsv"
check "mirror fetch of an absent file leaves no file" test ! -e "$SANDBOX/absent.tsv"
touch "$FAKE_SSH_DOWN"
rw_worker_mirror_fetch fakeworker "$FAKE_WORKER_HOME" "$id_a" manifest.worker.tsv "$SANDBOX/x.tsv"
eq "mirror fetch from an unreachable worker returns 6" "$?" "6"
rm -f "$FAKE_SSH_DOWN"

check "no command reached tmux beyond the stub" test ! -s "$FAKE_TMUX_LOG"
finish
