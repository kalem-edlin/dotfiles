import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "agent_command.py"
SPEC = importlib.util.spec_from_file_location("agent_command", SCRIPT)
agent_command = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent_command)


class AgentCommandTests(unittest.TestCase):
    def test_infers_names_paths_assignments_and_wrappers(self):
        cases = {
            "claude --model opus": "claude",
            "/opt/bin/claudef --resume abc": "claude",
            "PI_CODING_AGENT_DIR=/tmp/p env FOO=bar command /usr/bin/pif": "pi",
            "noglob exec codex resume abc": "codex",
            "codexf abc": "codex",
        }
        for command, expected in cases.items():
            with self.subTest(command=command):
                self.assertEqual(agent_command.infer(command), expected)

    def test_does_not_match_mentions(self):
        for command in ("echo claude", "printf 'run pi now'", "echo 'codexf abc'",
                        "cd /tmp && echo claude", "cd /tmp && claude && echo nope",
                        "cd /tmp; claude", "cd $HOME && claude"):
            with self.subTest(command=command):
                self.assertIsNone(agent_command.infer(command))

    def test_safe_cd_chain_preserves_cwd_and_resumes_through_focus_launcher(self):
        command = "cd '/tmp/Agent Work' && claude --resume old --model opus\n"
        self.assertEqual(agent_command.infer(command), "claude")
        self.assertEqual(agent_command.resume("claude", "new id", command),
                         "cd '/tmp/Agent Work' && claudef --model opus --resume 'new id'")

    def test_cd_dash_separator_is_preserved(self):
        self.assertEqual(agent_command.resume("pi", "id", "cd -- '-workspace' && pif"),
                         "cd -- -workspace && pif --session id")

    def test_claude_resume_flag_does_not_consume_following_option(self):
        self.assertEqual(agent_command.resume("claude", "new id", "claude --resume --model opus"),
                         "claudef --model opus --resume 'new id'")

    def test_removes_claude_old_selectors(self):
        self.assertEqual(agent_command.resume("claude", "id", "claudef --resume=old --continue --last"),
                         "claudef --resume id")

    def test_pi_selector_and_canonical_session(self):
        self.assertEqual(agent_command.resume("pi", "id", "pif --resume old --model opus"),
                         "pif --model opus --session id")
        self.assertEqual(agent_command.resume("pi", "id", "pif --resume --model opus"),
                         "pif --model opus --session id")
        self.assertEqual(agent_command.resume("pi", "id", "pif --continue -c -r --model opus"),
                         "pif --model opus --session id")

    def test_codex_resume_is_rejected(self):
        for command in ("codex", "codexf resume old", "cd /tmp && codexf"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                agent_command.resume("codex", "id", command)

    def test_ignored_codex_launchers_include_chains_and_unfinished_input(self):
        for command in ("codex", "codexf resume old", "/opt/bin/codexf",
                        "env FOO=bar command codexf", "noglob exec codex",
                        "cd /tmp && codexf", "echo ready; codexf",
                        "echo ready\ncodexf", 'codexf "unfinished',
                        "printf '%s' $(codexf)"):
            with self.subTest(command=command):
                self.assertTrue(agent_command.is_ignored(command))

    def test_codex_mentions_are_not_ignored(self):
        for command in ("echo codex", "printf 'codexf resume old'", "echo .codex",
                        "# codexf", "claudef --model opus", "pif", None):
            with self.subTest(command=command):
                self.assertFalse(agent_command.is_ignored(command))

    def test_removes_tool_specific_old_selectors(self):
        self.assertEqual(agent_command.resume("claude", "id", "claude -r old -c --session-id other --model opus"),
                         "claudef --model opus --resume id")

    def test_rejects_unsafe_session_ids(self):
        for session_id in ("-flag", "line\nbreak", "nul\x00byte", "del\x7f"):
            with self.subTest(session_id=repr(session_id)):
                with self.assertRaises(ValueError):
                    agent_command.resume("claude", session_id, "claude")

    def test_claude_settings_falls_back_to_focus_defaults(self):
        self.assertEqual(agent_command.resume("claude", "id", "claude --settings /tmp/other.json --model opus"),
                         "claudef --resume id")

    def test_quotes_session_id_and_normalizes_to_focus_launcher(self):
        self.assertEqual(agent_command.resume("claude", "space id", "claude --model opus"),
                         "claudef --model opus --resume 'space id'")

    def test_drops_positional_prompts_and_complex_shell(self):
        self.assertEqual(agent_command.resume("claude", "id", "claude --model opus 'do the thing'"),
                         "claudef --resume id")
        self.assertEqual(agent_command.resume("pi", "id", "pif --model opus | cat"), "pif --session id")

    def test_empty_id_rejected(self):
        with self.assertRaises(ValueError):
            agent_command.resume("codex", "", "codex")


if __name__ == "__main__":
    unittest.main()
