#!/usr/bin/env python3
"""Detached, single-host jobs. Resume means inspect, never replay.

Linux + Python 3.10+ + an existing systemd user manager are required.
The supplied shell script must be reviewed and authorized before submission.
This is not a sandbox, a fleet-wide writer lease, or a publication authority.
"""
from __future__ import annotations
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

VERSION = "1.0.0"
TERMINAL = {"COMPLETED", "FAILED", "BLOCKED", "VERIFY_REQUIRED"}


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def identifier(value: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,79}", value):
        raise ValueError("Use 1-80 lowercase letters, digits, underscores or hyphens.")
    return value


def root_dir() -> Path:
    p = Path(os.environ.get("AFZ_JOB_ROOT", str(Path.home() / ".local/state/afz-safe-jobs"))).expanduser().resolve()
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def atomic(path: Path, value: dict) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


@contextlib.contextmanager
def locked(path: Path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def manager_env() -> dict:
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
    env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + env["XDG_RUNTIME_DIR"] + "/bus"
    return env


def unit_state(unit: str) -> dict:
    try:
        p = subprocess.run(["systemctl", "--user", "show", unit,
            "--property=LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus"],
            env=manager_env(), capture_output=True, text=True, timeout=5)
        result = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
        return result if p.returncode == 0 else {"query": "unavailable"}
    except (OSError, subprocess.TimeoutExpired):
        return {"query": "unavailable"}


def status(root: Path, job_id: str, inspect_unit: bool = True) -> dict:
    job = root / identifier(job_id)
    spec, state = load(job / "manifest.json"), load(job / "state.json")
    live = unit_state(spec["unit"]) if inspect_unit else {}
    effective = state["status"]
    if inspect_unit and effective not in TERMINAL:
        if live.get("query") == "unavailable":
            effective = "UNKNOWN_VERIFY_FIRST"
        elif live.get("ActiveState") not in {"active", "activating", "reloading"}:
            effective = "VERIFY_REQUIRED"
    return {"job_id": job_id, "project": spec["project"], "stored": state,
        "effective_status": effective, "systemd": live, "job_dir": str(job),
        "checkpoint": load(job / "checkpoint.json") if (job / "checkpoint.json").is_file() else None,
        "log": str(job / "job.log"), "automatic_replay": False,
        "next": "Read saved evidence and verify the external result before any new action."}


def submit(root: Path, job_id: str, project: str, script: Path,
           timeout: int, effect: str, cwd: Path, launch: bool = True) -> dict:
    identifier(job_id)
    identifier(project)
    if not 1 <= timeout <= 604800:
        raise ValueError("Timeout must be 1-604800 seconds.")
    if effect not in {"read-only", "local-change"}:
        raise ValueError("Unknown effect classification.")
    if not cwd.is_dir() or not script.is_file():
        raise ValueError("Script and working directory must exist.")
    payload = script.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    request = {"project": project, "script_sha256": digest,
               "timeout_seconds": timeout, "effect": effect, "cwd": str(cwd.resolve())}
    job = root / job_id
    with locked(root / ".submit.lock"):
        if job.exists():
            old = load(job / "manifest.json")
            if any(old.get(k) != v for k, v in request.items()):
                raise ValueError("Job ID already exists with different inputs; nothing was changed.")
            return {"existing": True, **status(root, job_id, inspect_unit=launch)}
        job.mkdir(mode=0o700)
        unit = "afz-safe-" + hashlib.sha256(job_id.encode()).hexdigest()[:24] + ".service"
        spec = {**request, "version": VERSION, "job_id": job_id, "unit": unit, "created": now()}
        for name, data in (("payload.sh", payload), ("runner.py", Path(__file__).read_bytes())):
            fd = os.open(job / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
        atomic(job / "manifest.json", spec)
        atomic(job / "state.json", {"status": "SUBMITTED", "phase": "awaiting-worker", "updated": now()})
        if launch:
            command = ["systemd-run", "--user", "--quiet", "--collect", "--unit=" + unit,
                "--property=Type=exec", "--property=Restart=no", "--property=UMask=0077",
                "--property=KillMode=control-group", "--property=TimeoutStopSec=10s",
                sys.executable, str(job / "runner.py"), "--root", str(root), "_run", job_id]
            try:
                p = subprocess.run(command, env=manager_env(), capture_output=True, text=True, timeout=8)
                receipt = {"returncode": p.returncode, "updated": now(),
                           "accepted": p.returncode == 0, "stderr": p.stderr[-2000:]}
            except (OSError, subprocess.TimeoutExpired) as e:
                receipt = {"accepted": None, "updated": now(), "error_type": type(e).__name__}
            atomic(job / "launch.json", receipt)
        return {"existing": False, "job_id": job_id, "job_dir": str(job),
                "next": "Use status or resume with this same ID; do not submit a replacement."}


def worker(root: Path, job_id: str) -> int:
    job = root / identifier(job_id)
    spec = load(job / "manifest.json")
    identifier(spec["project"])
    def save(label: str, **extra) -> None:
        atomic(job / "state.json", {"status": label, "updated": now(), **extra})
    try:
        with locked(root / (".project-" + spec["project"] + ".lock")):
            # A second invocation must not rerun completed OR uncertain work.
            if load(job / "state.json")["status"] != "SUBMITTED":
                return 0
            if hashlib.sha256((job / "payload.sh").read_bytes()).hexdigest() != spec["script_sha256"]:
                save("BLOCKED", reason="Script snapshot hash mismatch")
                return 2
            started = now()
            save("RUNNING", phase="starting-script", started=started)
            env = os.environ.copy()
            env.update(AFZ_JOB_ID=job_id, AFZ_JOB_DIR=str(job), AFZ_JOB_ROOT=str(root))
            child = None
            def stopped(signum, frame):
                raise InterruptedError(f"signal-{signum}")
            previous = signal.signal(signal.SIGTERM, stopped)
            try:
                with (job / "job.log").open("ab", buffering=0) as log:
                    os.chmod(job / "job.log", 0o600)
                    child = subprocess.Popen(["/bin/bash", "--noprofile", "--norc", str(job / "payload.sh")],
                        cwd=spec["cwd"], env=env, stdin=subprocess.DEVNULL,
                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    deadline = time.monotonic() + spec["timeout_seconds"]
                    while child.poll() is None:
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Script runtime budget exceeded")
                        save("RUNNING", phase="executing-script", started=started, child_pid=child.pid)
                        time.sleep(min(2, max(0.05, deadline - time.monotonic())))
                    label = "COMPLETED" if child.returncode == 0 else (
                        "FAILED" if spec["effect"] == "read-only" else "VERIFY_REQUIRED")
                    save(label, phase="script-exited", started=started, exit_code=child.returncode,
                        result_scope="Script exit only; external effects require separate verification.")
                    return 0 if child.returncode == 0 else 1
            except (OSError, TimeoutError, InterruptedError, KeyboardInterrupt) as e:
                save("VERIFY_REQUIRED", reason=type(e).__name__, started=started)
                if child is not None and child.poll() is None:
                    try:
                        os.killpg(child.pid, signal.SIGTERM)
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=3)
                    except ProcessLookupError:
                        pass
                return 2
            finally:
                signal.signal(signal.SIGTERM, previous)
    except BlockingIOError:
        # Never overwrite state owned by a worker already running this same job.
        if load(job / "state.json")["status"] == "SUBMITTED":
            save("BLOCKED", reason="Another job holds this project lock; no automatic retry.")
        return 3


def main() -> int:
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root")
    sub = p.add_subparsers(dest="action", required=True)
    s = sub.add_parser("submit")
    s.add_argument("job_id")
    s.add_argument("--project", required=True)
    s.add_argument("--script", type=Path, required=True)
    s.add_argument("--cwd", type=Path, default=Path.home())
    s.add_argument("--timeout", type=int, default=1800)
    s.add_argument("--effect", choices=["read-only", "local-change"], default="read-only")
    s.add_argument("--acknowledge-local-change", action="store_true")
    c = sub.add_parser("checkpoint")
    c.add_argument("job_id")
    c.add_argument("--phase", required=True)
    c.add_argument("--next-step", required=True)
    c.add_argument("--evidence", type=Path, required=True)
    for action in ("status", "resume", "_run"):
        sub.add_parser(action).add_argument("job_id")
    args = p.parse_args()
    if args.root:
        os.environ["AFZ_JOB_ROOT"] = args.root
    root = root_dir()
    try:
        if args.action == "_run":
            return worker(root, args.job_id)
        if args.action == "checkpoint":
            job = root / identifier(args.job_id)
            load(job / "manifest.json")
            evidence = args.evidence.expanduser().resolve()
            result = {"phase": args.phase, "next_step": args.next_step, "updated": now(),
                "evidence": str(evidence), "evidence_sha256": hashlib.sha256(evidence.read_bytes()).hexdigest(),
                "scope": "Caller observation; revalidate live state before new actions."}
            atomic(job / "checkpoint.json", result)
        elif args.action == "submit":
            if args.effect == "local-change" and not args.acknowledge_local_change:
                p.error("Local changes require explicit authorization and --acknowledge-local-change.")
            result = submit(root, args.job_id, args.project, args.script.expanduser().resolve(),
                            args.timeout, args.effect, args.cwd.expanduser().resolve())
        else:
            result = status(root, args.job_id)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
        print(json.dumps({"error": str(e), "automatic_replay": False,
                          "next": "Inspect existing state; no work was retried."}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
