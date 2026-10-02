#!/usr/bin/env python3
"""Apply the reviewed R27 phone picker fix to an unchanged AFZ R26 checkout."""
import argparse
from pathlib import Path
import subprocess

BASE = "0c3340c3364205de5be368a84f74293372f504b2"
parser = argparse.ArgumentParser()
parser.add_argument("source_dir", type=Path)
args = parser.parse_args()
source = args.source_dir.resolve()
patch = Path(__file__).with_name("phone-download-ranking-r27.patch")
def git(*args):
    return subprocess.check_output(["git", *args], cwd=source, text=True).strip()
if git("rev-parse", "HEAD") != BASE:
    raise SystemExit("This patch requires the reviewed R26 head; review newer source before applying.")
if git("status", "--porcelain", "--untracked-files=all"):
    raise SystemExit("Source has local changes; leave them intact and use a clean worktree.")
git("apply", "--check", str(patch))
git("apply", str(patch))
git("diff", "--check")
print("R27 source applied. Build with the existing AFZ SDK and signing key, then run the regression gate before installing.")
