#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  workspace_log "save failed: jq and python3 are required for exact agent resumes"
  exit 1
fi

state_dir="$(workspace_state_dir)"
resurrect_dir="$(workspace_resurrect_dir)"
sidecar="$(workspace_sidecar_file)"
# common.sh helpers and per-pane agent lookups must reuse this resolved path;
# otherwise each lookup asks the tmux server for the same environment value.
export TMUX_WORKSPACE_RESURRECT_STATE_DIR="$state_dir"
workspace_ensure_private_dir "$state_dir"
workspace_ensure_private_dir "$resurrect_dir"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-workspace-resurrect-save.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
panes_jsonl="$work_dir/panes.jsonl"
treemux_jsonl="$work_dir/treemux.jsonl"
: >"$panes_jsonl"
: >"$treemux_jsonl"

# Read configuration once per save. These values used to run jq for every
# pane, even though config.json cannot change the choice for the current run.
capture_neovim_sessions=0
capture_agent_sessions=0
capture_treemux=0
workspace_config_bool '.capture.neovim_sessions' && capture_neovim_sessions=1
workspace_config_bool '.capture.agent_sessions' && capture_agent_sessions=1
workspace_config_bool '.capture.treemux' && capture_treemux=1
neovim_rpc_timeout="$(jq -er '.neovim_rpc_timeout_seconds | numbers' "$WORKSPACE_CONFIG_FILE" 2>/dev/null || echo 3)"
case "$neovim_rpc_timeout" in
  '' | *[!0-9]*) neovim_rpc_timeout=3 ;;
esac
[ "$neovim_rpc_timeout" -gt 0 ] || neovim_rpc_timeout=3
server_identity="$(tmux display-message -p '#{pid}:#{start_time}')"
server_started="${server_identity#*:}"

clear_neovim_registration() {
  local pane_id="$1" expected_owner="$2" current_owner option
  current_owner="$(tmux show-option -pt "$pane_id" -qv @workspace-nvim-owner-pid 2>/dev/null || true)"
  [ "$current_owner" = "$expected_owner" ] || return 0
  for option in \
    @workspace-nvim-owner-pid \
    @workspace-nvim-server \
    @workspace-nvim-session \
    @workspace-nvim-active-file; do
    tmux set-option -pqu -t "$pane_id" "$option" 2>/dev/null || true
  done
}

process_running() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}

force_neovim_session_save() {
  local pane_id="$1" server="$2" owner="$3"
  local rpc_pid rpc_started rpc_result="$work_dir/nvim-${1#%}.result"
  case "$owner" in
    '' | *[!0-9]*)
      [ -z "$server" ] || clear_neovim_registration "$pane_id" "$owner"
      return 1
      ;;
  esac
  if ! kill -0 "$owner" 2>/dev/null || [ ! -S "$server" ]; then
    workspace_log "save: cleared stale Neovim registration for $pane_id (owner=$owner)"
    clear_neovim_registration "$pane_id" "$owner"
    return 1
  fi
  command -v nvim >/dev/null 2>&1 || return 1

  nvim --server "$server" --remote-expr \
    'luaeval("require(\"tmux_workspace_resurrect\").save()")' \
    >"$rpc_result" 2>/dev/null &
  rpc_pid=$!
  rpc_started=$SECONDS
  while process_running "$rpc_pid"; do
    if [ $((SECONDS - rpc_started)) -ge "$neovim_rpc_timeout" ]; then
      kill -TERM "$rpc_pid" 2>/dev/null || true
      sleep 0.2
      if kill -0 "$rpc_pid" 2>/dev/null; then
        kill -KILL "$rpc_pid" 2>/dev/null || true
      fi
      wait "$rpc_pid" 2>/dev/null || true
      workspace_log "save: Neovim RPC timed out after ${neovim_rpc_timeout}s for $pane_id; continuing without it"
      clear_neovim_registration "$pane_id" "$owner"
      return 1
    fi
    sleep 0.1
  done
  if ! wait "$rpc_pid"; then
    workspace_log "save: Neovim RPC failed for $pane_id; continuing without it"
    return 1
  fi
  if [ "$(<"$rpc_result")" != "true" ]; then
    workspace_log "save: Neovim refused to publish a session for $pane_id"
    return 2
  fi
  return 0
}

# tmux's q: modifier still emits literal newlines on 3.7b. Build one bulk
# query with an unpredictable marker around every value, then decode it to
# JSON. This preserves option bytes without aligning independent line-based
# queries and avoids one tmux process per pane/field.
captured_panes="$work_dir/captured-panes.jsonl"
if ! python3 - "$captured_panes" <<'PY'
import json
import secrets
import subprocess
import sys

output = sys.argv[1]
fields = {
    "pane_id": "#{pane_id}",
    "session_name": "#{session_name}",
    "window_index": "#{window_index}",
    "pane_index": "#{pane_index}",
    "pane_pid": "#{pane_pid}",
    "pane_command": "#{pane_current_command}",
    "pane_path": "#{pane_current_path}",
    "pane_title": "#{pane_title}",
    "nvim_server": "#{@workspace-nvim-server}",
    "nvim_owner": "#{@workspace-nvim-owner-pid}",
    "nvim_session": "#{@workspace-nvim-session}",
    "nvim_active_file": "#{@workspace-nvim-active-file}",
    "last_command": "#{@workspace-last-command}",
    "pending_buffer": "#{@workspace-pending-buffer}",
    "pending_cursor": "#{@workspace-pending-cursor}",
}
marker = "__TWR_" + secrets.token_hex(24) + "__"
parts = []
for name, value in fields.items():
    parts.extend((marker, name, marker, value))
parts.extend((marker, "record_end", marker))
raw = subprocess.run(
    ["tmux", "list-panes", "-a", "-F", "".join(parts)],
    check=True, stdout=subprocess.PIPE,
).stdout.decode("utf-8", "surrogateescape")

tokens = raw.split(marker)
records = []
record = {}
i = 1
while i + 1 < len(tokens):
    name, value = tokens[i], tokens[i + 1]
    i += 2
    if name == "record_end":
        # list-panes appends exactly one record-separating newline.
        if value != "\n":
            raise SystemExit("unexpected bytes after pane record terminator")
        if set(record) != set(fields):
            raise SystemExit("incomplete pane record from tmux")
        records.append(record)
        record = {}
    elif name in fields and name not in record:
        record[name] = value
    else:
        raise SystemExit("malformed or colliding pane capture marker")
if record or any(part for part in tokens[i:] if part.strip("\n")):
    raise SystemExit("trailing partial pane record from tmux")
pane_ids = [record["pane_id"] for record in records]
if not records or len(pane_ids) != len(set(pane_ids)):
    raise SystemExit("empty or duplicate pane-id coverage")
with open(output, "w", encoding="utf-8", errors="surrogateescape") as stream:
    for record in records:
        json.dump(record, stream, ensure_ascii=False)
        stream.write("\n")
PY
then
  workspace_log "save failed: could not capture a complete pane set"
  exit 1
fi

nvim_failures="$work_dir/nvim-failures"
: >"$nvim_failures"
if [ "$capture_neovim_sessions" -eq 1 ]; then
  nvim_candidates="$work_dir/nvim-candidates"
  if ! python3 - "$captured_panes" >"$nvim_candidates" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    pane = json.loads(line)
    for key in ("pane_id", "nvim_server", "nvim_owner"):
        sys.stdout.buffer.write(pane[key].encode("utf-8") + b"\0")
PY
  then
    workspace_log "save failed: could not prepare Neovim capture batch"
    exit 1
  fi
  while IFS= read -r -d '' pane_id && IFS= read -r -d '' nvim_server && IFS= read -r -d '' nvim_owner; do
    if force_neovim_session_save "$pane_id" "$nvim_server" "$nvim_owner"; then
      :
    else
      rpc_status=$?
      if [ "$rpc_status" -eq 2 ]; then
        printf 'workspace save: Neovim could not persist buffers in %s\n' "$pane_id" >&2
        exit 1
      fi
      printf '%s\n' "$pane_id" >>"$nvim_failures"
    fi
  done <"$nvim_candidates"

  # A successful RPC may publish a new editor-generation path. Refresh its
  # registration in one bulk query rather than saving the pre-RPC filename.
  python3 - "$captured_panes" "$nvim_failures" <<'PY'
import json, pathlib, secrets, subprocess, sys
path = pathlib.Path(sys.argv[1])
panes = [json.loads(line) for line in path.read_text().splitlines()]
failed = set(pathlib.Path(sys.argv[2]).read_text().splitlines())
fields = {"pane_id": "#{pane_id}", "nvim_server": "#{@workspace-nvim-server}",
          "nvim_owner": "#{@workspace-nvim-owner-pid}",
          "nvim_session": "#{@workspace-nvim-session}",
          "nvim_active_file": "#{@workspace-nvim-active-file}"}
marker = "__TWR_NVIM_" + secrets.token_hex(16) + "__"
parts = []
for name, value in fields.items():
    parts.extend((marker, name, marker, value))
parts.extend((marker, "end", marker))
raw = subprocess.check_output(["tmux", "list-panes", "-a", "-F", "".join(parts)], text=True)
tokens = raw.split(marker)
records, record = {}, {}
if tokens[0] or len(tokens) % 2 != 1:
    raise SystemExit("malformed Neovim registration capture")
for index in range(1, len(tokens), 2):
    name, value = tokens[index:index + 2]
    if name == "end":
        if value != "\n" or set(record) != set(fields) or record["pane_id"] in records:
            raise SystemExit("incomplete or duplicate Neovim registration")
        records[record["pane_id"]] = record
        record = {}
    elif name in fields and name not in record:
        record[name] = value
    else:
        raise SystemExit("malformed Neovim registration")
if record:
    raise SystemExit("partial Neovim registration")
for pane in panes:
    if pane["pane_id"] in failed:
        continue
    refreshed = records.get(pane["pane_id"])
    if refreshed is None or refreshed["nvim_owner"] != pane["nvim_owner"]:
        raise SystemExit("Neovim owner changed while saving")
    session = pathlib.Path(refreshed["nvim_session"])
    if not session.is_file() or session.stat().st_size == 0:
        raise SystemExit("Neovim acknowledged saving without publishing a session file")
    pane.update(refreshed)
path.write_text("".join(json.dumps(pane) + "\n" for pane in panes))
PY
fi

python3 "$SCRIPT_DIR/assemble_panes.py" "$captured_panes" "$panes_jsonl" "$nvim_failures" \
  "$state_dir" "$server_identity" "$server_started" "$capture_agent_sessions" "$capture_neovim_sessions"

# Capture all Treemux registrations in one tmux call, then resolve sidebar
# pane IDs from the already captured pane set.
if [ "$capture_treemux" -eq 1 ]; then
  python3 - "$panes_jsonl" "$treemux_jsonl" <<'PY'
import json, secrets, subprocess, sys
panes = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
logical = {pane["pane_id"]: pane["logical_id"] for pane in panes}
prefix = "@-treemux-registered-pane-"
marker = "__TWR_OPTIONS_" + secrets.token_hex(24) + "__"
registrations = {}
pane_ids = list(logical)
# tmux silently produces an empty display-message for very large formats.
# Eight registrations stay well below that limit even with long pane IDs.
for offset in range(0, len(pane_ids), 8):
    batch = pane_ids[offset:offset + 8]
    parts = []
    for pane_id in batch:
        formatted_id = pane_id.replace("%", "%%")
        parts.extend((marker, formatted_id, marker, "#{" + prefix + formatted_id + "}"))
    parts.append(marker)
    raw = subprocess.run(["tmux", "display-message", "-p", "-F", "".join(parts)],
                         check=True, stdout=subprocess.PIPE).stdout.decode("utf-8", "surrogateescape")
    tokens = raw.split(marker)
    if not tokens or tokens[0] or tokens[-1] != "\n" or len(tokens) != 2 * len(batch) + 2:
        raise SystemExit("malformed Treemux option capture")
    registrations.update(zip(tokens[1:-1:2], tokens[2:-1:2]))
with open(sys.argv[2], "w", encoding="utf-8", errors="surrogateescape") as output:
    for main_id, registration in registrations.items():
        sidebar_id, comma, args = registration.partition(",")
        if comma and main_id in logical and sidebar_id in logical:
            json.dump({"main_logical_id": logical[main_id],
                       "sidebar_logical_id": logical[sidebar_id], "args": args}, output)
            output.write("\n")
PY
fi

# Refuse to publish if panes appeared/disappeared during the capture, if a
# logical location was duplicated, or if any captured pane failed validation.
if ! python3 - "$captured_panes" "$panes_jsonl" <<'PY'
import json
import subprocess
import sys

captured = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
saved = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8")]
live = subprocess.run(
    ["tmux", "list-panes", "-a", "-F", "#{pane_id}"], check=True,
    stdout=subprocess.PIPE, text=True,
).stdout.splitlines()
captured_ids = [pane["pane_id"] for pane in captured]
saved_ids = [pane["pane_id"] for pane in saved]
logical_ids = [pane["logical_id"] for pane in saved]
if (sorted(live) != sorted(captured_ids) or saved_ids != captured_ids or
        len(logical_ids) != len(set(logical_ids))):
    raise SystemExit("pane coverage changed, is incomplete, or is duplicated")
PY
then
  workspace_log "save failed: incomplete pane logical-id coverage"
  exit 1
fi

snapshot=""
if [ -L "$resurrect_dir/last" ]; then
  snapshot="$(readlink "$resurrect_dir/last")"
elif [ -f "$resurrect_dir/last" ]; then
  snapshot="last"
fi

temp_sidecar="$(mktemp "$resurrect_dir/.workspace-state.XXXXXX")"
jq -n \
  --argjson version 1 \
  --arg saved_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg resurrect_snapshot "$snapshot" \
  --slurpfile panes "$panes_jsonl" \
  --slurpfile treemux "$treemux_jsonl" \
  '{
    version: $version,
    saved_at: $saved_at,
    resurrect_snapshot: $resurrect_snapshot,
    panes: $panes,
    pane_coverage: {
      expected_count: ($panes | length),
      captured_count: ($panes | length),
      complete: true,
      logical_ids_unique: true
    },
    agent_capture_errors: [$panes[] | select(.agent_capture_error != "") |
      {logical_id, error: .agent_capture_error}],
    treemux: $treemux
  }' >"$temp_sidecar"
chmod 0600 "$temp_sidecar"
mv "$temp_sidecar" "$sidecar"

workspace_log "saved $(jq '.panes | length' "$sidecar") pane records alongside ${snapshot:-unknown snapshot}"
