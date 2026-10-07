import base64
import os
from pathlib import Path
import tempfile
import unittest
from escrow_password import escrow_command, password_bytes


class PasswordTests(unittest.TestCase):
    def test_private_create_and_preserve(self):
        with tempfile.TemporaryDirectory() as name:
            target = Path(name) / "password"
            first = password_bytes(target)
            self.assertEqual(len(first), 64)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(first, password_bytes(target))

    def test_reject_public_parent_and_symlink(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            root.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "private"):
                password_bytes(root / "password")
            root.chmod(0o700)
            target = root / "password"
            target.symlink_to(root / "elsewhere")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                password_bytes(target)

    def test_reject_loose_existing_password_mode(self):
        with tempfile.TemporaryDirectory() as name:
            target = Path(name) / "password"
            target.write_text("x" * 64)
            target.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "0600"):
                password_bytes(target)

    def test_remote_stdin_and_verified_ssh(self):
        p = dict(ssh_host="backup.example.test", ssh_user="Backup", ssh_key="/keys/existing",
                 known_hosts="/keys/known_hosts", drive_letter="F", volume_guid="11111111-1111-1111-1111-111111111111",
                 volume_label="Test' Media", min_free_bytes=1024, escrow_windows_path="F:\\Backups\\recovery\\password.dpapi")
        argv = escrow_command(p)
        self.assertIn("StrictHostKeyChecking=yes", argv)
        code = base64.b64decode(argv[-1].split()[-1]).decode("utf-16le")
        self.assertIn("[Console]::In.ReadToEnd()", code)
        self.assertIn("[IO.FileMode]::CreateNew", code)
        self.assertIn("Test'' Media", code)
        self.assertNotIn("password_file", code)
        p["escrow_windows_path"] = "G:\\Backups\\wrong"
        with self.assertRaises(ValueError):
            escrow_command(p)


if __name__ == "__main__":
    unittest.main()
