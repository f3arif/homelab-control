#!/usr/bin/env python3
"""Capture encrypted restic files without decrypting or changing the source.

A stage is accepted only when COMPLETE exists and INCOMPLETE does not. The
observer must return JSON with idle=true and stable evidence identifying the
known writers. Observation is not an exclusive repository lock or restore test.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess


PERSISTENT_DIRS = ("keys", "data", "index", "snapshots")
QUALIFICATION = "stable observed capture; no exclusive writer lock"


class CaptureError(RuntimeError):
    pass


def _no_symlink_path(path):
    for part in (path, *path.parents):
        if part.is_symlink():
            raise CaptureError(f"Symlink rejected: {part}")


def _locks_empty(root):
    locks = root / "locks"
    if locks.is_symlink() or not locks.is_dir():
        raise CaptureError("A real locks directory is required")
    if any(locks.iterdir()):
        raise CaptureError("Repository locks are not empty")


def _layout(root):
    _no_symlink_path(root)
    if not root.is_dir():
        raise CaptureError("Source is not a directory")
    _locks_empty(root)
    allowed = {"config", "locks", "tmp", *PERSISTENT_DIRS}
    for entry in root.iterdir():
        if entry.name not in allowed:
            raise CaptureError(f"Unexpected repository entry: {entry.name}")
    if not (root / "config").is_file():
        raise CaptureError("Repository config is missing")
    for name in PERSISTENT_DIRS:
        if not (root / name).is_dir():
            raise CaptureError(f"Repository directory is missing: {name}")
    for current, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            item = Path(current) / name
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise CaptureError(f"Symlink rejected: {item}")
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise CaptureError(f"Nonregular repository entry: {item}")


def _read_file(path, output=None):
    _no_symlink_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise CaptureError(f"Not a regular file: {path}")
        digest = hashlib.sha256()
        size = 0
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
            size += len(block)
            if output is not None:
                output.write(block)
        after = os.fstat(source.fileno())
        signature = lambda s: (s.st_dev, s.st_ino, s.st_size,
                               s.st_mtime_ns, s.st_ctime_ns)
        if signature(before) != signature(after) or size != after.st_size:
            raise CaptureError(f"File changed while reading: {path}")
    return {"size": size, "sha256": digest.hexdigest()}


def manifest(root):
    """Return persistent-file hashes, rejecting locks and noncanonical objects."""
    root = Path(root)
    _layout(root)
    paths = [root / "config"]
    for name in PERSISTENT_DIRS:
        paths.extend(p for p in (root / name).rglob("*") if p.is_file())
    result = {}
    for path in sorted(paths):
        _locks_empty(root)
        relative = path.relative_to(root).as_posix()
        value = _read_file(path)
        if relative != "config" and (
                re.fullmatch(r"[0-9a-f]{64}", path.name) is None or
                value["sha256"] != path.name):
            raise CaptureError(f"Invalid content-addressed object: {relative}")
        result[relative] = value
    _locks_empty(root)
    return result


def _observe(observer):
    value = json.loads(json.dumps(observer(), allow_nan=False, sort_keys=True))
    if not isinstance(value, dict) or value.get("idle") is not True:
        raise CaptureError("Writer observer did not confirm idle=true")
    return value


def _write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def capture(source, destination, observer):
    """Create a new stage and verify it against stable source/writer observations.

    Never replaces an existing destination. Failed stages remain INCOMPLETE;
    no source file, lock, timer, password, or prior generation is changed.
    """
    source = Path(source).absolute()
    destination = Path(destination).absolute()
    _no_symlink_path(source)
    _no_symlink_path(destination)
    resolved_source = source.resolve(strict=True)
    resolved_destination = destination.resolve()
    if (resolved_source == resolved_destination or
            resolved_source in resolved_destination.parents or
            resolved_destination in resolved_source.parents):
        raise CaptureError("Source and destination must be separate trees")
    destination.mkdir(mode=0o700)
    incomplete = destination / "INCOMPLETE"
    incomplete.write_text("Capture is not verified.\n", encoding="utf-8")
    try:
        observed_before = _observe(observer)
        before = manifest(source)
        repo = destination / "repo"
        repo.mkdir(mode=0o700)
        for name in (*PERSISTENT_DIRS, "locks", "tmp"):
            (repo / name).mkdir(mode=0o700)
        for relative, expected in before.items():
            _locks_empty(source)
            target = repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as output:
                actual = _read_file(source / relative, output)
                output.flush()
                os.fsync(output.fileno())
            if actual != expected:
                raise CaptureError(f"Source changed during copying: {relative}")
        if manifest(repo) != before:
            raise CaptureError("Staged bytes differ from the source manifest")
        after = manifest(source)
        observed_after = _observe(observer)
        _locks_empty(source)
        if before != after:
            raise CaptureError("Source manifest changed during capture")
        if observed_before != observed_after:
            raise CaptureError("Writer observation changed during capture")
        metadata = {
            "schema": 1,
            "qualification": QUALIFICATION,
            "restic_decryption_or_restore_tested": False,
            "source": str(source),
            "captured_utc": datetime.now(timezone.utc).isoformat(),
            "observer_before": observed_before,
            "observer_after": observed_after,
            "file_count": len(before),
            "total_bytes": sum(item["size"] for item in before.values()),
            "files": before,
        }
        _write_json(destination / "manifest.json", metadata)
        _write_json(destination / "COMPLETE", {
            "qualification": QUALIFICATION,
            "manifest_sha256": _read_file(destination / "manifest.json")["sha256"],
        })
        incomplete.unlink()
        return metadata
    except BaseException:
        # Never turn a partially copied stage into a usable generation.
        (destination / "COMPLETE").unlink(missing_ok=True)
        if not incomplete.exists():
            incomplete.write_text("Capture failed; not verified.\n", encoding="utf-8")
        raise


def command_observer(argv):
    """Run a JSON observer without a shell; do not include secrets in its output."""
    if not isinstance(argv, list) or not argv or not all(
            isinstance(item, str) and item for item in argv):
        raise ValueError("Observer command must be a nonempty JSON string array")

    def observe():
        result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise CaptureError(f"Observer command failed (exit {result.returncode})")
        return json.loads(result.stdout)
    return observe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--observer-command", required=True,
                        help="JSON argv array; command returns stable JSON with idle=true")
    args = parser.parse_args()
    try:
        observer = command_observer(json.loads(args.observer_command))
        result = capture(args.source, args.destination, observer)
    except Exception as exc:
        parser.exit(1, f"Capture failed: {exc}\n")
    print(json.dumps({"status": "complete", "destination": str(args.destination),
                      "qualification": result["qualification"],
                      "file_count": result["file_count"],
                      "total_bytes": result["total_bytes"]}))


if __name__ == "__main__":
    main()
