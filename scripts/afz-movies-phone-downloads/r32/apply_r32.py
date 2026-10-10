#!/usr/bin/env python3
"""Apply the tested phone-only R32 change to the exact preserved R29 source."""
from pathlib import Path
import hashlib, subprocess, sys
BASE = "10be7a7b0dfb650117c872705efaf9a1cc272f47"
PATCH_SHA256 = "e2059cd79b55466431d56ae0c79b6310b5c38367aa7c19df1d1979529bbfca91"
root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None
if root is None:
    raise SystemExit("Usage: python3 apply_r32.py /path/to/preserved-r29-source")
def git(*args):
    return subprocess.check_output(["git", "-c", "core.filemode=false", *args], cwd=root, text=True)
if git("rev-parse", "HEAD").strip() != BASE:
    raise SystemExit("Source HEAD differs from the preserved R29 base. Review/rebase first.")
if git("status", "--porcelain").strip():
    raise SystemExit("Source checkout has changes; refusing to overwrite.")
patch = Path(__file__).with_name("phone-first-r32.patch")
if hashlib.sha256(patch.read_bytes()).hexdigest() != PATCH_SHA256:
    raise SystemExit("Patch checksum mismatch.")
git("apply", "--check", str(patch))
git("apply", str(patch))
git("diff", "--check")
print("R32 phone-only ordering applied. Build and test before installing.")
