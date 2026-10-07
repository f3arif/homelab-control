import json
import fcntl
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import backup_hp as backup


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "application"
        self.source.mkdir()
        self.ssh = self.base / "ssh"
        self.ssh.mkdir(mode=0o700)
        self.password = self.base / "repository-password"
        self.password.write_text("nonsecret-test-only-password")
        self.password.chmod(0o600)
        self.p = {
            "source_roots": [str(self.source)], "exclusions": [], "database_dumps": [],
            "password_file": str(self.password), "work_dir": str(self.base / "work"),
            "ssh_key": str(self.ssh / "existing-identity"), "known_hosts": str(self.ssh / "known_hosts"),
            "ssh_host": "backup.example", "ssh_user": "backup", "drive_letter": "F",
            "repository_path": "/F:/Approved/Backup/restic", "restic_image": "restic/restic@sha256:" + "a" * 64,
            "snapshot_host": "test-host", "snapshot_tag": "application-config", "coverage": {"scope": "test-only"},
        }
        self.addCleanup(patch.stopall)
        patch.object(backup, "EXPECTED_UID", os.geteuid()).start()
        patch.object(backup, "EXPECTED_GID", os.getegid()).start()
        self.calls = []

    def fake_restic(self, p, stage, label, args, include_sources=False):
        self.calls.append((label, args, include_sources))
        out = stage / (label + ".stdout")
        if label == "backup":
            out.write_text(json.dumps({"message_type": "summary", "snapshot_id": "abcdefff",
                                       "total_files_processed": 4, "total_bytes_processed": 80}) + "\n")
        elif label == "snapshot-metadata":
            out.write_text(json.dumps([{"id": "abcdefff" + "0" * 56}]))
        elif label == "restored-marker":
            source = Path(p["work_dir"]) / args[-1].removeprefix("/work/")
            out.write_bytes(source.read_bytes())
        else:
            out.write_text("{}")
        return out

    def test_profile_rejects_broad_roots_and_unpinned_image(self):
        backup.validate_profile(self.p)
        for root in ("/", "/home", "/home/operator", "/var/lib/docker"):
            with self.subTest(root=root), self.assertRaises(backup.BackupError):
                backup.validate_profile(dict(self.p, source_roots=[root]))
        with self.assertRaisesRegex(backup.BackupError, "pinned_official"):
            backup.validate_profile(dict(self.p, restic_image="restic/restic:latest"))

    def test_scan_does_not_follow_symlinks_or_nested_mounts(self):
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "private.txt").write_text("not part of source")
        (self.source / "link").symlink_to(outside, target_is_directory=True)
        mounted = self.source / "remote"
        mounted.mkdir()
        (mounted / "file").write_text("do not traverse")
        (self.source / "normal").write_text("included")
        plan = backup.source_plan(self.p, mounts=[("/", "ext4"), (str(mounted), "fuse.sshfs")])
        self.assertTrue(plan["ok"])
        self.assertEqual(plan["regular_files"], 1)
        self.assertEqual(plan["symlinks"], 1)
        self.assertNotIn(str(outside / "private.txt"), plan["_paths"])
        self.assertEqual(plan["excluded"][0]["reason"], "nested_mount_not_followed")
        (self.base / "source-alias").symlink_to(self.source, target_is_directory=True)
        alias = dict(self.p, source_roots=[str(self.base / "source-alias")])
        self.assertFalse(backup.source_plan(alias, mounts=[])["ok"])

    def test_private_key_headers_renamed_keys_and_names_are_excluded(self):
        headers = [b"-----BEGIN " + kind + b"PRIVATE KEY-----\nprivate"
                   for kind in (b"OPENSSH ", b"RSA ", b"EC ", b"DSA ", b"", b"ENCRYPTED ")]
        for index, header in enumerate(headers):
            (self.source / ("renamed-" + str(index) + ".txt")).write_bytes(header)
        (self.source / "id_ed25519").write_text("unrecognized-but-forbidden-name")
        (self.source / "normal.txt").write_text("safe configuration")
        plan = backup.source_plan(self.p, mounts=[])
        self.assertTrue(plan["ok"])
        self.assertEqual(plan["regular_files"], 1)
        self.assertEqual(len(plan["excluded"]), 7)
        self.assertNotIn("BEGIN", json.dumps(backup.public_plan(plan)))
        self.assertEqual(plan["_paths"], [str(self.source / "normal.txt")])

    def test_permission_failure_is_explicit_and_has_no_native_error_text(self):
        denied = self.source / "denied.txt"
        denied.write_text("data")
        original = os.open
        def denying(path, *args, **kwargs):
            if str(path) == str(denied):
                raise PermissionError("PRIVATE_ERROR_MUST_NOT_APPEAR")
            return original(path, *args, **kwargs)
        with patch.object(backup.os, "open", side_effect=denying):
            plan = backup.source_plan(self.p, mounts=[])
        self.assertFalse(plan["ok"])
        self.assertEqual(plan["issues"], [{"path": str(denied), "code": "permission_denied"}])
        self.assertNotIn("PRIVATE_ERROR", json.dumps(plan))
        self.p["exclusions"] = [{"path": str(denied), "reason": "explicit alternate coverage"}]
        with patch.object(backup.os, "open", side_effect=denying):
            self.assertTrue(backup.source_plan(self.p, mounts=[])["ok"])

    def test_sqlite_backup_captures_committed_wal_and_is_private(self):
        source = self.source / "state ? #.db"
        live = sqlite3.connect(source)
        self.addCleanup(live.close)
        live.execute("PRAGMA journal_mode=WAL")
        live.execute("CREATE TABLE state (value TEXT)")
        live.execute("INSERT INTO state VALUES ('committed-in-wal')")
        live.commit()
        self.assertTrue(Path(str(source) + "-wal").exists())
        plan = backup.source_plan(self.p, mounts=[])
        self.assertEqual(plan["sqlite_files"], [str(source)])
        target = self.base / "snapshot.db"
        backup.sqlite_export(source, target)
        restored = sqlite3.connect(target)
        self.addCleanup(restored.close)
        self.assertEqual(restored.execute("SELECT value FROM state").fetchall(), [("committed-in-wal",)])
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        with self.assertRaises(FileExistsError):
            backup.sqlite_export(source, target)

    def test_docker_has_only_individual_readonly_sources_and_uid1000(self):
        argv = backup.docker_restic_argv(self.p, ["check"], container_name="owned-test")
        self.assertEqual(argv[argv.index("--user") + 1], "1000:1000")
        self.assertEqual(argv[argv.index("--network") + 1], "host")
        mounts = [argv[i + 1] for i, item in enumerate(argv) if item == "--mount"]
        self.assertIn("type=bind,src=" + str(self.source) + ",dst=" + str(self.source) + ",readonly", mounts)
        self.assertFalse(any("src=/home," in item or "src=/var/lib/docker," in item for item in mounts))
        self.assertNotIn("nonsecret-test-only-password", " ".join(argv))
        self.assertIn("StrictHostKeyChecking=yes", " ".join(argv))
        self.assertIn("UserKnownHostsFile=", " ".join(argv))
        self.assertIn("type=bind,src=" + self.p["work_dir"] + "/container-passwd,dst=/etc/passwd,readonly", mounts)
        self.assertIn("type=bind,src=" + self.p["work_dir"] + "/container-group,dst=/etc/group,readonly", mounts)
        self.assertFalse(any("src=/etc/passwd," in item or "src=/etc/group," in item for item in mounts))

    def test_generated_container_identity_is_minimal_private_and_idempotent(self):
        work = self.base / "identity-work"
        work.mkdir(mode=0o700)
        backup.ensure_container_identity(work)
        backup.ensure_container_identity(work)
        passwd = work / "container-passwd"
        group = work / "container-group"
        self.assertEqual(passwd.read_bytes(), backup.CONTAINER_IDENTITY["container-passwd"])
        self.assertIn(b"backup:x:1000:1000:", passwd.read_bytes())
        self.assertEqual(group.read_bytes(), b"root:x:0:\nbackup:x:1000:\n")
        self.assertEqual(stat.S_IMODE(passwd.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(group.stat().st_mode), 0o600)
        passwd.write_text("unexpected-account-record")
        with self.assertRaisesRegex(backup.BackupError, "generated_container_identity_invalid"):
            backup.ensure_container_identity(work)

    def test_failed_or_empty_native_dump_is_never_accepted(self):
        exports, logs = self.base / "exports", self.base / "logs"
        exports.mkdir(mode=0o700)
        logs.mkdir(mode=0o700)
        self.p["database_dumps"] = [{"name": "db", "argv": ["docker", "exec", "database", "native-dump"]}]
        def failed(argv, **kwargs):
            self.assertIs(kwargs["shell"], False)
            kwargs["stdout"].write(b"partial-sql-data")
            kwargs["stderr"].write(b"private-native-error")
            return subprocess.CompletedProcess(argv, 2)
        with self.assertRaisesRegex(backup.BackupError, "database_export_failed"):
            backup.database_exports(self.p, exports, logs, run=failed)
        self.assertEqual((exports / "db.sql").read_bytes(), b"partial-sql-data")

    def test_repository_open_failure_never_calls_init_or_database_export(self):
        def fail(*args, **kwargs):
            self.calls.append(args[2])
            raise backup.BackupError("auth_or_transport_failure")
        with patch.object(backup, "guarded", return_value={"ok": True}), \
                patch.object(backup, "restic", side_effect=fail), \
                patch.object(backup, "database_exports") as dumps:
            with self.assertRaisesRegex(backup.BackupError, "auth_or_transport_failure"):
                backup.perform(self.p)
            dumps.assert_not_called()
        self.assertEqual(self.calls, ["repository-open"])
        self.assertFalse((Path(self.p["work_dir"]) / "latest-success.json").exists())

    def test_initialization_requires_explicit_new_repository_flag(self):
        with patch.object(backup, "guarded", return_value={"ok": True}), patch.object(backup, "restic") as restic:
            with self.assertRaisesRegex(backup.BackupError, "explicit_new_repository"):
                backup.perform(self.p, init=True)
            restic.assert_not_called()

    def test_busy_backup_is_clean_noop_and_preserves_existing_writer(self):
        work = Path(self.p["work_dir"])
        work.mkdir(mode=0o700)
        runs = work / "runs"
        runs.mkdir(mode=0o700)
        first = runs / "first-running"
        first.mkdir(mode=0o700)
        exports = first / "exports"
        exports.mkdir(mode=0o700)
        original_export = exports / "database.sql"
        original_export.write_bytes(b"first-writer-private-output")
        latest = work / "latest-success.json"
        latest.write_text('{"snapshot_id":"previous-success"}')
        before_latest = latest.read_bytes()
        with open(work / "runner.lock", "w") as first_lock:
            fcntl.flock(first_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(backup, "guarded") as guard, \
                    patch.object(backup, "restic") as restic, \
                    patch.object(backup, "source_plan") as scan, \
                    patch.object(backup, "database_exports") as dumps:
                result = backup.perform(self.p, verify_restore=True)
                self.assertEqual(result, {"ok": True, "status": "skipped_busy", "operation": "backup"})
                guard.assert_not_called()
                restic.assert_not_called()
                scan.assert_not_called()
                dumps.assert_not_called()
                with self.assertRaisesRegex(backup.BackupError, "backup_already_running"):
                    backup.perform(self.p, init=True)
            # Closing the skipped invocation's descriptor must not release the
            # original writer's separate flock/open-file description.
            with open(work / "runner.lock", "r+") as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(list(runs.iterdir()), [first])
            self.assertFalse(list(runs.glob("*/SUCCESS.json")))
            self.assertFalse(list(runs.glob("*/FAILED.json")))
            self.assertEqual(latest.read_bytes(), before_latest)
            self.assertEqual(original_export.read_bytes(), b"first-writer-private-output")

    def test_backup_uses_approved_files_and_publishes_marker_verified_success(self):
        (self.source / "config.txt").write_text("included configuration")
        (self.source / "renamed-key.txt").write_text("-----BEGIN OPENSSH PRIVATE KEY-----\nnot-copied")
        (self.source / "empty").mkdir(mode=0o700)
        with patch.object(backup, "guarded", return_value={"ok": True}), \
                patch.object(backup, "restic", side_effect=self.fake_restic):
            result = backup.perform(self.p, verify_restore=True)
        self.assertTrue(result["ok"])
        self.assertTrue(result["restore_probe"]["ok"])
        self.assertEqual(result["repository_check"], "metadata")
        published = json.loads((Path(self.p["work_dir"]) / "latest-success.json").read_text())
        self.assertEqual(published["snapshot_id"], result["snapshot_id"])
        raw = (Path(result["stage"]) / "approved-files.raw").read_bytes().split(b"\0")
        self.assertIn(os.fsencode(self.source / "config.txt"), raw)
        self.assertNotIn(os.fsencode(self.source), raw)
        self.assertNotIn(os.fsencode(self.source / "renamed-key.txt"), raw)
        args = next(args for label, args, source in self.calls if label == "backup")
        self.assertIn("--files-from-raw", args)
        self.assertNotIn(str(self.source), args)
        self.assertFalse(any(command in args for command in ("forget", "prune", "unlock")))
        self.assertEqual(stat.S_IMODE((Path(self.p["work_dir"]) / "latest-success.json").stat().st_mode), 0o600)

    def test_final_volume_failure_does_not_publish_success(self):
        (self.source / "config").write_text("configuration")
        with patch.object(backup, "guarded", side_effect=[{"ok": True}] * 3 + [backup.GuardError("volume_identity_mismatch")]), \
                patch.object(backup, "restic", side_effect=self.fake_restic):
            with self.assertRaisesRegex(backup.BackupError, "volume_identity_mismatch"):
                backup.perform(self.p)
        work = Path(self.p["work_dir"])
        self.assertFalse((work / "latest-success.json").exists())
        self.assertEqual(len(list((work / "runs").glob("*/FAILED.json"))), 1)
        self.assertEqual(len(list((work / "runs").glob("*/SUCCESS.json"))), 0)
        failed = json.loads(next((work / "runs").glob("*/FAILED.json")).read_text())
        self.assertIs(failed["ok"], False)

    def test_timeout_cleans_up_only_runner_owned_container(self):
        stage = self.base / "stage"
        stage.mkdir()
        with patch.object(backup, "execute_private", side_effect=backup.BackupError("command_timed_out")), \
                patch.object(backup, "stop_owned_container", return_value=True) as cleanup:
            with self.assertRaisesRegex(backup.BackupError, "command_timed_out"):
                backup.restic(self.p, stage, "operation", ["check"])
        name = cleanup.call_args.args[0]
        self.assertRegex(name, r"^app-backup-[0-9a-f]{32}$")
        self.assertEqual(json.loads((stage / "operation.container.json").read_text())["container_name"], name)

    def test_literal_exclusions_escape_metacharacters_and_dollar_expansion(self):
        self.assertEqual(backup.literal_exclusion("/data/$HOME/[old]*?"), "/data/$$HOME/\\[old]\\*\\?")

    def test_restore_probe_rejects_wrong_bytes(self):
        a, b = self.base / "a", self.base / "b"
        a.write_bytes(b"expected")
        b.write_bytes(b"wrong")
        with self.assertRaisesRegex(backup.BackupError, "restored_marker_mismatch"):
            backup.verify_marker(a, b)


if __name__ == "__main__":
    unittest.main()
