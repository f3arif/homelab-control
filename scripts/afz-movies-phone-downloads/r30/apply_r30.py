#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

BASE = "10be7a7b0dfb650117c872705efaf9a1cc272f47"
HERE = Path(__file__).resolve().parent
PATCH = HERE / "tv-download-r30.patch"

def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True)

def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: apply_r30.py /path/to/nuvio-source")
    repo = Path(sys.argv[1]).resolve()
    head = run("git", "rev-parse", "HEAD", cwd=repo)
    if head.returncode or head.stdout.strip() != BASE:
        raise SystemExit(f"refusing restore: expected exact R29 HEAD {BASE}, got {head.stdout.strip() or 'unreadable'}")
    status = run("git", "status", "--porcelain", cwd=repo)
    if status.returncode or status.stdout.strip():
        raise SystemExit("refusing restore: source tree is not clean")
    check = run("git", "apply", "--check", str(PATCH), cwd=repo)
    if check.returncode:
        raise SystemExit("restore apply-check failed:\n" + check.stderr)
    apply_result = run("git", "apply", str(PATCH), cwd=repo)
    if apply_result.returncode:
        raise SystemExit("restore apply failed:\n" + apply_result.stderr)
    diff_check = run("git", "diff", "--check", cwd=repo)
    if diff_check.returncode:
        raise SystemExit("restored tree failed git diff --check:\n" + diff_check.stdout + diff_check.stderr)
    print("R30 restore applied cleanly on exact R29 base.")

if __name__ == "__main__":
    main()
