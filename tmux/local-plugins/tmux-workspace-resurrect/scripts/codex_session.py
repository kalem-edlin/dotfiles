#!/usr/bin/env python3
"""Compatibility helpers: Codex is excluded from workspace resurrection."""


def inspect(pane_pid, pane_path):
    """Never inspect processes or rollouts for an excluded agent."""
    return "ignored", None


def recover(pane_pid, pane_path):
    """Never return a resumable Codex session."""
    return None
