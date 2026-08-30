import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from afz_h3_worker.process import run_process


class RunProcessTests(unittest.TestCase):
    def test_returns_real_exit_and_streams(self):
        result = run_process(
            [
                sys.executable,
                "-c",
                "import sys; print('OUT'); print('ERR', file=sys.stderr); sys.exit(7)",
            ]
        )
        self.assertFalse(result.timed_out)
        self.assertEqual(result.exit_code, 7)
        self.assertEqual(result.stdout, "OUT\n")
        self.assertEqual(result.stderr, "ERR\n")

    def test_git_prompt_is_disabled(self):
        result = run_process(
            [sys.executable, "-c", "import os; print(os.environ['GIT_TERMINAL_PROMPT'])"]
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stdout.strip(), "0")

    def test_timeout_is_explicit(self):
        started = time.monotonic()
        result = run_process(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            timeout_seconds=0.2,
        )
        self.assertTrue(result.timed_out)
        self.assertIsNone(result.exit_code)
        self.assertLess(time.monotonic() - started, 5)

    def test_shell_string_is_rejected(self):
        with self.assertRaises(TypeError):
            run_process("echo unsafe")

    def test_stdin_is_closed_by_default(self):
        result = run_process(
            [sys.executable, "-c", "import sys; print(sys.stdin.read())"]
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stdout, "\n")


if __name__ == "__main__":
    unittest.main()
