#!/usr/bin/env python3
"""Render new systemd user backup units; never install or enable them.

Both runners accept one positional private profile and own a whole-run lock.
Initialization and restore/data verification are explicit first-run operations,
not timer actions. Calendar times use the host's configured local time zone.
"""
import argparse
import os
from pathlib import Path, PurePosixPath


def absolute_path(value):
    if (not isinstance(value, str) or not value.startswith("/") or
            any(ord(c) < 32 or ord(c) == 127 for c in value) or
            ".." in PurePosixPath(value).parts or str(PurePosixPath(value)) != value):
        raise ValueError("paths must be normalized absolute paths without control characters")
    return value


def quote_exec_path(value):
    """Quote one ExecStart argument without environment/specifier expansion."""
    value = absolute_path(value).replace("%", "%%").replace("$", "$$")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_units(deployment_dir, hp_profile, pi_profile, python="/usr/bin/python3"):
    deployment_dir = absolute_path(deployment_dir)
    absolute_path(python)
    result = {}
    for role, profile, calendar, delay, cap in (
        ("hp", hp_profile, "*-*-* 04:15:00", "0", "12h"),
        ("pi", pi_profile, "*-*-* *:40:00", "180s", "90min"),
    ):
        name = "afz-backup-" + role + "-8tb"
        command = " ".join(quote_exec_path(item) for item in
                           (python, deployment_dir + "/backup_" + role + ".py", profile))
        result[name + ".service"] = f"""[Unit]
Description=Append {role.upper()} backup to verified secondary volume

[Service]
Type=oneshot
ExecStart={command}
UMask=0077
Environment=PYTHONUNBUFFERED=1
StandardInput=null
StandardOutput=journal
StandardError=journal
TimeoutStartSec={cap}
TimeoutStopSec=60s
KillMode=control-group
Restart=no
"""
        result[name + ".timer"] = f"""[Unit]
Description=Schedule {role.upper()} backup to verified secondary volume

[Timer]
OnCalendar={calendar}
RandomizedDelaySec={delay}
AccuracySec=1s
Persistent=true
Unit={name}.service

[Install]
WantedBy=timers.target
"""
    return result


def write_units(output_dir, units):
    """Require a new directory so prior units cannot be overwritten."""
    output_dir = Path(output_dir)
    if not output_dir.is_absolute() or any(p.is_symlink() for p in (output_dir, *output_dir.parents)):
        raise ValueError("output directory must be absolute and contain no symlink")
    output_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
    for name, contents in units.items():
        descriptor = os.open(output_dir / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(contents)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment-dir", required=True)
    parser.add_argument("--hp-profile", required=True)
    parser.add_argument("--pi-profile", required=True)
    parser.add_argument("--output-dir", required=True, help="New absolute directory; must not exist")
    parser.add_argument("--python", default="/usr/bin/python3")
    args = parser.parse_args()
    try:
        units = render_units(args.deployment_dir, args.hp_profile, args.pi_profile, args.python)
        write_units(args.output_dir, units)
    except (ValueError, OSError) as exc:
        parser.exit(1, "Unit rendering failed: " + type(exc).__name__ + "\n")
    print("Rendered four user units; no installation, enablement, or backup was performed.")


if __name__ == "__main__":
    main()
