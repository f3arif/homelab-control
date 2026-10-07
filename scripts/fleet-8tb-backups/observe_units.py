#!/usr/bin/env python3
"""Read stable boot and systemd writer state without reading protected scripts.

Invoke on the writer host: python3 observe_units.py EXPECTED_HOST UNIT [UNIT...].
The complete output is suitable for capture_restic's before/after observer.
"""
import json
from pathlib import Path
import re
import socket
import subprocess
import sys


FIELDS = ("Id", "LoadState", "ActiveState", "SubState", "InvocationID",
          "ExecMainStartTimestampMonotonic", "ExecMainExitTimestampMonotonic", "Result")


def observe(expected_host, units):
    if not units or any(re.fullmatch(r"[A-Za-z0-9_.@:-]+\.service", u) is None for u in units):
        raise ValueError("invalid_writer_units")
    host = socket.gethostname()
    if host != expected_host:
        raise ValueError("writer_host_mismatch")
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    if re.fullmatch(r"[0-9a-f-]{36}", boot) is None:
        raise ValueError("invalid_boot_identity")
    observed = {}
    for unit in sorted(units):
        result = subprocess.run(["systemctl", "show", unit, "--no-pager", "--property=" + ",".join(FIELDS)],
                                capture_output=True, text=True, timeout=10, check=False)
        if result.returncode:
            raise ValueError("writer_state_unavailable")
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        if set(values) != set(FIELDS) or values["Id"] != unit or values["LoadState"] != "loaded":
            raise ValueError("invalid_writer_state")
        observed[unit] = values
    if Path("/proc/sys/kernel/random/boot_id").read_text().strip() != boot:
        raise ValueError("boot_identity_changed")
    idle = all(v["ActiveState"] == "inactive" and v["SubState"] == "dead" for v in observed.values())
    return {"idle": idle, "host": host, "boot_id": boot, "units": observed}


def main():
    try:
        print(json.dumps(observe(sys.argv[1], sys.argv[2:]), sort_keys=True, separators=(",", ":")))
    except Exception:
        print(json.dumps({"idle": False, "error": "writer_observation_failed"}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
