from pathlib import Path
import tempfile
import unittest

from afz_h3_worker.actions import ActionContractError, h3_file_hash, resolve_readonly_file


class FileHashActionR5Tests(unittest.TestCase):
    def test_exact_legacy_summary_shape_and_uppercase_sha256(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "AFZ-H3-Worker.ps1"
            path.write_bytes(b"abc")

            payload = h3_file_hash(path, allowed_roots=(root,))

            self.assertEqual(
                payload,
                {
                    "summary": [
                        "FILE_HASH : READ ONLY",
                        f"PATH={path.resolve()}",
                        "SHA256=BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
                    ]
                },
            )

    def test_readonly_resolution_accepts_nested_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            nested = root / "a" / "b"
            nested.mkdir(parents=True)
            path = nested / "x.bin"
            path.write_bytes(b"x")
            self.assertEqual(resolve_readonly_file(path, (root,)), path.resolve())

    def test_outside_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_a, tempfile.TemporaryDirectory() as temp_b:
            path = Path(temp_a) / "x.bin"
            path.write_bytes(b"x")
            with self.assertRaises(ActionContractError):
                h3_file_hash(path, allowed_roots=(Path(temp_b),))

    def test_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ActionContractError):
                h3_file_hash(root, allowed_roots=(root,))

    def test_missing_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(FileNotFoundError):
                h3_file_hash(root / "missing.bin", allowed_roots=(root,))

    def test_empty_root_set_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "x.bin"
            path.write_bytes(b"x")
            with self.assertRaises(ActionContractError):
                h3_file_hash(path, allowed_roots=())


if __name__ == "__main__":
    unittest.main()
