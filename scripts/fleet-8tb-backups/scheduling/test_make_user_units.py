import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from make_user_units import quote_exec_path, render_units, write_units


class UserUnitTests(unittest.TestCase):
    def units(self):
        return render_units("/opt/example-backup", "/home/example/private/hp.json",
                            "/home/example/private/pi.json")

    def test_schedules_and_backup_only(self):
        units = self.units()
        self.assertEqual(len(units), 4)
        self.assertIn("OnCalendar=*-*-* 04:15:00\n", units["afz-backup-hp-8tb.timer"])
        self.assertIn("OnCalendar=*-*-* *:40:00\n", units["afz-backup-pi-8tb.timer"])
        self.assertIn("RandomizedDelaySec=180s\n", units["afz-backup-pi-8tb.timer"])
        for name, contents in units.items():
            if name.endswith(".timer"):
                self.assertIn("Persistent=true\n", contents)
            else:
                self.assertIn("Type=oneshot\n", contents)
                self.assertIn("KillMode=control-group\n", contents)
                self.assertIn("UMask=0077\n", contents)
                self.assertNotIn("--init", contents)
                self.assertNotIn("--verify-restore", contents)
                self.assertNotIn("--check-data", contents)
                self.assertNotIn("--profile", contents)
                self.assertNotIn("RemainAfterExit", contents)

    def test_rejects_relative_or_injectable_paths(self):
        for path in ("relative", "/a/../b", "/a//b", "/a\nExecStart=/bin/false", "/a\x00b"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                render_units(path, "/private/hp.json", "/private/pi.json")

    def test_systemd_literal_expansions(self):
        self.assertEqual(quote_exec_path('/a/%h $HOME/"b"'),
                         '"/a/%%h $$HOME/\\"b\\""')

    def test_exclusive_private_output(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "units"
            write_units(destination, self.units())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
            for path in destination.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                write_units(destination, self.units())

    @unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze unavailable")
    def test_units_pass_systemd_parser(self):
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "units"
            write_units(destination, self.units())
            result = subprocess.run(["systemd-analyze", "verify", "--man=no",
                                     *map(str, sorted(destination.iterdir()))],
                                    capture_output=True, text=True, timeout=20,
                                    env={**os.environ, "SYSTEMD_LOG_LEVEL": "warning"})
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
