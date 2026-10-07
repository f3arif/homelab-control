import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import capture_restic as capture_module
from capture_restic import CaptureError, capture, command_observer, manifest


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.stage = self.root / "stage"
        self.source.mkdir()
        for name in ("keys", "data", "index", "snapshots", "locks", "tmp"):
            (self.source / name).mkdir()
        (self.source / "config").write_bytes(b"encrypted-config\x00\xff")
        self.add_object("keys", b"encrypted-key-file")
        self.add_object("index", b"encrypted-index")
        self.add_object("snapshots", b"encrypted-snapshot")
        self.pack = self.add_object("data/ab", bytes(range(256)) * 8193)
        self.idle = {"idle": True, "writers": {
            "backup": {"state": "inactive", "invocation": "one", "start": 41, "end": 42},
            "maintenance": {"state": "inactive", "invocation": "two", "start": 10, "end": 20},
        }}

    def add_object(self, folder, content):
        parent = self.source / folder
        parent.mkdir(parents=True, exist_ok=True)
        path = parent / hashlib.sha256(content).hexdigest()
        path.write_bytes(content)
        return path

    def assert_incomplete(self):
        self.assertTrue((self.stage / "INCOMPLETE").is_file())
        self.assertFalse((self.stage / "COMPLETE").exists())

    def test_success_preserves_every_byte_and_source(self):
        original = manifest(self.source)
        result = capture(self.source, self.stage, lambda: self.idle)
        self.assertEqual(manifest(self.source), original)
        self.assertEqual(manifest(self.stage / "repo"), original)
        self.assertEqual(result["files"], original)
        self.assertEqual(result["qualification"], capture_module.QUALIFICATION)
        self.assertFalse(result["restic_decryption_or_restore_tested"])
        self.assertFalse((self.stage / "INCOMPLETE").exists())
        marker = json.loads((self.stage / "COMPLETE").read_text())
        self.assertEqual(marker["manifest_sha256"], hashlib.sha256(
            (self.stage / "manifest.json").read_bytes()).hexdigest())
        for name in original:
            self.assertEqual((self.source / name).read_bytes(),
                             (self.stage / "repo" / name).read_bytes())

    def test_source_change_during_copy_stays_incomplete(self):
        real_read = capture_module._read_file
        changed = False

        def read(path, output=None):
            nonlocal changed
            result = real_read(path, output)
            if output is not None and not changed:
                changed = True
                self.add_object("snapshots", b"new-concurrent-snapshot")
            return result

        with patch.object(capture_module, "_read_file", side_effect=read):
            with self.assertRaisesRegex(CaptureError, "manifest changed"):
                capture(self.source, self.stage, lambda: self.idle)
        self.assert_incomplete()

    def test_existing_and_new_locks_are_rejected_without_removal(self):
        lock = self.source / "locks" / "active"
        lock.write_bytes(b"opaque-lock")
        with self.assertRaisesRegex(CaptureError, "locks are not empty"):
            capture(self.source, self.stage, lambda: self.idle)
        self.assertEqual(lock.read_bytes(), b"opaque-lock")
        self.assert_incomplete()

        self.stage = self.root / "second-stage"
        lock.unlink()
        real_read = capture_module._read_file

        def read(path, output=None):
            result = real_read(path, output)
            if output is not None:
                lock.write_bytes(b"new-lock")
            return result

        with patch.object(capture_module, "_read_file", side_effect=read):
            with self.assertRaisesRegex(CaptureError, "locks are not empty"):
                capture(self.source, self.stage, lambda: self.idle)
        self.assert_incomplete()
        self.assertTrue(lock.exists())

    def test_short_completed_writer_is_detected_by_observer_change(self):
        calls = 0

        def observer():
            nonlocal calls
            calls += 1
            if calls == 2:
                # Deliberately mutate the same dictionary returned previously.
                self.idle["writers"]["backup"].update(invocation="new", start=43, end=44)
            return self.idle

        with self.assertRaisesRegex(CaptureError, "Writer observation changed"):
            capture(self.source, self.stage, observer)
        self.assert_incomplete()

    def test_nonidle_and_failed_observers_are_rejected(self):
        with self.assertRaisesRegex(CaptureError, "idle=true"):
            capture(self.source, self.stage, lambda: {"idle": False})
        self.assert_incomplete()
        self.stage = self.root / "second-stage"

        def observer():
            raise RuntimeError("state unavailable")

        with self.assertRaisesRegex(RuntimeError, "state unavailable"):
            capture(self.source, self.stage, observer)
        self.assert_incomplete()

    def test_file_and_directory_symlinks_are_rejected(self):
        outside = self.root / "outside"
        outside.write_bytes(b"must not copy")
        link = self.source / "snapshots" / "linked-file"
        link.symlink_to(outside)
        with self.assertRaisesRegex(CaptureError, "Symlink rejected"):
            capture(self.source, self.stage, lambda: self.idle)
        self.assert_incomplete()
        link.unlink()
        self.stage = self.root / "second-stage"
        (self.source / "data" / "linked-dir").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(CaptureError, "Symlink rejected"):
            capture(self.source, self.stage, lambda: self.idle)
        self.assert_incomplete()

    def test_corrupt_ciphertext_object_is_rejected(self):
        self.pack.write_bytes(b"corruption")
        with self.assertRaisesRegex(CaptureError, "content-addressed object"):
            capture(self.source, self.stage, lambda: self.idle)
        self.assert_incomplete()

    def test_corrupted_staging_bytes_are_rejected(self):
        real_manifest = capture_module.manifest

        def inspect(root):
            if root == self.stage / "repo":
                (root / "config").write_bytes(b"transfer corruption")
            return real_manifest(root)

        with patch.object(capture_module, "manifest", side_effect=inspect):
            with self.assertRaisesRegex(CaptureError, "Staged bytes differ"):
                capture(self.source, self.stage, lambda: self.idle)
        self.assert_incomplete()

    def test_existing_destination_and_source_child_are_not_modified(self):
        self.stage.mkdir()
        sentinel = self.stage / "keep"
        sentinel.write_bytes(b"existing-generation")
        with self.assertRaises(FileExistsError):
            capture(self.source, self.stage, lambda: self.idle)
        self.assertEqual(list(self.stage.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"existing-generation")
        nested = self.source / "capture"
        with self.assertRaisesRegex(CaptureError, "separate trees"):
            capture(self.source, nested, lambda: self.idle)
        self.assertFalse(nested.exists())

    def test_command_observer_executes_argv_without_shell(self):
        observer = command_observer([
            sys.executable, "-c", "import json,sys; print(json.dumps({'idle':True,'arg':sys.argv[1]}))",
            "$(must-not-execute); literal",
        ])
        self.assertEqual(observer(), {"idle": True, "arg": "$(must-not-execute); literal"})
        with self.assertRaises(ValueError):
            command_observer("shell command is not accepted")


if __name__ == "__main__":
    unittest.main()
