#!/usr/bin/env python3
"""Validate a Windows backup volume over existing, strictly verified SSH."""
import base64
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path


class GuardError(ValueError):
    pass


def normalize_guid(value):
    value = str(value).strip()
    if value.lower().startswith("\\\\?\\volume{") and value.endswith("}\\"):
        value = value[11:-2]
    return str(uuid.UUID(value))


def load_profile(path):
    try:
        p = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(p, dict):
            raise ValueError()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", p["ssh_host"]):
            raise ValueError()
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", p["ssh_user"]):
            raise ValueError()
        for key in ("ssh_key", "known_hosts"):
            if not isinstance(p[key], str) or not os.path.isabs(p[key]) or any(c in p[key] for c in "\x00\r\n"):
                raise ValueError()
        letter = re.fullmatch(r"([A-Za-z]):?", p["drive_letter"])
        if not letter or not isinstance(p["volume_label"], str) or not p["volume_label"]:
            raise ValueError()
        if type(p["min_free_bytes"]) is not int or p["min_free_bytes"] < 0:
            raise ValueError()
        p["drive_letter"] = letter[1].upper()
        p["volume_guid"] = normalize_guid(p["volume_guid"])
        return p
    except (OSError, ValueError, TypeError, KeyError):
        raise GuardError("invalid_profile") from None


def ssh_command(p):
    script = (
        "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); "
        f"$v=@(Get-Volume -DriveLetter '{p['drive_letter']}' -ErrorAction Stop); "
        "if($v.Count -ne 1){throw 'volume_count'}; "
        "[pscustomobject]@{drive_letter=[string]$v[0].DriveLetter;"
        "volume_guid=[string]$v[0].UniqueId;volume_label=[string]$v[0].FileSystemLabel;"
        "free_bytes=[int64]$v[0].SizeRemaining}|ConvertTo-Json -Compress"
    )
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + p["known_hosts"],
            "-o", "ConnectTimeout=7", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "-i", p["ssh_key"],
            p["ssh_user"] + "@" + p["ssh_host"],
            "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded]


def query_volume(p, run=None):
    try:
        result = (run or subprocess.run)(ssh_command(p), capture_output=True, text=True,
                                        encoding="utf-8", timeout=25, check=False)
        if result.returncode:
            raise GuardError("ssh_query_failed")
        return json.loads(result.stdout.lstrip("\ufeff"))
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        raise GuardError("ssh_query_failed") from None
    except json.JSONDecodeError:
        raise GuardError("invalid_volume_response") from None


def validate_volume(p, actual):
    try:
        identity = (actual["drive_letter"].upper(), normalize_guid(actual["volume_guid"]), actual["volume_label"])
        if identity != (p["drive_letter"], p["volume_guid"], p["volume_label"]):
            raise GuardError("volume_identity_mismatch")
        free = actual["free_bytes"]
        if type(free) is not int or free < 0:
            raise ValueError()
        if free < p["min_free_bytes"]:
            raise GuardError("insufficient_free_space")
        return {"ok": True, "drive_letter": p["drive_letter"], "free_bytes": free,
                "min_free_bytes": p["min_free_bytes"]}
    except GuardError:
        raise
    except (TypeError, KeyError, ValueError, AttributeError):
        raise GuardError("invalid_volume_response") from None


def main(argv=None):
    try:
        args = sys.argv[1:] if argv is None else argv
        if len(args) != 1:
            raise GuardError("expected_profile_path")
        p = load_profile(args[0])
        summary = validate_volume(p, query_volume(p))
    except GuardError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1
    print(json.dumps(summary, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
