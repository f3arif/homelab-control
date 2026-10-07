import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import backup_pi as backup
import capture_restic


GEN = "20260101T010203123456Z-012345abcdef"
PROFILE = {
    "ssh_host": "192.0.2.10", "ssh_user": "backup_user",
    "ssh_key": "/private/ssh files/key's file", "known_hosts": "/private/ssh files/known_hosts",
    "drive_letter": "X", "volume_guid": "11111111-2222-4333-8444-555555555555",
    "volume_label": "EXAMPLE_BACKUP", "min_free_bytes": 100,
    "source_repository": "/private/source", "work_dir": "/private/work",
    "rclone_image": "sha256:" + "a" * 64,
    "repository_base_windows": "X:\\AFZ\\Backups\\Repo's archive",
    "repository_base_sftp": "/X:/AFZ/Backups/Repo's archive",
    "observer_command": ["python3", "/private/observe.py"], "host": "example", "tag": "replica",
}
ACTUAL = {key: PROFILE[key] for key in ("drive_letter", "volume_guid", "volume_label")}
ACTUAL["free_bytes"] = 10**12


class ReplicaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.work = self.root / "work"
        self.source.mkdir()
        for folder in ("keys", "data", "index", "snapshots", "locks", "tmp"):
            (self.source / folder).mkdir()
        (self.source / "config").write_bytes(b"encrypted configuration")
        for folder in ("keys", "data", "index", "snapshots"):
            data = ("encrypted " + folder).encode()
            (self.source / folder / hashlib.sha256(data).hexdigest()).write_bytes(data)
        self.profile = dict(PROFILE, source_repository=str(self.source), work_dir=str(self.work))
        self.events = []
        self.observer = lambda: {"idle": True, "boot": "fixture", "invocation": "unchanged"}

    def mocked_run(self, remote=None, upload=None):
        def fake_remote(p, action, **request):
            self.events.append(action)
            if action == "status":
                return {"ok": True, "matches": True}
            if action == "prepare":
                self.assertGreater(request["required_bytes"], 0)
                return {"ok": True}
            expected = request["expected"]
            return {"ok": True, "generation": request["generation"],
                    "manifest_sha256": expected["manifest_sha256"],
                    "published_utc": "2026-01-01T00:00:00Z"}

        def fake_upload(p, stage, generation):
            self.events.append("upload")
            self.assertTrue((stage / "COMPLETE").is_file())
            self.assertFalse((stage / "INCOMPLETE").exists())
            self.assertFalse((stage / "PUBLISHED.json").exists())

        def volume(_p):
            self.events.append("guard")
            return ACTUAL

        with patch.object(backup.guard_volume, "query_volume", side_effect=volume), \
             patch.object(capture_restic, "command_observer", return_value=self.observer), \
             patch.object(backup, "remote", side_effect=remote or fake_remote), \
             patch.object(backup, "upload", side_effect=upload or fake_upload):
            return backup.replicate(self.profile)

    def test_publish_then_skip_requires_guard_and_remote_confirmation(self):
        first = self.mocked_run()
        self.assertEqual(first["status"], "published")
        self.assertEqual(self.events, ["guard", "prepare", "upload", "publish"])
        record = json.loads((self.work / "latest_verified.json").read_text())
        stage = self.work / "stages" / first["generation"]
        self.assertTrue((stage / "PUBLISHED.json").exists())
        self.assertEqual(record["source_manifest_sha256"], backup.content_hash(capture_restic.manifest(self.source)))
        self.events.clear()
        second = self.mocked_run()
        self.assertEqual(second["status"], "skipped_unchanged")
        self.assertEqual(self.events, ["guard", "status"])
        self.assertEqual(first["generation"], second["generation"])

    def test_upload_failure_never_publishes_or_marks_local_receipt(self):
        def fail(*args):
            raise backup.BackupError("upload_failed")
        with self.assertRaisesRegex(backup.BackupError, "upload_failed"):
            self.mocked_run(upload=fail)
        self.assertNotIn("publish", self.events)
        self.assertFalse((self.work / "latest_verified.json").exists())
        stages = list((self.work / "stages").iterdir())
        self.assertEqual(len(stages), 1)
        self.assertFalse((stages[0] / "PUBLISHED.json").exists())
        backup.cleanup_stages(self.work, keep=0)
        self.assertTrue(stages[0].exists())

    def test_publication_failure_and_bad_receipt_preserve_previous_record(self):
        self.mocked_run()
        original = (self.work / "latest_verified.json").read_bytes()
        (self.source / "config").write_bytes(b"new encrypted config")
        for bad_receipt in (False, True):
            def fail(p, action, **request):
                if action == "prepare":
                    return {"ok": True}
                if bad_receipt:
                    return {"ok": True, "generation": "wrong", "manifest_sha256": "wrong"}
                raise backup.BackupError("remote_publish_failed")
            with self.subTest(bad_receipt=bad_receipt), self.assertRaises(backup.BackupError):
                self.mocked_run(remote=fail)
            self.assertEqual((self.work / "latest_verified.json").read_bytes(), original)

    def test_busy_lock_and_unsafe_work_permissions(self):
        with backup.runner_lock(self.work) as acquired:
            self.assertTrue(acquired)
            with patch.object(backup.guard_volume, "query_volume") as guard:
                self.assertEqual(backup.replicate(self.profile)["status"], "skipped_busy")
                guard.assert_not_called()
        self.work.chmod(0o755)
        with self.assertRaisesRegex(backup.BackupError, "mode_0700"):
            with backup.runner_lock(self.work):
                self.fail("unsafe work directory accepted")

    def test_volume_failure_prevents_capture_and_transfer(self):
        with patch.object(backup.guard_volume, "query_volume", return_value=dict(ACTUAL, volume_label="WRONG")), \
             patch.object(capture_restic, "capture") as capture, patch.object(backup, "upload") as upload:
            with self.assertRaises(backup.guard_volume.GuardError):
                backup.replicate(self.profile)
            capture.assert_not_called()
            upload.assert_not_called()

    def test_cleanup_is_bounded_and_requires_matching_published_receipt(self):
        self.work.mkdir(mode=0o700)
        stages = self.work / "stages"
        stages.mkdir()
        created = []
        for n in range(4):
            generation = f"20260101T00000000000{n}Z-012345abcdef"
            stage = stages / generation
            capture_restic.capture(self.source, stage, self.observer)
            marker = json.loads((stage / "COMPLETE").read_text())
            receipt = {"kind": backup.STAGE_KIND, "generation": generation,
                       "manifest_sha256": marker["manifest_sha256"] if n != 0 else "wrong"}
            (stage / "PUBLISHED.json").write_text(json.dumps(receipt))
            created.append(stage)
        backup.cleanup_stages(self.work, keep=1, max_remove=1)
        self.assertTrue(created[0].exists())  # mismatched receipt is never deleted
        self.assertFalse(created[1].exists())
        self.assertTrue(created[2].exists())
        self.assertTrue(created[3].exists())


class CommandTests(unittest.TestCase):
    def test_large_remote_payload_uses_stdin_and_bounded_command(self):
        receipt = {"snapshot_ids": [f"{n:064x}" for n in range(1000)]}
        captured = {}
        def run(argv, **kwargs):
            captured.update(argv=argv, kwargs=kwargs)
            return SimpleNamespace(returncode=0, stdout='{"ok":true}', stderr="")
        with patch.object(backup.subprocess, "run", side_effect=run):
            backup.remote(PROFILE, "publish", generation=GEN, expected=receipt)
        self.assertLess(len(captured["argv"][-1]), 2000)
        self.assertGreater(len(captured["kwargs"]["input"]), 60000)
        frame = captured["kwargs"]["input"]
        self.assertTrue(frame.endswith("\n"))
        self.assertEqual(frame.count("\n"), 1)
        payload = json.loads(frame[:-1])
        self.assertEqual(payload["cfg"]["repository_base_windows"], PROFILE["repository_base_windows"])
        self.assertEqual(payload["cfg"]["expected"], receipt)
        self.assertNotIn("shell", captured["kwargs"])
        bootstrap = base64.b64decode(captured["argv"][-1].split()[-1]).decode("utf-16le")
        self.assertIn("[Console]::In.ReadLine()", bootstrap)
        self.assertNotIn("ReadToEnd", bootstrap)
        self.assertIn("missing_input_payload", bootstrap)
        self.assertNotIn(PROFILE["repository_base_windows"], bootstrap)
        self.assertIn("StrictHostKeyChecking=yes", captured["argv"])
        self.assertIn("UserKnownHostsFile=" + PROFILE["known_hosts"], captured["argv"])

    def test_newlines_inside_payload_do_not_split_the_frame(self):
        note = "first line\nsecond line\r\nUnicode: \u96ea"
        frame = backup.remote_payload(PROFILE, "status", expected={"note": note})
        self.assertEqual(frame.count("\n"), 1)
        self.assertTrue(frame.endswith("\n"))
        self.assertNotIn("\r", frame)
        self.assertEqual(json.loads(frame[:-1])["cfg"]["expected"]["note"], note)

    def test_upload_uses_pinned_image_readonly_mounts_and_copy(self):
        cmd = backup.upload_command(PROFILE, Path("/private/stage's dir"), GEN)
        self.assertEqual(cmd[cmd.index("--network") + 1], "host")
        self.assertEqual(cmd[cmd.index("--user") + 1], "1000:1000")
        self.assertEqual(cmd[cmd.index("--config") + 1], "/dev/null")
        self.assertIn(PROFILE["rclone_image"], cmd)
        self.assertIn("copy", cmd)
        self.assertNotIn("sync", cmd)
        self.assertFalse(any(part.startswith("--delete") for part in cmd))
        self.assertEqual(cmd[cmd.index("--sftp-known-hosts-file") + 1], "/keys/known_hosts")
        mounts = [cmd[i + 1] for i, value in enumerate(cmd) if value == "--mount"]
        self.assertTrue(all(value.endswith(",readonly") for value in mounts))

    def test_timeout_removes_only_labelled_owned_container(self):
        for owns in (True, False):
            calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                if argv[:2] == ["docker", "run"]:
                    raise subprocess.TimeoutExpired(argv, 2700)
                if argv[:2] == ["docker", "inspect"]:
                    labels = {"afz.replica.kind": "pi", "afz.replica.generation": GEN if owns else "other"}
                    return SimpleNamespace(returncode=0, stdout=json.dumps(labels), stderr="")
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            with self.subTest(owns=owns), patch.object(backup.subprocess, "run", side_effect=run):
                with self.assertRaisesRegex(backup.BackupError, "upload_failed"):
                    backup.upload(PROFILE, Path("/stage"), GEN)
            removes = [cmd for cmd in calls if cmd[:3] == ["docker", "rm", "-f"]]
            self.assertEqual(len(removes), int(owns))
            if removes:
                self.assertEqual(removes[0][-1], backup.container_name(GEN))

    def test_profile_rejects_wrong_mapping_unpinned_image_and_escaping_path(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "profile.json"
            path.write_text(json.dumps(PROFILE))
            self.assertEqual(backup.load_profile(path)["host"], "example")
            for field, value in (("rclone_image", "rclone/rclone:latest"),
                                 ("repository_base_sftp", "/Y:/wrong"),
                                 ("repository_base_windows", "X:\\AFZ\\..\\wrong"),
                                 ("repository_base_windows", "X:\\AFZ\\Backups:stream"),
                                 ("observer_command", "shell command")):
                path.write_text(json.dumps(dict(PROFILE, **{field: value})))
                with self.subTest(field=field), self.assertRaises(backup.BackupError):
                    backup.load_profile(path)


if __name__ == "__main__":
    unittest.main()
