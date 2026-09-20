#!/usr/bin/env python3
"""Augment ccline with model effort and the five-hour reset countdown."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

CACHE_SECONDS = 180
CACHE_PATH = Path.home() / ".claude/ccline/.api_usage_resets_cache.json"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USAGE_ICON = "󰪞".encode()


def read_credentials() -> dict | None:
    credentials_file = Path.home() / ".claude/.credentials.json"
    try:
        if credentials_file.is_file():
            return json.loads(credentials_file.read_text())
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=2,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None


def read_usage() -> dict | None:
    try:
        cached = json.loads(CACHE_PATH.read_text())
        if time.time() - CACHE_PATH.stat().st_mtime < CACHE_SECONDS:
            return cached
    except (OSError, json.JSONDecodeError):
        cached = None

    credentials = read_credentials()
    token = credentials and credentials.get("claudeAiOauth", {}).get("accessToken")
    if not token:
        return cached

    request = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            usage = json.load(response)
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        temporary = CACHE_PATH.with_suffix(".tmp")
        temporary.write_text(json.dumps(usage))
        os.chmod(temporary, 0o600)
        temporary.replace(CACHE_PATH)
        return usage
    except (OSError, ValueError):
        return cached


def reset_countdown(usage: dict | None) -> str | None:
    resets_at = usage and usage.get("five_hour", {}).get("resets_at")
    if not resets_at:
        return None
    try:
        reset = datetime.fromisoformat(resets_at.replace("Z", "+00:00"))
        minutes = max(
            0,
            int((reset - datetime.now(timezone.utc)).total_seconds() // 60),
        )
        return f"{minutes // 60}h" if minutes >= 60 else f"{minutes}m"
    except (TypeError, ValueError):
        return None


def add_reset_countdown(output: bytes, countdown: str | None) -> bytes:
    if not countdown:
        return output
    icon_at = output.find(USAGE_ICON)
    dot_at = output.find("· ".encode(), icon_at)
    if icon_at < 0 or dot_at < 0:
        return output
    insert_at = dot_at + len("· ".encode())
    return output[:insert_at] + f"{countdown} ".encode() + output[insert_at:]


def main() -> int:
    payload = sys.stdin.buffer.read()
    result = subprocess.run(
        ["ccline"],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    output = result.stdout
    if result.returncode == 0:
        try:
            status = json.loads(payload)
            model = status.get("model", {}).get("display_name")
            effort = status.get("effort", {}).get("level")
            if model and effort:
                output = output.replace(
                    model.encode(), f"{model} ({effort})".encode(), 1
                )
        except (AttributeError, json.JSONDecodeError):
            pass
        output = add_reset_countdown(output, reset_countdown(read_usage()))

    sys.stdout.buffer.write(output)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
