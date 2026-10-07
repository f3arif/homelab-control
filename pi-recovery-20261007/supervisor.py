#!/usr/bin/env python3
"""Keep the sibling recovery server running while its bind address becomes ready."""
import argparse
import math
from pathlib import Path
import signal
import subprocess
import sys
import time


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initial-delay", type=float, default=2.0)
    parser.add_argument("--max-delay", type=float, default=30.0)
    parser.add_argument("--stop-timeout", type=float, default=5.0)
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="optional child command after --")
    args = parser.parse_args(argv)
    values = (args.initial_delay, args.max_delay, args.stop_timeout)
    if not all(math.isfinite(n) and n > 0 for n in values):
        parser.error("delays and stop timeout must be finite and positive")
    if args.initial_delay > args.max_delay:
        parser.error("initial delay must not exceed maximum delay")
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    command = command or [sys.executable, "-u",
                          str(Path(__file__).resolve().with_name("server.py"))]
    stopping = False
    stop_signal = signal.SIGTERM

    def request_stop(signum, _frame):
        nonlocal stop_signal, stopping
        stop_signal = signum
        stopping = True

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, request_stop)

    delay = args.initial_delay
    while not stopping:
        child = None
        started = time.monotonic()
        try:
            child = subprocess.Popen(command)
            while True:
                if stopping:
                    child.send_signal(stop_signal)
                    try:
                        child.wait(timeout=args.stop_timeout)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                    return 0
                try:
                    code = child.wait(timeout=0.2)
                    reason = f"child exited with status {code}"
                    break
                except subprocess.TimeoutExpired:
                    pass
        except OSError as exc:
            reason = f"child start failed: {exc}"
        finally:
            if child is not None and child.poll() is None:
                child.kill()
                child.wait()
        if stopping:
            break
        if time.monotonic() - started >= 60:
            delay = args.initial_delay
        print(f"[recovery-supervisor] {reason}; restart in {delay:.2f}s",
              file=sys.stderr, flush=True)
        deadline = time.monotonic() + delay
        while not stopping:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(remaining, 0.2))
        delay = min(delay * 2, args.max_delay)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
