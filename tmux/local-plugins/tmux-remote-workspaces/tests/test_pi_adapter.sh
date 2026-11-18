#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Item 4: two pi agents in one root each resume THEIR session. export,
# install and resume-cmd carry the exact transcript (path or header id),
# never "the newest transcript in the project".

set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rw_test_sandbox

PI="$RW_PLUGIN/libexec/adapters/pi"
proj="$HOME/Developer/two-agents"
mkdir -p "$proj"
sessions="$HOME/.pi/agent/sessions"
mkdir -p "$sessions"
id_a="01aaaaaa-0000-7000-8000-00000000000a"
id_b="01bbbbbb-0000-7000-8000-00000000000b"
printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-11-01T10:00:00.000Z","cwd":"%s"}\n{"type":"message","n":"A"}\n' "$id_a" "$proj" \
  >"$sessions/2026-11-01T10-00-00-000Z_$id_a.jsonl"
printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-11-02T10:00:00.000Z","cwd":"%s"}\n{"type":"message","n":"B"}\n' "$id_b" "$proj" \
  >"$sessions/2026-11-02T10-00-00-000Z_$id_b.jsonl"
touch "$sessions/2026-11-02T10-00-00-000Z_$id_b.jsonl" # B is the newest

# Handoff direction: export A by its local path, install on the worker.
"$PI" export --session-id "$sessions/2026-11-01T10-00-00-000Z_$id_a.jsonl" --project-path "$proj" --out "$SANDBOX/xa" >/dev/null 2>&1
eq "export by path takes exactly that transcript" "$(tail -n1 "$SANDBOX/xa/session.jsonl")" '{"type":"message","n":"A"}'
eq "export manifest carries the header id" "$(jq -r .session_id "$SANDBOX/xa/manifest.json")" "$id_a"
"$PI" export --session-id "$sessions/2026-11-02T10-00-00-000Z_$id_b.jsonl" --project-path "$proj" --out "$SANDBOX/xb" >/dev/null 2>&1
wproj="$FAKE_WORKER_HOME/Developer/two-agents"
mkdir -p "$wproj"
"$PI" install --snapshot "$SANDBOX/xa" --dest-path "$wproj" --worker fakeworker >/dev/null 2>&1
"$PI" install --snapshot "$SANDBOX/xb" --dest-path "$wproj" --worker fakeworker >/dev/null 2>&1

# resume-cmd for A, run on the "worker": it must open A, not the newer B.
cmd_a="$("$PI" resume-cmd --dest-path "$wproj" --session-id "$id_a")"
# Turn `... && pif --session X` into `... && printf '%s\n' X`.
show_arg=' && printf "%s\n" '
resolve_on_worker() { # print the --session argument the command would pass
  local c="${1/ && pif --session /$show_arg}"
  (cd "$FAKE_WORKER_HOME" && HOME="$FAKE_WORKER_HOME" bash -c "$c")
}
got="$(resolve_on_worker "$cmd_a")"
check "resume-cmd for A resolves A's installed transcript" bash -c "[[ '$got' == *_$id_a.jsonl ]]"
got="$(resolve_on_worker "$("$PI" resume-cmd --dest-path "$wproj" --session-id "$id_b")")"
check "resume-cmd for B resolves B's installed transcript" bash -c "[[ '$got' == *_$id_b.jsonl ]]"
check "installed header cwd is the worker path" bash -c "head -n1 \"\$(ls '$FAKE_WORKER_HOME'/.pi/agent/sessions/*/*_$id_a.jsonl)\" | jq -e --arg c '$wproj' '.cwd == \$c' >/dev/null"

# Hand-back direction: export A from the worker by its id.
"$PI" export --session-id "$id_a" --project-path "$wproj" --out "$SANDBOX/ra" --worker fakeworker >/dev/null 2>&1
eq "export from the worker by id takes exactly A" "$(tail -n1 "$SANDBOX/ra/session.jsonl")" '{"type":"message","n":"A"}'
"$PI" export --session-id "01cccccc-0000-7000-8000-00000000000c" --project-path "$wproj" --out "$SANDBOX/rc" --worker fakeworker >/dev/null 2>&1
eq "an unknown id is exit 4, never the newest transcript" "$?" "4"

# A local path that exists is used as is (the rollback resume on the laptop).
got="$("$PI" resume-cmd --dest-path "$proj" --session-id "$sessions/2026-11-01T10-00-00-000Z_$id_a.jsonl")"
c="${got/ && pif --session /$show_arg}"
eq "resume-cmd with an existing path opens that path" "$(cd "$HOME" && bash -c "$c")" "$sessions/2026-11-01T10-00-00-000Z_$id_a.jsonl"

finish
