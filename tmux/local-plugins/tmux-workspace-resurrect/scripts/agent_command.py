#!/usr/bin/env python3
"""Infer an agent launcher and build a safe, focus-profile resume command."""

import shlex
import sys
import re


_NAMES = {
    "claude": {"claude", "claudef"},
    "pi": {"pi", "pif"},
    "codex": {"codex", "codexf"},
}
_VALUE_OPTIONS = {
    "claude": {"--model", "--permission-mode", "--output-format", "--add-dir"},
    "pi": {"--model", "--provider", "--thinking", "--mode", "--append-system-prompt"},
}


def _tokens(command):
    command = command.rstrip("\r\n")
    if any(c in command for c in "\n\r;&|<>`$"):
        return None
    try:
        return shlex.split(command, comments=False, posix=True)
    except ValueError:
        return None


def _command_parts(command):
    """Parse either one launcher command or the specifically supported cd chain."""
    command = command.rstrip("\r\n")
    prefix = None
    match = re.fullmatch(r"cd\s+(--\s+)?(.+?)\s+&&\s*(.+)", command)
    if match:
        path_text, tail = match.group(2), match.group(3)
        # The cd operand must be one literal shell word. No expansions, escapes
        # or shell syntax are evaluated; shlex only decodes its quoting.
        if any(c in path_text for c in "$`;&|<>\n\r"):
            return None, None
        try:
            path_tokens = shlex.split(path_text, comments=False, posix=True)
        except ValueError:
            return None, None
        if len(path_tokens) != 1:
            return None, None
        prefix = "cd " + ("-- " if match.group(1) else "") + shlex.quote(path_tokens[0]) + " && "
        command = tail
    return prefix, _tokens(command)


def _launcher(tokens):
    """Return tool and invocation args only when argv starts with a launcher."""
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in ("command", "exec", "noglob"):
            i += 1
            continue
        if token == "env":
            i += 1
            while i < len(tokens) and (tokens[i].startswith("-") or _assignment(tokens[i])):
                if tokens[i] in ("-u", "--unset", "-C", "--chdir"):
                    i += 1
                i += 1
            continue
        if _assignment(token):
            i += 1
            continue
        name = token.rsplit("/", 1)[-1]
        for tool, names in _NAMES.items():
            if name in names:
                args = tokens[i + 1:]
                return tool, args
        return None, None
    return None, None


def _assignment(token):
    return "=" in token and token.split("=", 1)[0].replace("_", "a").isalnum() and not token.startswith("=")


def is_ignored(command):
    """Recognize Codex launchers, including chains and unfinished shell input.

    Read incrementally so an unclosed prompt quote cannot hide its launcher.
    Plain mentions such as `echo codex` are not launch commands.
    """
    if not isinstance(command, str):
        return False
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    tokens = []
    try:
        for token in lexer:
            if token and all(char in ";&|()<>\n" for char in token):
                tokens = []
                continue
            tokens.append(token)
            if _launcher(tokens)[0] == "codex":
                return True
    except ValueError:
        pass
    return False


def infer(command):
    _, tokens = _command_parts(command)
    return _launcher(tokens)[0] if tokens else None


def resume(tool, session_id, launch_command):
    if tool not in _VALUE_OPTIONS or not session_id or session_id.startswith("-") or any(
        ord(char) < 32 or ord(char) == 127 for char in session_id
    ):
        raise ValueError("tool and a safe, non-empty session id are required")
    prefix, tokens = _command_parts(launch_command)
    detected, args = _launcher(tokens or [])
    if detected != tool or args is None:
        args = []

    # Keep only confidently understood option/value pairs. Positional prompts,
    # old selectors and unknown syntax fall back to the canonical launcher.
    kept = []
    i = 0
    valid = True
    while i < len(args):
        arg = args[i]
        if arg in ("--",):
            valid = False
            break
        if tool == "claude" and arg == "--resume":
            i += 2 if i + 1 < len(args) and not args[i + 1].startswith("-") else 1
            continue
        if tool == "claude" and arg.startswith("--resume="):
            i += 1
            continue
        if tool == "claude" and arg in ("--continue", "--last", "-c"):
            i += 1
            continue
        if tool == "claude" and arg in ("-r", "--session-id"):
            i += 2 if i + 1 < len(args) and not args[i + 1].startswith("-") else 1
            continue
        if tool == "claude" and arg.startswith("--session-id="):
            i += 1
            continue
        if tool == "pi" and arg in ("--session", "--resume"):
            i += 2 if i + 1 < len(args) and not args[i + 1].startswith("-") else 1
            continue
        if tool == "pi" and arg.startswith("--session="):
            i += 1
            continue
        if tool == "pi" and arg in ("--continue", "-c", "-r"):
            i += 1
            continue
        if arg.startswith("-"):
            key, eq, value = arg.partition("=")
            if key in _VALUE_OPTIONS[tool]:
                if eq:
                    kept.append(arg)
                elif i + 1 < len(args) and not args[i + 1].startswith("-"):
                    kept.extend((arg, args[i + 1]))
                    i += 1
                else:
                    valid = False
                    break
            elif arg in {"--verbose", "--debug", "--no-color", "--full-auto", "--dangerously-bypass-approvals-and-sandbox"}:
                kept.append(arg)
            else:
                valid = False
                break
        else:
            valid = False  # Never replay a task prompt or arbitrary positional arg.
            break
        i += 1

    if not valid:
        kept = []
    if tool == "claude":
        argv = ["claudef", *kept, "--resume", session_id]
    else:
        argv = ["pif", *kept, "--session", session_id]
    return (prefix or "") + shlex.join(argv)


def main(argv):
    if len(argv) == 3 and argv[1] == "infer":
        print(infer(argv[2]) or "")
        return 0
    if len(argv) == 5 and argv[1] == "resume":
        try:
            print(resume(argv[2], argv[3], argv[4]))
            return 0
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
    print("usage: agent_command.py infer COMMAND | resume TOOL ID COMMAND", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
