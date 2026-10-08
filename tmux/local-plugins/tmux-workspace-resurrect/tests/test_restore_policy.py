import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "restore_policy.py"
SPEC = importlib.util.spec_from_file_location("restore_policy", SCRIPT)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class RestorePolicyTests(unittest.TestCase):
    def setUp(self):
        self.config = {"restore_mode": "whitelist", "restore_whitelist": {
            "names": ["claudef", "pif", "codexf", "nvim"], "delay_ms": 500}}

    def agent(self, tool="claude", command="claude --model opus", current="node"):
        return {"selected_source": f"{tool}-session", "selected_command": command,
                "pending_buffer": "", "current_command": current,
                "agent": {"tool": tool, "session_id": "exact-id"}}

    def test_agents_use_canonical_focus_resume_with_exact_id(self):
        expected = {"claude": "claudef --model opus --resume exact-id",
                    "pi": "pif --model opus --session exact-id"}
        for tool, command in expected.items():
            with self.subTest(tool=tool):
                result = POLICY.decide(self.agent(tool, f"{tool} --model opus"), self.config)
                self.assertEqual(result["action"], "execute")
                self.assertEqual(result["command"], command)

    def test_codex_is_never_executed_or_queued_even_in_old_snapshots(self):
        records = [
            self.agent("codex", "codexf resume old"),
            self.agent("codex", "echo mismatched old metadata", current="zsh"),
            {"selected_source": "codex-session", "selected_command": "echo old", "agent": None},
            {"selected_source": "last-command", "selected_command": "codex resume old"},
            {"selected_source": "pending-buffer", "selected_command": 'codexf "unfinished',
             "pending_buffer": 'codexf "unfinished'},
            {"selected_source": "last-command", "selected_command": "cd /work && codexf"},
            {"selected_source": "last-command", "selected_command": "echo ready\ncodexf"},
            {"selected_source": "last-command", "selected_command": "echo old", "current_command": "/opt/codex"},
        ]
        for config in (self.config, {"restore_mode": "queue"}, {}):
            for record in records:
                with self.subTest(config=config, record=record):
                    self.assertEqual(POLICY.decide(record, config), {"action": "ignore", "command": ""})

    def test_pending_input_never_executes(self):
        record = self.agent(command="claudef --resume exact-id")
        record.update(selected_source="pending-buffer", pending_buffer="claudef --resume exact-id")
        self.assertEqual(POLICY.decide(record, self.config)["action"], "queue")

    def test_exited_agent_at_shell_stays_queued(self):
        for shell in ("zsh", "bash", "fish", "sh", ""):
            with self.subTest(shell=shell):
                self.assertEqual(POLICY.decide(self.agent(current=shell), self.config)["action"], "queue")

    def test_source_tool_and_allowlist_must_agree(self):
        record = self.agent()
        record["selected_source"] = "pi-session"
        self.assertEqual(POLICY.decide(record, self.config)["action"], "queue")
        config = json.loads(json.dumps(self.config))
        config["restore_whitelist"]["names"].remove("claudef")
        self.assertEqual(POLICY.decide(self.agent(), config)["action"], "queue")

    def test_mismatched_saved_agent_command_does_not_autostart(self):
        self.assertEqual(POLICY.decide(self.agent(command="echo injected"), self.config)["action"], "queue")

    def test_queue_mode_preserves_original_command(self):
        record = self.agent(command="echo untouched")
        config = {"restore_mode": "queue"}
        self.assertEqual(POLICY.decide(record, config),
                         {"action": "queue", "command": "echo untouched"})

    def test_neovim_requires_exact_command_and_regular_existing_session(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory) / "Session File.vim"
            session.write_text("", encoding="utf-8")
            command = "nvim -S " + POLICY.shlex.quote(str(session))
            record = {"selected_source": "neovim-session", "selected_command": command,
                      "pending_buffer": "", "current_command": "nvim",
                      "neovim": {"session_file": str(session)}}
            self.assertEqual(POLICY.decide(record, self.config)["action"], "execute")
            record["selected_command"] = f"nvim -S '{session}'"
            self.assertEqual(POLICY.decide(record, self.config)["action"], "execute")
            record["selected_command"] += " --cmd 'echo unsafe'"
            self.assertEqual(POLICY.decide(record, self.config)["action"], "queue")
            record["selected_command"] = command
            session.unlink()
            self.assertEqual(POLICY.decide(record, self.config)["action"], "queue")


if __name__ == "__main__":
    unittest.main()
