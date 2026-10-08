#!/usr/bin/env python3
"""Assemble all workspace pane records in one process."""

from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
sys.dont_write_bytecode = True


def load_agent_command(script_dir):
    spec = importlib.util.spec_from_file_location("agent_command", script_dir / "agent_command.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def process_exists(value):
    try:
        os.kill(int(value), 0)
        return True
    except (ValueError, OSError):
        return False


def parse_time(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return -1


def is_socket(path):
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except OSError:
        return False


def main():
    captured_path, output_path, failures_path, state_dir, identity, started, capture_agents, capture_nvim = sys.argv[1:]
    agent_command = load_agent_command(Path(__file__).resolve().parent)
    failures = set(Path(failures_path).read_text().splitlines()) if Path(failures_path).exists() else set()
    server_key = identity.replace(":", "-", 1)
    records = []
    with open(captured_path, encoding="utf-8") as stream:
        for line in stream:
            source = json.loads(line)
            numeric = [source.get(key) for key in ("window_index", "pane_index", "pane_pid")]
            cursor_text = source.get("pending_cursor") or "0"
            if any(not isinstance(value, str) or not value.isascii() or not value.isdigit() for value in [*numeric, cursor_text]):
                raise SystemExit(f"non-numeric pane metadata for {source.get('pane_id', 'unknown')}")
            window_index, pane_index, pane_pid = map(int, numeric)
            pending_cursor = int(cursor_text)
            pane_id = source["pane_id"]
            logical_id = f"{source['session_name']}:{window_index}.{pane_index}"
            last_command = source["last_command"]
            pending = source["pending_buffer"]
            selected = pending if pending else last_command
            selected_source = "pending-buffer" if pending else "last-command"
            ignored_pending = agent_command.is_ignored(pending)
            ignored_last = agent_command.is_ignored(last_command)
            if ignored_last:
                last_command = ""
            if ignored_pending:
                pending = ""
                pending_cursor = 0
            if ignored_pending or (not pending and ignored_last):
                selected = ""
                selected_source = "ignored-agent"
            nvim = None
            if not pending and not ignored_pending and capture_nvim == "1" and pane_id not in failures and source["nvim_session"] \
                    and is_socket(source["nvim_server"]) and process_exists(source["nvim_owner"]):
                session = source["nvim_session"].replace("'", "'\"'\"'")
                selected = f"nvim -S '{session}'"
                selected_source = "neovim-session"
                nvim = {"server": source["nvim_server"], "session_file": source["nvim_session"],
                        "active_file": source["nvim_active_file"]}
            agent = None
            agent_error = ""
            inferred = agent_command.infer(last_command)
            if capture_agents == "1" and inferred and selected_source == "last-command":
                number = pane_id.removeprefix("%")
                scoped = Path(state_dir) / "agents" / f"server-{server_key}" / f"pane-{number}.json"
                legacy = Path(state_dir) / "agents" / f"pane-{number}.json"
                state_file = scoped if scoped.is_file() else legacy
                data = None
                try:
                    data = json.loads(state_file.read_text())
                except (OSError, UnicodeError, json.JSONDecodeError):
                    pass
                valid = bool(isinstance(data, dict) and data.get("pane_id") == pane_id and data.get("tool") == inferred
                             and isinstance(data.get("session_id"), str) and data["session_id"])
                if valid:
                    if "pane_identity" in data and data["pane_identity"] is not None and data["pane_identity"] is not False:
                        valid = data["pane_identity"] == f"{identity}:{pane_pid}"
                    else:
                        valid = parse_time(data.get("recorded_at")) >= int(started) and data.get("cwd") == source["pane_path"]
                if valid:
                    try:
                        selected = agent_command.resume(inferred, data["session_id"], last_command)
                        selected_source = f"{inferred}-session"
                        agent = {key: data.get(key) for key in
                                 ("tool", "session_id", "session_file", "cwd", "model", "recorded_at", "pane_identity")}
                        agent["cwd"] = agent["cwd"] or ""
                        agent["model"] = agent["model"] or ""
                    except ValueError:
                        agent_error = "could not construct exact focus resume"
                else:
                    agent_error = f"missing, invalid or stale {inferred} session hook record"
                if agent_error:
                    selected = ""
                    selected_source = "agent-session-unavailable"
            records.append({"logical_id": logical_id, "session_name": source["session_name"],
                "window_index": window_index, "pane_index": pane_index, "pane_id": pane_id,
                "pane_pid": pane_pid, "cwd": source["pane_path"], "title": source["pane_title"],
                "current_command": source["pane_command"], "last_command": last_command,
                "pending_buffer": pending, "pending_cursor": pending_cursor,
                "selected_command": selected, "selected_source": selected_source,
                "agent": agent, "agent_capture_error": agent_error, "neovim": nvim})
    with open(output_path, "w", encoding="utf-8") as stream:
        for record in records:
            json.dump(record, stream, ensure_ascii=False, separators=(",", ":"))
            stream.write("\n")


if __name__ == "__main__":
    main()
