#!/usr/bin/env python3
"""Read-only H3 legacy-state probe for migration planning.

This program intentionally has no Control Hub claim/complete client and no
subprocess execution. It only snapshots legacy files supplied on the command
line so parity work can proceed without creating a second execution fabric.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_key_value_heartbeat(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("=") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key and key.replace("_", "").isalnum():
            result[key] = value
    return result


def inspect_file(path: Path, *, heartbeat: bool = False) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "exists": False}
    data = path.read_bytes()
    result: dict[str, Any] = {
        "path": str(path),
        "exists": True,
        "bytes": len(data),
        "sha256": _sha256(path),
    }
    if heartbeat:
        text = data.decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text)
            result["heartbeat_format"] = "json"
            result["heartbeat"] = parsed
        except json.JSONDecodeError:
            result["heartbeat_format"] = "key-value"
            result["heartbeat"] = _parse_key_value_heartbeat(text)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy-heartbeat", type=Path)
    parser.add_argument("--legacy-script", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    snapshot: dict[str, Any] = {
        "schema": "afz-h3-python-shadow-probe-v1",
        "mode": "read-only-shadow",
        "claims_jobs": False,
        "owns_scheduler": False,
        "owns_leases": False,
        "installs_service": False,
        "heartbeat": inspect_file(args.legacy_heartbeat, heartbeat=True)
        if args.legacy_heartbeat
        else None,
        "legacy_scripts": [inspect_file(path) for path in args.legacy_script],
    }
    encoded = json.dumps(snapshot, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
