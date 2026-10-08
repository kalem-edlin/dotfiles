#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import socket
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLER = ROOT / "scripts" / "assemble_panes.py"


class AssemblePanesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.identity = "100:200"
        self.started = "200"

    def tearDown(self):
        self.temp.cleanup()

    def pane(self, number=1, command="claudef --model sonnet", pending=""):
        return {"pane_id": f"%{number}", "session_name": "test", "window_index": "0",
                "pane_index": str(number - 1), "pane_pid": str(300 + number),
                "pane_command": "zsh", "pane_path": "/work", "pane_title": "title",
                "nvim_server": "", "nvim_owner": "", "nvim_session": "",
                "nvim_active_file": "", "last_command": command,
                "pending_buffer": pending, "pending_cursor": "0"}

    def hook_path(self, pane):
        path = self.state / "agents" / "server-100-200" / f"pane-{pane['pane_id'][1:]}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def hook(self, pane, tool="claude", session="session-id", **extra):
        value = {"pane_id": pane["pane_id"], "tool": tool, "session_id": session,
                 "cwd": pane["pane_path"], "recorded_at": "1970-01-01T00:03:21Z"}
        value.update(extra)
        self.hook_path(pane).write_text(json.dumps(value))

    def assemble(self, panes, capture_nvim=False, env=None, capture_agents=True):
        captured = self.root / "captured.jsonl"
        output = self.root / "output.jsonl"
        failures = self.root / "failures"
        captured.write_text("".join(json.dumps(pane) + "\n" for pane in panes))
        failures.write_text("")
        subprocess.run([sys.executable, str(ASSEMBLER), str(captured), str(output),
                        str(failures), str(self.state), self.identity, self.started, str(int(capture_agents)), str(int(capture_nvim))],
                       check=True, env=env)
        return [json.loads(line) for line in output.read_text().splitlines()]

    def native_codex_env(self, pane, rollouts):
        binary = self.root / "bin"
        binary.mkdir(exist_ok=True)
        ps = binary / "ps"
        lsof = binary / "lsof"
        ps.write_text(f"#!/bin/sh\nprintf '%s\\n' '{pane['pane_pid']} 1 /opt/codex'\n")
        lsof.write_text("#!/bin/sh\nprintf '%s\\n' " + " ".join(repr("n" + str(path)) for path in rollouts) + "\n")
        ps.chmod(0o755)
        lsof.chmod(0o755)
        return {**os.environ, "PATH": f"{binary}:{os.environ['PATH']}"}

    def rollout(self, session_id):
        directory = self.root / ".codex" / "sessions" / "2026" / "09" / "29"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"rollout-2026-09-29T00-00-00-{session_id}.jsonl"
        path.write_text(json.dumps({"type": "session_meta", "payload": {
            "id": session_id, "cwd": "/work", "source": "cli"}}) + "\n")
        return path

    def test_malformed_nonobject_and_non_utf8_hooks_fail_closed(self):
        for index, content in enumerate((b"{", b"[]", b'\xff'), 1):
            pane = self.pane(index)
            self.hook_path(pane).write_bytes(content)
            record = self.assemble([pane])[0]
            self.assertEqual(record["selected_source"], "agent-session-unavailable")
            self.assertEqual(record["selected_command"], "")
            self.assertIn("missing, invalid or stale claude", record["agent_capture_error"])

    def test_identity_and_strict_legacy_provenance(self):
        exact, mismatch, empty, legacy, stale = [self.pane(index) for index in range(1, 6)]
        self.hook(exact, pane_identity=f"{self.identity}:{exact['pane_pid']}")
        self.hook(mismatch, pane_identity="wrong")
        self.hook(empty, pane_identity="")
        self.hook(legacy)
        self.hook(stale, recorded_at="1970-01-01T00:03:19Z")
        records = self.assemble([exact, mismatch, empty, legacy, stale])
        self.assertEqual([record["selected_source"] for record in records],
                         ["claude-session", "agent-session-unavailable",
                          "agent-session-unavailable", "claude-session",
                          "agent-session-unavailable"])

    def test_pending_precedence_and_batched_multiagent_exact_ids(self):
        pending = self.pane(1, pending="echo pending\necho exact")
        claude = self.pane(2, "claudef --model sonnet")
        pi = self.pane(3, "pif --model kimi")
        codex = self.pane(4, "codexf --model gpt-5 resume old-id")
        self.hook(pending, session="ignored-by-pending")
        self.hook(claude, session="claude-exact")
        self.hook(pi, tool="pi", session="pi-exact")
        self.hook(codex, tool="codex", session="codex-exact")
        records = self.assemble([pending, claude, pi, codex])
        self.assertEqual(records[0]["selected_source"], "pending-buffer")
        self.assertEqual(records[0]["selected_command"], pending["pending_buffer"])
        self.assertIn("--resume claude-exact", records[1]["selected_command"])
        self.assertIn("--session pi-exact", records[2]["selected_command"])
        self.assertEqual(records[3]["selected_command"], "")
        self.assertEqual(records[3]["selected_source"], "ignored-agent")
        self.assertIsNone(records[3]["agent"])
        self.assertEqual(records[3]["agent_capture_error"], "")
        self.assertEqual([record["agent"]["session_id"] for record in records[1:3]],
                         ["claude-exact", "pi-exact"])

    def test_pending_input_wins_over_still_live_neovim_registration(self):
        pending = "claudef --resume not-submitted\nprintf '%s\\n' 'still editing'"
        pane = self.pane(pending=pending)
        pane.update(nvim_server=str(self.root / "n.sock"), nvim_owner=str(os.getpid()),
                    nvim_session=str(self.root / "editor.vim"), pending_cursor="9")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(pane["nvim_server"])
            record = self.assemble([pane], capture_nvim=True)[0]
        self.assertEqual(record["selected_source"], "pending-buffer")
        self.assertEqual(record["selected_command"], pending)
        self.assertEqual(record["pending_cursor"], 9)
        self.assertIsNone(record["neovim"])

    def test_live_codex_is_ignored_with_missing_or_conflicting_hook(self):
        live_id = "01a0c5cf-f3cb-74f3-b37f-372de1cfa7b6"
        for with_hook in (False, True):
            with self.subTest(with_hook=with_hook):
                pane = self.pane(8, "codexf resume stale-id")
                if with_hook:
                    self.hook(pane, tool="codex", session="stale-id",
                              pane_identity=f"{self.identity}:{pane['pane_pid']}")
                record = self.assemble([pane], env=self.native_codex_env(
                    pane, [self.rollout(live_id)]))[0]
                self.assertEqual(record["selected_source"], "ignored-agent")
                self.assertIsNone(record["agent"])
                self.assertEqual(record["selected_command"], "")
                self.assertEqual(record["last_command"], "")
                self.assertEqual(record["agent_capture_error"], "")

    def test_ambiguous_live_codex_does_not_block_save(self):
        pane = self.pane(9, "codexf resume stale-id")
        self.hook(pane, tool="codex", session="stale-id",
                  pane_identity=f"{self.identity}:{pane['pane_pid']}")
        ids = ["01a0c5cf-f3cb-74f3-b37f-372de1cfa7b6",
               "01a088f0-65d2-7772-965f-11dff139bbba"]
        record = self.assemble([pane], env=self.native_codex_env(
            pane, [self.rollout(value) for value in ids]))[0]
        self.assertEqual(record["selected_source"], "ignored-agent")
        self.assertEqual(record["selected_command"], "")
        self.assertEqual(record["agent_capture_error"], "")

    def test_codex_pending_is_discarded_even_when_agent_capture_is_disabled(self):
        for capture_agents in (True, False):
            for pending in ("codexf resume old", 'codexf "unfinished',
                            "cd /work && codex", "echo ready\ncodexf"):
                with self.subTest(capture_agents=capture_agents, pending=pending):
                    pane = self.pane(command="echo old", pending=pending)
                    pane["pending_cursor"] = "5"
                    record = self.assemble([pane], capture_agents=capture_agents)[0]
                    self.assertEqual(record["selected_source"], "ignored-agent")
                    self.assertEqual(record["selected_command"], "")
                    self.assertEqual(record["pending_buffer"], "")
                    self.assertEqual(record["pending_cursor"], 0)
                    self.assertEqual(record["agent_capture_error"], "")

    def test_non_codex_pending_survives_codex_last_command(self):
        pane = self.pane(command="codexf resume old", pending="echo editing")
        record = self.assemble([pane])[0]
        self.assertEqual(record["selected_command"], "echo editing")
        self.assertEqual(record["last_command"], "")
        self.assertEqual(record["selected_source"], "pending-buffer")


if __name__ == "__main__":
    unittest.main()
