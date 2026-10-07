#!/usr/bin/env python3
"""Stage and publish an additional opaque restic replica using a private profile."""
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import uuid

import capture_restic
import guard_volume


GENERATION = re.compile(r"[0-9]{8}T[0-9]{12}Z-[0-9a-f]{12}")
STAGE_KIND = "pi-replica-local-stage-v1"


class BackupError(RuntimeError):
    pass


def content_hash(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"),
                         allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def load_profile(path):
    p = guard_volume.load_profile(path)
    try:
        for key in ("source_repository", "work_dir"):
            if not isinstance(p[key], str) or not os.path.isabs(p[key]) or any(
                    c in p[key] for c in "\x00\r\n,"):
                raise ValueError()
        if not re.fullmatch(r"(?:[A-Za-z0-9_./:-]+@)?sha256:[0-9a-f]{64}", p["rclone_image"]):
            raise ValueError()
        for key in ("host", "tag"):
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", p[key]):
                raise ValueError()
        base = PureWindowsPath(p["repository_base_windows"])
        if (base.drive.upper() != p["drive_letter"] + ":" or
                base.root != "\\" or len(base.parts) < 3 or
                any(part in (".", "..") or ":" in part or part.rstrip(" .") != part
                    for part in base.parts[1:]) or
                any(c in str(base) for c in '\x00\r\n*?"<>|')):
            raise ValueError()
        p["repository_base_windows"] = str(base)
        if p["repository_base_sftp"].rstrip("/") != "/" + str(base).replace("\\", "/"):
            raise ValueError()
        p["repository_base_sftp"] = p["repository_base_sftp"].rstrip("/")
        if Path(p["ssh_key"]).parent != Path(p["known_hosts"]).parent:
            raise ValueError()
        if any(c in p["ssh_key"] + p["known_hosts"] for c in ","):
            raise ValueError()
        capture_restic.command_observer(p["observer_command"])
        return p
    except (KeyError, TypeError, ValueError):
        raise BackupError("invalid_replica_profile") from None


def remote_payload(p, action, **request):
    fields = ("drive_letter", "volume_guid", "volume_label", "min_free_bytes",
              "repository_base_windows", "host", "tag")
    payload = {key: p[key] for key in fields}
    payload.update(request, action=action)
    script = Path(__file__).with_name("backup_pi_verify.ps1").read_bytes()
    return json.dumps({"cfg": payload, "script_base64": base64.b64encode(script).decode("ascii")})


def remote_command(p):
    bootstrap = (
        "$ErrorActionPreference='Stop';"
        "[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);"
        "$payload=[Console]::In.ReadToEnd()|ConvertFrom-Json;"
        "$cfg=$payload.cfg;"
        "$script=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$payload.script_base64));"
        "& ([ScriptBlock]::Create($script))"
    )
    encoded = base64.b64encode(bootstrap.encode("utf-16le")).decode("ascii")
    return guard_volume.ssh_command(p)[:-1] + [
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded]


def remote(p, action, **request):
    try:
        result = subprocess.run(remote_command(p), input=remote_payload(p, action, **request), capture_output=True,
                                text=True, encoding="utf-8", timeout=900, check=False)
        if result.returncode:
            raise BackupError("remote_" + action + "_failed")
        response = json.loads(result.stdout.lstrip("\ufeff"))
        if not isinstance(response, dict) or response.get("ok") is not True:
            raise BackupError("invalid_remote_response")
        return response
    except (OSError, subprocess.TimeoutExpired, UnicodeError, json.JSONDecodeError):
        raise BackupError("remote_" + action + "_failed") from None


def upload_command(p, stage, generation):
    if GENERATION.fullmatch(generation) is None:
        raise BackupError("invalid_generation")
    ssh_dir = str(Path(p["ssh_key"]).parent)
    return ["docker", "run", "--rm", "--name", container_name(generation),
            "--label", "afz.replica.kind=pi", "--label", "afz.replica.generation=" + generation,
            "--pull", "never", "--network", "host",
            "--user", "1000:1000", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--tmpfs", "/tmp",
            "--mount", f"type=bind,src={ssh_dir},dst=/keys,readonly",
            "--mount", f"type=bind,src={stage},dst=/stage,readonly",
            p["rclone_image"], "copy", "/stage",
            ":sftp:" + p["repository_base_sftp"] + "/" + generation + ".partial",
            "--config", "/dev/null", "--sftp-host", p["ssh_host"],
            "--sftp-user", p["ssh_user"], "--sftp-key-file", "/keys/" + Path(p["ssh_key"]).name,
            "--sftp-known-hosts-file", "/keys/" + Path(p["known_hosts"]).name,
            "--sftp-disable-hashcheck", "--create-empty-src-dirs", "--immutable",
            "--transfers", "2", "--checkers", "2", "--retries", "2",
            "--low-level-retries", "2", "--contimeout", "10s", "--timeout", "1m"]


def container_name(generation):
    if GENERATION.fullmatch(generation) is None:
        raise BackupError("invalid_generation")
    return "afz-pi-replica-" + generation.lower()


def cleanup_container(generation):
    """Only stop the uniquely named container carrying both our expected labels."""
    name = container_name(generation)
    try:
        result = subprocess.run(["docker", "inspect", "--format", "{{json .Config.Labels}}", name],
                                capture_output=True, text=True, timeout=15, check=False)
        if result.returncode:
            return
        labels = json.loads(result.stdout)
        if labels.get("afz.replica.kind") != "pi" or labels.get("afz.replica.generation") != generation:
            return
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, text=True, timeout=20, check=False)
    except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired):
        return


def upload(p, stage, generation):
    try:
        result = subprocess.run(upload_command(p, stage, generation), capture_output=True,
                                text=True, timeout=2700, check=False)
        if result.returncode:
            raise BackupError("upload_failed")
    except BaseException as exc:
        cleanup_container(generation)
        if isinstance(exc, (OSError, subprocess.TimeoutExpired)):
            raise BackupError("upload_failed") from None
        raise


@contextmanager
def runner_lock(work):
    capture_restic._no_symlink_path(work)
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = work.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise BackupError("work_directory_must_be_owned_and_mode_0700")
    fd = os.open(work / "runner.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(fd)


def _atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    capture_restic._write_json(temporary, value)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def cleanup_stages(work, keep=2, max_remove=2):
    """Bounded cleanup of this runner's published local stages; failures remain."""
    root = work / "stages"
    candidates = []
    if not root.is_dir() or root.is_symlink():
        return
    for stage in root.iterdir():
        if (GENERATION.fullmatch(stage.name) is None or stage.is_symlink() or
                not stage.is_dir() or stage.stat().st_uid != os.getuid() or
                (stage / "INCOMPLETE").exists() or not (stage / "COMPLETE").is_file()):
            continue
        try:
            receipt = json.loads((stage / "PUBLISHED.json").read_text())
            marker = json.loads((stage / "COMPLETE").read_text())
            if (receipt.get("kind") != STAGE_KIND or receipt.get("generation") != stage.name or
                    receipt.get("manifest_sha256") != marker.get("manifest_sha256") or
                    marker.get("manifest_sha256") != capture_restic._read_file(stage / "manifest.json")["sha256"]):
                continue
            if any(item.is_symlink() for item in stage.rglob("*")):
                continue
            candidates.append(stage)
        except (OSError, ValueError, capture_restic.CaptureError):
            continue
    eligible = sorted(candidates, reverse=True)[keep:]
    for stage in sorted(eligible)[:max_remove]:
        shutil.rmtree(stage)


def replicate(p):
    work = Path(p["work_dir"])
    profile_id = content_hash({key: p[key] for key in (
        "source_repository", "ssh_host", "ssh_user", "volume_guid", "volume_label",
        "repository_base_windows", "host", "tag")})
    with runner_lock(work) as acquired:
        if not acquired:
            return {"ok": True, "status": "skipped_busy"}
        guard_volume.validate_volume(p, guard_volume.query_volume(p))
        observer = capture_restic.command_observer(p["observer_command"])
        observed_before = capture_restic._observe(observer)
        source_hash = content_hash(capture_restic.manifest(Path(p["source_repository"])))
        if observed_before != capture_restic._observe(observer):
            raise BackupError("source_probe_writer_changed")
        record_path = work / "latest_verified.json"
        try:
            record = json.loads(record_path.read_text())
        except (OSError, ValueError):
            record = {}
        if (record.get("profile_id") == profile_id and
                record.get("source_manifest_sha256") == source_hash):
            status = remote(p, "status", expected=record)
            if status.get("matches") is True:
                return {"ok": True, "status": "skipped_unchanged", "generation": record["generation"],
                        "qualification": capture_restic.QUALIFICATION}
        stages = work / "stages"
        capture_restic._no_symlink_path(stages)
        stages.mkdir(mode=0o700, exist_ok=True)
        generation = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ-") + uuid.uuid4().hex[:12]
        stage = stages / generation
        metadata = capture_restic.capture(p["source_repository"], stage, observer)
        receipt = {
            "schema": 1, "generation": generation, "profile_id": profile_id,
            "source_manifest_sha256": content_hash(metadata["files"]),
            "manifest_sha256": capture_restic._read_file(stage / "manifest.json")["sha256"],
            "complete_sha256": capture_restic._read_file(stage / "COMPLETE")["sha256"],
            "captured_utc": metadata["captured_utc"],
            "snapshot_ids": sorted(Path(name).name for name in metadata["files"] if name.startswith("snapshots/")),
            "observer": metadata["observer_after"], "host": p["host"], "tag": p["tag"],
            "qualification": capture_restic.QUALIFICATION,
            "restic_decryption_or_restore_tested": False,
        }
        required = metadata["total_bytes"] + (stage / "manifest.json").stat().st_size + (stage / "COMPLETE").stat().st_size
        remote(p, "prepare", generation=generation, required_bytes=required)
        upload(p, stage, generation)
        published = remote(p, "publish", generation=generation, expected=receipt)
        if (published.get("generation") != generation or
                published.get("manifest_sha256") != receipt["manifest_sha256"]):
            raise BackupError("publication_receipt_mismatch")
        receipt["published_utc"] = published["published_utc"]
        _atomic_json(stage / "PUBLISHED.json", dict(receipt, kind=STAGE_KIND))
        _atomic_json(record_path, receipt)
        cleanup_stages(work)
        return {"ok": True, "status": "published", "generation": generation,
                "source_manifest_sha256": receipt["source_manifest_sha256"],
                "snapshot_ids": receipt["snapshot_ids"], "qualification": capture_restic.QUALIFICATION}


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    try:
        if len(args) != 1:
            raise BackupError("expected_private_profile_path")
        result = replicate(load_profile(args[0]))
    except Exception as exc:
        print(json.dumps({"ok": False, "error_type": type(exc).__name__}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    def stop(_signum, _frame):
        raise BackupError("terminated")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    raise SystemExit(main())
