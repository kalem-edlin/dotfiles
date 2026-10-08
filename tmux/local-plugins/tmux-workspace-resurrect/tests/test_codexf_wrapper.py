import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO = TEST_DIR.parents[3]


class CodexfWrapperTests(unittest.TestCase):
    def test_forwards_explicit_arguments_with_and_without_instructions(self):
        source = (REPO / "zsh/.zshrc").read_text()
        function = re.search(r"(?ms)^codexf\(\) \{.*?^\}", source).group(0)
        self.assertNotIn(".codex", function)
        with tempfile.TemporaryDirectory(prefix="codexf-wrapper-test-") as directory:
            root = Path(directory)
            binary = root / "codex"
            shutil.copyfile(TEST_DIR / "fixtures/codex-argv", binary)
            binary.chmod(0o700)
            (root / "agents").mkdir()
            for instructions in (False, True):
                prompt = root / "agents/communication.md"
                if instructions:
                    prompt.write_text('test instructions with "quotes" and \\slashes\n')
                env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                           DOTFILES=str(root))
                for args in ([], ["resume", "test-session"], ["--help"]):
                    with self.subTest(instructions=instructions, args=args):
                        output = subprocess.check_output(
                            ["zsh", "-df", "-c", function + '\ncodexf "$@"', "_", *args],
                            env=env, text=True,
                        ).splitlines()
                        self.assertEqual(output[0], "--dangerously-bypass-approvals-and-sandbox")
                        offset = 1
                        if instructions:
                            self.assertEqual(output[1], "-c")
                            self.assertEqual(output[2], "developer_instructions=" +
                                             json.dumps(prompt.read_text()))
                            offset = 3
                        self.assertEqual(output[offset:], args)


if __name__ == "__main__":
    unittest.main()
