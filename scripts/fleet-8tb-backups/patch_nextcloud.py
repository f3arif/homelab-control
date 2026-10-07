#!/usr/bin/env python3
"""Make the bounded network/volume-guard patch; leave backup actions intact."""
import argparse
import os
import shlex
import stat
from pathlib import Path

FLOCK = "flock -n 9 || exit 0"
MARKER = 'cat >"$BASE/last-h3-backup.json" <<EOF'
DOCKER = "docker run --rm"


def patch_nextcloud(source, guard_path, profile_path):
    for path in (guard_path, profile_path):
        if not os.path.isabs(path) or any(c in path for c in "\x00\r\n"):
            raise ValueError("guard and profile paths must be absolute single-line paths")
    lines = source.splitlines(keepends=True)
    plain = [line.rstrip("\r\n") for line in lines]
    if plain.count(FLOCK) != 1 or plain.count(MARKER) != 1 or source.count(DOCKER) != 1:
        raise ValueError("expected exactly one flock, success marker, and Docker anchor")
    if plain.index(FLOCK) >= plain.index(MARKER):
        raise ValueError("success marker precedes backup lock")
    docker_line = next(line for line in plain if DOCKER in line)
    if "--network" in docker_line or "--net=" in docker_line:
        raise ValueError("Docker network already configured; refusing duplicate patch")
    invocation = "python3 " + shlex.quote(guard_path) + " " + shlex.quote(profile_path) + " || exit $?"
    out = []
    for line, body in zip(lines, plain):
        newline = "\r\n" if line.endswith("\r\n") else "\n"
        if body == MARKER:
            out.append(invocation + newline)
        out.append(line.replace(DOCKER, DOCKER + " --network host"))
        if body == FLOCK:
            out.append(invocation + newline)
    return "".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "output", "guard_path", "profile_path"):
        parser.add_argument(name)
    args = parser.parse_args()
    src, dst = Path(args.source), Path(args.output)
    if src.resolve() == dst.resolve():
        parser.error("output must differ from source")
    result = patch_nextcloud(src.read_bytes().decode("utf-8"), args.guard_path, args.profile_path)
    dst.write_bytes(result.encode("utf-8"))
    dst.chmod(stat.S_IMODE(src.stat().st_mode))


if __name__ == "__main__":
    main()
