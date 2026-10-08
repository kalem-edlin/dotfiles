#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "codex_session.py"
SPEC = importlib.util.spec_from_file_location("codex_session", MODULE_PATH)
CODEX_SESSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CODEX_SESSION)


class CodexSessionTests(unittest.TestCase):
    def test_codex_is_ignored_without_process_or_rollout_discovery(self):
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("must not inspect Codex")):
            self.assertEqual(CODEX_SESSION.inspect(100, "/work"), ("ignored", None))
            self.assertIsNone(CODEX_SESSION.recover(100, "/work"))


if __name__ == "__main__":
    unittest.main()
