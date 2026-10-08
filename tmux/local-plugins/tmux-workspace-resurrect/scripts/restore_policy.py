#!/usr/bin/env python3
"""Choose whether a saved pane command may be executed during restoration."""

import importlib.util
import json
from pathlib import Path
import os
import shlex
import stat
import sys


SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("agent_command", SCRIPT_DIR / "agent_command.py")
AGENT_COMMAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AGENT_COMMAND)

SHELLS = {"zsh", "-zsh", "bash", "-bash", "fish", "sh", "dash"}
LAUNCHERS = {"claude": "claudef", "pi": "pif"}


def _regular_file(path):
    try:
        return stat.S_ISREG(Path(path).stat().st_mode)
    except (OSError, TypeError, ValueError):
        return False


def decide(record, config):
    """Return an execute decision only for a validated, running allowlist entry."""
    agent = record.get("agent")
    if (record.get("selected_source") in {"codex-session", "ignored-agent"} or
            (isinstance(agent, dict) and agent.get("tool") == "codex") or
            any(AGENT_COMMAND.is_ignored(record.get(key)) for key in
                ("selected_command", "pending_buffer", "current_command"))):
        return {"action": "ignore", "command": ""}

    queued = {"action": "queue", "command": record.get("selected_command", "")}
    if config.get("restore_mode") != "whitelist":
        return queued

    policy = config.get("restore_whitelist")
    names = policy.get("names", []) if isinstance(policy, dict) else []
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        return queued

    # Pending input represents an unfinished user edit. It is never a launch
    # request, even when its text happens to look like an allowed command.
    source = record.get("selected_source")
    if source == "pending-buffer" or record.get("pending_buffer"):
        return queued

    # A resume record can survive after the program exits. A shell (or absent)
    # current process means the tool was not running at save time.
    current = record.get("current_command")
    current_name = os.path.basename(current) if isinstance(current, str) else ""
    if not current_name or current_name in SHELLS:
        return queued

    if isinstance(agent, dict):
        tool = agent.get("tool")
        session_id = agent.get("session_id")
        if (source != f"{tool}-session" or tool not in LAUNCHERS or
                LAUNCHERS[tool] not in names or not isinstance(session_id, str)):
            return queued
        if AGENT_COMMAND.infer(record.get("selected_command", "")) != tool:
            return queued
        try:
            command = AGENT_COMMAND.resume(tool, session_id, record.get("selected_command", ""))
        except (TypeError, ValueError):
            return queued
        return {"action": "execute", "command": command,
                "key": f"{tool}:{session_id}"}

    if source == "neovim-session" and "nvim" in names:
        nvim = record.get("neovim")
        path = nvim.get("session_file") if isinstance(nvim, dict) else None
        if not isinstance(path, str) or not path or not _regular_file(path):
            return queued
        if current_name != "nvim":
            return queued
        command = "nvim -S " + shlex.quote(path)
        try:
            saved_argv = shlex.split(record.get("selected_command", ""), comments=False, posix=True)
        except (TypeError, ValueError):
            return queued
        # Accept quoting differences, but never an extra option or shell word.
        if saved_argv != ["nvim", "-S", path]:
            return queued
        return {"action": "execute", "command": command,
                "key": f"nvim:{path}"}

    return queued


def main(argv):
    if len(argv) != 3:
        print("usage: restore_policy.py RECORD_JSON CONFIG_JSON", file=sys.stderr)
        return 2
    try:
        record = json.loads(argv[1])
        config = json.loads(argv[2])
        if not isinstance(record, dict) or not isinstance(config, dict):
            raise ValueError
    except (json.JSONDecodeError, ValueError):
        return 2
    print(json.dumps(decide(record, config), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
