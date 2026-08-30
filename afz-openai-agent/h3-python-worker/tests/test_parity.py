from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from afz_h3_worker.parity import compare_process_results, semantic_json_equal, sha256_file
from afz_h3_worker.process import ProcessResult


class ParityTests(unittest.TestCase):
    def test_identical_process_results_pass(self):
        left = ProcessResult(("x",), 0, "a", "", 1.0, False)
        right = ProcessResult(("x",), 0, "a", "", 2.0, False)
        report = compare_process_results(left, right)
        self.assertTrue(report.ok)

    def test_exit_mismatch_fails(self):
        left = ProcessResult(("x",), 0, "", "", 1.0, False)
        right = ProcessResult(("x",), 1, "", "", 1.0, False)
        report = compare_process_results(left, right)
        self.assertFalse(report.ok)
        self.assertIn("exit_code", report.differences)

    def test_semantic_json_ignores_declared_volatile_keys(self):
        self.assertTrue(
            semantic_json_equal(
                '{"state":"READY","timestamp":"a"}',
                '{"timestamp":"b","state":"READY"}',
                ignore_keys={"timestamp"},
            )
        )

    def test_sha256_is_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "a.bin"
            path.write_bytes(b"abc")
            self.assertEqual(
                sha256_file(path),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            )


if __name__ == "__main__":
    unittest.main()
