"""Process-level checks for recovery retries and shutdown without orphan children."""
import contextlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SUPERVISOR = Path(__file__).with_name("supervisor.py")


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("condition not reached before timeout")

    @contextlib.contextmanager
    def running(self, code, initial="0.05", maximum="0.10"):
        log = self.root / "supervisor.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [sys.executable, str(SUPERVISOR), "--initial-delay", initial,
                 "--max-delay", maximum, "--stop-timeout", "0.20", "--",
                 sys.executable, "-u", "-c", code, str(self.root)],
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                yield process, log
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=3)

    def assert_gone(self, pid):
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_retries_until_address_ready_and_then_stays_running(self):
        code = """
import os, pathlib, sys, time
p = pathlib.Path(sys.argv[1])
with (p / 'attempts').open('a') as f: f.write('start\\n')
if not (p / 'address-ready').exists():
    print('Cannot assign requested address', flush=True)
    sys.exit(1)
(p / 'ready').write_text(str(os.getpid()))
time.sleep(30)
"""
        with self.running(code) as (process, log):
            attempts = self.root / "attempts"
            self.until(lambda: attempts.exists() and
                       len(attempts.read_text().splitlines()) >= 2)
            (self.root / "address-ready").touch()
            ready = self.root / "ready"
            self.until(ready.exists)
            pid = int(ready.read_text())
            count = attempts.read_text()
            time.sleep(0.25)
            self.assertEqual(attempts.read_text(), count)
            self.assertIsNone(process.poll())
            self.assertIn("status 1; restart in 0.05s", log.read_text())
            process.terminate()
            self.assertEqual(process.wait(timeout=3), 0)
            self.assert_gone(pid)

    def test_clean_exits_restart_with_bounded_backoff(self):
        code = """
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'attempts'
with p.open('a') as f: f.write('start\\n')
"""
        with self.running(code) as (process, log):
            self.until(lambda: log.read_text().count("restart in") >= 4)
            process.terminate()
            self.assertEqual(process.wait(timeout=3), 0)
            messages = log.read_text().splitlines()
            self.assertIn("status 0; restart in 0.05s", messages[0])
            self.assertTrue(all("status 0; restart in 0.10s" in line
                                for line in messages[1:]))

    def test_term_and_int_are_forwarded_and_children_reaped(self):
        code = """
import os, pathlib, signal, sys, time
p = pathlib.Path(sys.argv[1])
def stop(number, frame):
    (p / 'signal').write_text(str(number))
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
(p / 'ready').write_text(str(os.getpid()))
time.sleep(30)
"""
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum), self.running(code) as (process, _):
                ready = self.root / "ready"
                self.until(ready.exists)
                pid = int(ready.read_text())
                process.send_signal(signum)
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(int((self.root / "signal").read_text()), signum)
                self.assert_gone(pid)
                ready.unlink()

    def test_uncooperative_child_is_killed_and_reaped(self):
        code = """
import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
(pathlib.Path(sys.argv[1]) / 'ready').write_text(str(os.getpid()))
time.sleep(30)
"""
        with self.running(code) as (process, _):
            ready = self.root / "ready"
            self.until(ready.exists)
            pid = int(ready.read_text())
            process.terminate()
            self.assertEqual(process.wait(timeout=3), 0)
            self.assert_gone(pid)

    def test_stop_during_backoff_returns_without_another_child(self):
        code = """
import pathlib, sys
with (pathlib.Path(sys.argv[1]) / 'attempts').open('a') as f: f.write('start\\n')
sys.exit(1)
"""
        with self.running(code, initial="10", maximum="10") as (process, log):
            self.until(lambda: "restart in 10.00s" in log.read_text())
            process.terminate()
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertEqual((self.root / "attempts").read_text(), "start\n")


if __name__ == "__main__":
    unittest.main()
