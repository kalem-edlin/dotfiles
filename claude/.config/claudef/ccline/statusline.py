#!/usr/bin/env python3
"""Augment ccline with model effort and a live subscription-usage segment.

ccline 1.1.2 cannot parse the usage API while no five-hour window is open
(five_hour is null), so it keeps printing its last cache (seen 2026-11-18:
a 3% from 2026-10-31). This wrapper redraws that segment from the live API:
the percent is the five-hour window's, or the weekly one's when no five-hour
window is open, then the five-hour countdown, then the weekly reset
(month-day-hour, local time).
"""

from __future__ import annotations

from datetime import datetime, timezone
import math
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

CACHE_SECONDS = 180
CACHE_PATH = Path.home() / ".claude/ccline/.api_usage_resets_cache.json"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
# The pie glyphs pif's status line uses (empty, then eighths).
PIE_EMPTY = "\U000f0766"
PIE_SLICES = [chr(code) for code in range(0xF0A9E, 0xF0AA6)]
# ccline's usage segment: icon, "N%", "· reset", each in its own color span.
USAGE_SEGMENT = re.compile(
    rb"(\x1b\[[0-9;]*m)[^\x1b]*(\x1b\[0m )(\x1b\[[0-9;]*m)\d+(?:\.\d+)?%"
    rb"(\x1b\[0m )(\x1b\[[0-9;]*m)\xc2\xb7 [^\x1b]*(\x1b\[0m)"
)


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


def parse_time(value: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except (AttributeError, ValueError):
        return None


def pie_icon(percent: float) -> str:
    if percent <= 0:
        return PIE_EMPTY
    index = max(1, min(8, math.ceil(percent / 100 * 8)))
    return PIE_SLICES[index - 1]


def usage_text(usage: dict | None) -> tuple[str, str] | None:
    """The segment's icon and text, or None when the API gave no window."""
    if not isinstance(usage, dict):
        return None
    five_hour = usage.get("five_hour") or {}
    seven_day = usage.get("seven_day") or {}
    window = five_hour if five_hour.get("utilization") is not None else seven_day
    percent = window.get("utilization")
    if percent is None:
        return None
    parts = []
    five_hour_reset = parse_time(five_hour.get("resets_at"))
    if five_hour_reset:
        minutes = max(0, int((five_hour_reset - datetime.now(timezone.utc)).total_seconds() // 60))
        parts.append(f"{minutes // 60}h" if minutes >= 60 else f"{minutes}m")
    weekly_reset = parse_time(seven_day.get("resets_at"))
    if weekly_reset:
        local = weekly_reset.astimezone()
        parts.append(f"{local.month}-{local.day}-{local.hour}")
    text = f"{round(percent)}%"
    if parts:
        text += f" · {' '.join(parts)}"
    return pie_icon(percent), text


def replace_usage(output: bytes, usage: dict | None) -> bytes:
    rendered = usage_text(usage)
    match = USAGE_SEGMENT.search(output)
    if not rendered or not match:
        return output
    icon, text = rendered
    percent, _, rest = text.partition(" ")
    icon_color, gap, text_color, gap2, rest_color, close = match.groups()
    segment = icon_color + icon.encode() + gap + text_color + percent.encode()
    segment += (gap2 + rest_color + rest.encode() + close) if rest else close
    return output[: match.start()] + segment + output[match.end():]


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
        # The usage segment is optional. A surprise in the usage API must not
        # blank the status line, because nothing has been printed yet.
        try:
            output = replace_usage(output, read_usage())
        except Exception as error:
            print(f"statusline: {error!r}", file=sys.stderr)

    sys.stdout.buffer.write(output)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
