import base64
import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import guard_volume as guard
from patch_nextcloud import DOCKER, FLOCK, MARKER, patch_nextcloud

GUID = "11111111-2222-4333-8444-555555555555"
PROFILE = {"ssh_host": "192.0.2.10", "ssh_user": "backup_user", "ssh_key": "/private/ssh-key",
           "known_hosts": "/private/known-hosts", "drive_letter": "X", "volume_guid": GUID,
           "volume_label": "EXAMPLE_BACKUP", "min_free_bytes": 100 * 1024**3}
ACTUAL = {"drive_letter": "X", "volume_guid": "\\\\?\\Volume{" + GUID + "}\\",
          "volume_label": "EXAMPLE_BACKUP", "free_bytes": 101 * 1024**3}
SOURCE = ('#!/bin/sh\nset -eu\n' + FLOCK + '\n\ncd "$BASE"\nrclone() {\n  ' + DOCKER +
          '     -v "$BASE/data:/data:ro" rclone/rclone:latest "$@"\n}\n'
          'make_backup\n' + MARKER + '\n{"ok":true}\nEOF\n'
          "find backups -maxdepth 1 -type f -mtime +2 ! -name '*latest*' -delete\n"
          'cat "$BASE/last-h3-backup.json"\n')


class VolumeTests(unittest.TestCase):
    def test_identity_and_reserve_boundary(self):
        actual = dict(ACTUAL, free_bytes=PROFILE["min_free_bytes"])
        self.assertTrue(guard.validate_volume(PROFILE, actual)["ok"])
        for field, value in (("volume_guid", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
                             ("volume_label", "WRONG"), ("drive_letter", "Y")):
            with self.subTest(field=field), self.assertRaisesRegex(guard.GuardError, "identity_mismatch"):
                guard.validate_volume(PROFILE, dict(actual, **{field: value}))
        with self.assertRaisesRegex(guard.GuardError, "insufficient_free_space"):
            guard.validate_volume(PROFILE, dict(actual, free_bytes=actual["free_bytes"] - 1))

    def test_malformed_response_and_free_values_fail_closed(self):
        for actual in ([], None, {}, dict(ACTUAL, free_bytes=True), dict(ACTUAL, free_bytes=-1),
                       dict(ACTUAL, free_bytes="1099511627776"), dict(ACTUAL, volume_guid="bad")):
            with self.subTest(actual=actual), self.assertRaises(guard.GuardError):
                guard.validate_volume(PROFILE, actual)

    def test_private_profile_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "profile.json"
            path.write_text(json.dumps(dict(PROFILE, drive_letter="x:")))
            self.assertEqual(guard.load_profile(path)["drive_letter"], "X")
            for field, value in (("ssh_host", "-oProxyCommand=unsafe"), ("ssh_user", "-unsafe"),
                                 ("ssh_key", "relative"), ("drive_letter", "X';bad"),
                                 ("min_free_bytes", True), ("volume_guid", "bad")):
                path.write_text(json.dumps(dict(PROFILE, **{field: value})))
                with self.subTest(field=field), self.assertRaisesRegex(guard.GuardError, "invalid_profile"):
                    guard.load_profile(path)

    def test_ssh_is_pinned_bounded_and_utf16_encoded(self):
        captured = {}
        def run(argv, **kwargs):
            captured.update(argv=argv, kwargs=kwargs)
            return SimpleNamespace(returncode=0, stdout=json.dumps(ACTUAL), stderr="")
        self.assertEqual(guard.query_volume(PROFILE, run), ACTUAL)
        for value in ("StrictHostKeyChecking=yes", "BatchMode=yes", "IdentitiesOnly=yes",
                      "UserKnownHostsFile=/private/known-hosts", "ConnectTimeout=7"):
            self.assertIn(value, captured["argv"])
        command = captured["argv"][-1]
        script = base64.b64decode(command.split()[-1]).decode("utf-16le")
        self.assertIn("Get-Volume -DriveLetter 'X'", script)
        self.assertIn("UniqueId", script)
        self.assertEqual(captured["kwargs"]["timeout"], 25)
        self.assertNotIn("shell", captured["kwargs"])

    def test_ssh_errors_and_output_do_not_disclose_diagnostics(self):
        for result in (SimpleNamespace(returncode=1, stdout="", stderr="private diagnostic"),
                       SimpleNamespace(returncode=0, stdout="not JSON", stderr="")):
            with self.subTest(result=result), self.assertRaises(guard.GuardError):
                guard.query_volume(PROFILE, lambda *a, **k: result)
        def timeout(*a, **k):
            raise subprocess.TimeoutExpired(["private command"], 25)
        with self.assertRaisesRegex(guard.GuardError, "ssh_query_failed"):
            guard.query_volume(PROFILE, timeout)
        out = io.StringIO()
        with patch.object(guard, "load_profile", return_value=PROFILE), patch.object(guard, "query_volume", side_effect=guard.GuardError("ssh_query_failed")), redirect_stdout(out):
            self.assertEqual(guard.main(["/private/profile.json"]), 1)
        self.assertEqual(json.loads(out.getvalue()), {"ok": False, "error": "ssh_query_failed"})


class PatcherTests(unittest.TestCase):
    def test_only_intended_insertions_and_host_network(self):
        changed = patch_nextcloud(SOURCE, "/safe/guard's file.py", "/safe/private profile.json")
        calls = [line for line in changed.splitlines(keepends=True) if line.startswith("python3 ")]
        self.assertEqual(len(calls), 2)
        self.assertIn("'\"'\"'", calls[0])
        self.assertTrue(calls[0].endswith(" || exit $?\n"))
        restored = "".join(line for line in changed.splitlines(keepends=True) if not line.startswith("python3 "))
        self.assertEqual(restored.replace(DOCKER + " --network host", DOCKER), SOURCE)
        self.assertIn(FLOCK + "\n" + calls[0], changed)
        self.assertIn(calls[1] + MARKER, changed)
        self.assertEqual(subprocess.run(["sh", "-n"], input=changed, text=True, capture_output=True).returncode, 0)

    def test_anchor_counts_network_repatch_and_paths_fail_closed(self):
        bad = [SOURCE.replace(FLOCK, "missing"), SOURCE + FLOCK + "\n", SOURCE + MARKER + "\n",
               SOURCE + DOCKER, SOURCE.replace(DOCKER, DOCKER + " --network host")]
        for value in bad:
            with self.subTest(source=value), self.assertRaises(ValueError):
                patch_nextcloud(value, "/safe/guard.py", "/safe/profile.json")
        with self.assertRaises(ValueError):
            patch_nextcloud(SOURCE, "relative.py", "/safe/profile.json")

    def test_crlf_and_retention_preserved(self):
        changed = patch_nextcloud(SOURCE.replace("\n", "\r\n"), "/safe/guard.py", "/safe/profile.json")
        self.assertNotIn("\n", changed.replace("\r\n", ""))
        self.assertIn("-mtime +2 ! -name '*latest*' -delete\r\n", changed)


if __name__ == "__main__":
    unittest.main()
