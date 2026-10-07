#!/usr/bin/env python3
"""Append encrypted, permission-respecting application backups to a guarded volume.

Profiles extend guard_volume's JSON profile. Required additional fields:
source_roots, exclusions, database_dumps, password_file, work_dir, restic_image,
repository_path. Database dump entries have name, argv, and optional format
(sql, postgres-custom, or gzip). Commands are executed as argument arrays;
only an explicitly configured database container may interpret its own argv.

No retention, pruning, source deletion, permission escalation, or automatic
repository initialization is performed. A successful marker test verifies that
one generated file can be reconstructed; it is not a complete application restore.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import fnmatch
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import signal
import sqlite3
import stat
import subprocess
import sys
import time
from urllib.parse import quote
import uuid

from guard_volume import GuardError, load_profile as load_guard_profile, query_volume, validate_volume


EXPECTED_UID = 1000
EXPECTED_GID = 1000
SQLITE_HEADER = b"SQLite format 3\x00"
BROAD_ROOTS = {"/", "/home", "/root", "/etc", "/var", "/var/lib", "/var/lib/docker", "/mnt", "/media"}
REMOTE_TYPES = {"nfs", "nfs4", "cifs", "smb3", "smbfs", "9p", "ceph", "glusterfs"}
PRIVATE_KEY_GLOBS = ["*/.ssh", "*/.ssh/*", "*/id_rsa", "*/id_dsa", "*/id_ecdsa", "*/id_ed25519",
                     "*/id_ecdsa_sk", "*/id_ed25519_sk", "*.pem", "*.key", "*.ppk"]
PRIVATE_KEY_HEADER = re.compile(br"-----BEGIN (?:OPENSSH |RSA |EC |DSA |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----")
CONTAINER_IDENTITY = {
    "container-passwd": b"root:x:0:0:root:/root:/sbin/nologin\nbackup:x:1000:1000:Application backup:/work:/bin/sh\n",
    "container-group": b"root:x:0:\nbackup:x:1000:\n",
}


class BackupError(RuntimeError):
    """An intentionally nonsecret error code and optional safe metadata."""
    def __init__(self, code, details=None):
        super().__init__(code)
        self.code = code
        self.details = details or {}


def absolute_path(value):
    if (not isinstance(value, str) or not value.startswith("/") or
            any(c in value for c in "\x00\r\n,") or
            str(PurePosixPath(value)) != value or ".." in PurePosixPath(value).parts):
        raise BackupError("invalid_absolute_path")
    return value


def within(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def validate_profile(p):
    try:
        roots = p["source_roots"]
        if not isinstance(roots, list) or not roots:
            raise BackupError("source_roots_required")
        for root in roots:
            absolute_path(root)
            if root in BROAD_ROOTS or re.fullmatch(r"/home/[^/]+", root):
                raise BackupError("overbroad_source_root", {"path": root})
        for index, root in enumerate(roots):
            if any(within(root, other) or within(other, root) for other in roots[:index]):
                raise BackupError("overlapping_source_roots")
        for key in ("work_dir", "password_file", "ssh_key", "known_hosts"):
            absolute_path(p[key])
        if p["work_dir"] in BROAD_ROOTS:
            raise BackupError("overbroad_work_directory")
        for key in ("ssh_host", "ssh_user"):
            if not isinstance(p[key], str) or not re.fullmatch(r"[A-Za-z0-9_.:-]+", p[key]):
                raise BackupError("invalid_ssh_identity")
        image = p["restic_image"]
        if not isinstance(image, str) or not re.fullmatch(
                r"restic/restic(?::0\.19\.1)?@sha256:[0-9a-f]{64}", image):
            raise BackupError("pinned_official_restic_image_required")
        repo = absolute_path(p["repository_path"])
        if not repo.startswith("/" + p["drive_letter"] + ":/") or len(PurePosixPath(repo).parts) < 4:
            raise BackupError("repository_outside_verified_drive")
        exclusions = p.get("exclusions", [])
        if not isinstance(exclusions, list):
            raise BackupError("invalid_exclusions")
        for item in exclusions:
            pattern = item if isinstance(item, str) else item["path"]
            if not isinstance(pattern, str) or not pattern.startswith("/") or any(c in pattern for c in "\x00\r\n"):
                raise BackupError("absolute_exclusion_required")
        for pattern in p.get("private_key_globs", []):
            if not isinstance(pattern, str) or not pattern or any(c in pattern for c in "\x00\r\n"):
                raise BackupError("invalid_private_key_glob")
        seen = set()
        for dump in p.get("database_dumps", []):
            name, argv = dump["name"], dump["argv"]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", name) or name in seen:
                raise BackupError("invalid_dump_name")
            seen.add(name)
            if (not isinstance(argv, list) or len(argv) < 4 or argv[:2] != ["docker", "exec"] or
                    not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", argv[2]) or
                    not all(isinstance(arg, str) and arg and "\x00" not in arg for arg in argv)):
                raise BackupError("database_dump_must_use_existing_container_argv")
            if dump.get("format", "sql") not in {"sql", "postgres-custom", "gzip"}:
                raise BackupError("invalid_dump_format")
        if type(p.get("timeout_seconds", 14400)) is not int or not 60 <= p.get("timeout_seconds", 14400) <= 172800:
            raise BackupError("invalid_timeout")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", p.get("snapshot_host", "application-host")):
            raise BackupError("invalid_snapshot_host")
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", p.get("snapshot_tag", "application-config")):
            raise BackupError("invalid_snapshot_tag")
        return p
    except (KeyError, TypeError, ValueError):
        raise BackupError("invalid_backup_profile") from None


def no_symlink_parents(path):
    path = Path(path)
    for component in (path, *path.parents):
        try:
            if component.is_symlink():
                raise BackupError("symlink_path_rejected", {"path": str(component)})
        except OSError:
            raise BackupError("path_metadata_unreadable", {"path": str(component)}) from None


def private_directory(path):
    path = Path(path)
    no_symlink_parents(path)
    path.mkdir(mode=0o700, parents=False, exist_ok=True)
    st = path.stat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != EXPECTED_UID or stat.S_IMODE(st.st_mode) != 0o700:
        raise BackupError("work_directory_must_be_owned_private_0700", {"path": str(path)})
    return path


def validate_password_file(path):
    no_symlink_parents(path)
    try:
        st = Path(path).stat()
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != EXPECTED_UID or
                stat.S_IMODE(st.st_mode) != 0o600 or st.st_size == 0):
            raise BackupError("password_file_must_be_owned_nonempty_0600")
    except OSError:
        raise BackupError("password_file_unavailable") from None


def ensure_container_identity(work):
    """Provide getpwuid(1000) without copying host accounts or changing UID/GID.

    The pinned Alpine image was observed to lack this passwd entry; OpenSSH
    refused to start with 'No user exists for uid 1000'. These fixed, nonsecret
    generated files are the only account database files mounted into the image.
    """
    for name, content in CONTAINER_IDENTITY.items():
        path = Path(work) / name
        no_symlink_parents(path)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        except FileExistsError:
            pass
        st = path.stat()
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != EXPECTED_UID or
                stat.S_IMODE(st.st_mode) != 0o600 or path.read_bytes() != content):
            raise BackupError("generated_container_identity_invalid", {"file": name})


def mount_table():
    """Read kernel mount metadata, never descend into a remote filesystem."""
    result = []
    try:
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            left, right = line.split(" - ", 1)
            value = left.split()[4]
            path = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value)
            result.append((path, right.split()[0]))
    except (OSError, ValueError, IndexError):
        raise BackupError("mount_inventory_unavailable") from None
    return result


def exclusion_match(path, pattern):
    # Resolve every match to an exact path during scanning. The actual restic
    # exclusions below are literal escaped paths, not a second glob engine.
    return within(path, pattern) or fnmatch.fnmatchcase(path, pattern)


def source_plan(p, mounts=None):
    mounts = mount_table() if mounts is None else mounts
    patterns = [(v if isinstance(v, str) else v["path"]) for v in p.get("exclusions", [])]
    patterns += [p["work_dir"], p["password_file"]]
    key_patterns = PRIVATE_KEY_GLOBS + p.get("private_key_globs", [])
    result = {"regular_files": 0, "bytes": 0, "directories": 0, "symlinks": 0,
              "sqlite_files": [], "excluded": [], "issues": [], "coverage": p.get("coverage", {}),
              "_paths": [], "_empty_dirs": []}
    excluded = set()

    def skip(path, reason):
        if path not in excluded:
            excluded.add(path)
            result["excluded"].append({"path": path, "reason": reason})

    def visit(path, root, root_device):
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in key_patterns):
            skip(path, "private_key_name_policy_not_copied")
            return
        if any(exclusion_match(path, pattern) for pattern in patterns):
            skip(path, "profile_or_private_work_exclusion")
            return
        if path != root and any(path == mount[0] for mount in mounts):
            skip(path, "nested_mount_not_followed")
            return
        try:
            path.encode("utf-8")
            if any(c in path for c in "\x00\r\n"):
                raise ValueError()
        except (UnicodeError, ValueError):
            result["issues"].append({"path": path, "code": "unsupported_filename"})
            return
        try:
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                result["symlinks"] += 1
                result["_paths"].append(path)
                return  # Restic records symlink metadata without following it.
            if st.st_dev != root_device:
                skip(path, "different_filesystem_not_followed")
                return
            if stat.S_ISDIR(st.st_mode):
                result["directories"] += 1
                children = 0
                with os.scandir(path) as entries:
                    for entry in entries:
                        children += 1
                        visit(entry.path, root, root_device)
                if not children:
                    result["_empty_dirs"].append({"path": path, "mode": stat.S_IMODE(st.st_mode),
                                                   "uid": st.st_uid, "gid": st.st_gid})
                return
            if not stat.S_ISREG(st.st_mode):
                skip(path, "special_runtime_file")
                return
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                actual = os.fstat(stream.fileno())
                if not stat.S_ISREG(actual.st_mode) or (actual.st_dev, actual.st_ino) != (st.st_dev, st.st_ino):
                    raise BackupError("source_replaced_during_scan")
                header = stream.read(128)
            if PRIVATE_KEY_HEADER.search(header) or header.startswith(b"PuTTY-User-Key-File-"):
                skip(path, "private_key_material_not_copied")
                return
            result["regular_files"] += 1
            result["bytes"] += st.st_size
            if header[:16] == SQLITE_HEADER:
                result["sqlite_files"].append(path)
            else:
                result["_paths"].append(path)
        except (OSError, BackupError) as exc:
            code = "permission_denied" if isinstance(exc, PermissionError) else "source_unreadable_or_changed"
            result["issues"].append({"path": path, "code": code})

    for root in p["source_roots"]:
        try:
            no_symlink_parents(root)
            covering = [(path, typ) for path, typ in mounts if within(root, path)]
            typ = max(covering, key=lambda v: len(v[0]))[1] if covering else ""
            if typ in REMOTE_TYPES or typ.startswith("fuse"):
                result["issues"].append({"path": root, "code": "remote_source_root_rejected"})
                continue
            st = os.lstat(root)
            visit(root, root, st.st_dev)
        except (OSError, BackupError):
            result["issues"].append({"path": root, "code": "source_root_unavailable_or_symlink"})
    result["sqlite_files"].sort()
    result["excluded"].sort(key=lambda item: item["path"])
    result["ok"] = not result["issues"]
    return result


def public_plan(plan):
    return {key: value for key, value in plan.items() if not key.startswith("_")}


def write_json(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, sort_keys=True, separators=(",", ":"), allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def atomic_json(path, data):
    path = Path(path)
    no_symlink_parents(path)
    temporary = path.parent / (path.name + "." + uuid.uuid4().hex + ".tmp")
    write_json(temporary, data)
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def sqlite_export(source, target, timeout_seconds=120):
    """Take an online, transactional SQLite copy, including committed WAL data."""
    no_symlink_parents(source)
    fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    started = time.monotonic()
    def progress(status, remaining, total):
        if time.monotonic() - started > timeout_seconds:
            raise BackupError("sqlite_snapshot_timeout")
    try:
        src = sqlite3.connect("file:" + quote(str(source), safe="/") + "?mode=ro", uri=True, timeout=5)
        try:
            dst = sqlite3.connect(str(target))
            try:
                src.backup(dst, pages=256, progress=progress, sleep=0.05)
                check = dst.execute("PRAGMA quick_check").fetchall()
                if check != [("ok",)]:
                    raise BackupError("sqlite_snapshot_integrity_failed")
            finally:
                dst.close()
        finally:
            src.close()
    except sqlite3.Error:
        raise BackupError("sqlite_snapshot_failed", {"path": str(source)}) from None
    return {"source": str(source), "export": str(target), "bytes": Path(target).stat().st_size}


def execute_private(argv, stdout_path, stderr_path, timeout, run=None):
    """Never relay child output: database contents and errors stay in private files."""
    try:
        with open(stdout_path, "xb") as out, open(stderr_path, "xb") as err:
            result = (run or subprocess.run)(argv, stdout=out, stderr=err, timeout=timeout, check=False, shell=False)
            out.flush()
            os.fsync(out.fileno())
    except subprocess.TimeoutExpired:
        raise BackupError("command_timed_out") from None
    except OSError:
        raise BackupError("command_failed_to_start") from None
    if result.returncode != 0:
        raise BackupError("command_nonzero_exit", {"exit_code": result.returncode})


def database_exports(p, exports, logs, run=None):
    records = []
    for entry in p.get("database_dumps", []):
        kind = entry.get("format", "sql")
        suffix = {"sql": ".sql", "postgres-custom": ".pgdump", "gzip": ".gz"}[kind]
        output = exports / (entry["name"] + suffix)
        try:
            execute_private(entry["argv"], output, logs / (entry["name"] + ".stderr"),
                            p.get("database_timeout_seconds", 900), run=run)
            size = output.stat().st_size
            if not size:
                raise BackupError("empty_database_dump")
            if kind == "postgres-custom":
                with output.open("rb") as stream:
                    if stream.read(5) != b"PGDMP":
                        raise BackupError("invalid_postgres_dump_header")
            if kind == "gzip":
                with gzip.open(output, "rb") as stream:
                    while stream.read(1024 * 1024):
                        pass
            records.append({"name": entry["name"], "format": kind, "bytes": size, "export": str(output)})
        except (BackupError, OSError, EOFError):
            raise BackupError("database_export_failed", {"name": entry["name"]}) from None
    return records


def docker_restic_argv(p, args, include_sources=True, container_name=None):
    ssh_dir = str(Path(p["ssh_key"]).parent)
    if not within(p["known_hosts"], ssh_dir):
        raise BackupError("known_hosts_must_share_existing_ssh_directory")
    mounts = [(p["work_dir"], "/work", False), (ssh_dir, ssh_dir, True),
              (p["password_file"], "/run/secrets/restic-password", True),
              (str(Path(p["work_dir"]) / "container-passwd"), "/etc/passwd", True),
              (str(Path(p["work_dir"]) / "container-group"), "/etc/group", True)]
    if include_sources:
        mounts += [(root, root, True) for root in p["source_roots"]]
    argv = ["docker", "run", "--rm", "--network", "host", "--user", "1000:1000",
            "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--tmpfs", "/tmp:rw,noexec,nosuid,size=67108864",
            "--env", "HOME=/work", "--env", "TMPDIR=/work/tmp",
            "--env", "RESTIC_CACHE_DIR=/work/cache",
            "--env", "RESTIC_PASSWORD_FILE=/run/secrets/restic-password"]
    if container_name:
        argv += ["--name", container_name]
    for source, destination, readonly in mounts:
        value = "type=bind,src=" + source + ",dst=" + destination
        argv += ["--mount", value + (",readonly" if readonly else "")]
    ssh = ["ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
           "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + p["known_hosts"],
           "-o", "ConnectTimeout=7", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=10",
           "-o", "ServerAliveCountMax=3", "-i", p["ssh_key"], p["ssh_user"] + "@" + p["ssh_host"], "-s", "sftp"]
    repository = "sftp:" + p["ssh_user"] + "@" + p["ssh_host"] + ":" + p["repository_path"]
    return argv + [p["restic_image"], "--repo", repository, "-o", "sftp.command=" + shlex.join(ssh)] + list(args)


def container_path(p, path):
    return "/work/" + str(Path(path).relative_to(p["work_dir"]))


def stop_owned_container(name):
    """Stop only the unique container started by this command before lock release."""
    try:
        result = subprocess.run(["docker", "container", "inspect", "--format", "{{.State.Running}}", name],
                                capture_output=True, text=True, timeout=15, shell=False)
        if result.returncode:
            return "No such object" in result.stderr or "No such container" in result.stderr
        if result.stdout.strip() != "true":
            return True
        result = subprocess.run(["docker", "stop", "--time", "10", name],
                                capture_output=True, timeout=25, shell=False)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def restic(p, stage, label, args, include_sources=False):
    out, err = stage / (label + ".stdout"), stage / (label + ".stderr")
    name = "app-backup-" + uuid.uuid4().hex
    write_json(stage / (label + ".container.json"), {"container_name": name})
    try:
        execute_private(docker_restic_argv(p, args, include_sources, name), out, err, p.get("timeout_seconds", 14400))
    except BaseException:
        if not stop_owned_container(name):
            # The failure checkpoint and container identity permit explicit
            # recovery. Never report completion while its state is unknown.
            raise BackupError("owned_container_state_uncertain", {"container_name": name}) from None
        raise
    return out


def literal_exclusion(path):
    # restic's Go filepath.Match syntax: escape metacharacters, retain slashes.
    escaped = "".join("\\" + ch if ch in "\\*?[" else ch for ch in path)
    return escaped.replace("$", "$$")  # exclude files expand environment variables


def backup_summary(path):
    found = None
    try:
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                try:
                    item = json.loads(line)
                except (json.JSONDecodeError, UnicodeError):
                    continue
                if item.get("message_type") == "summary":
                    found = item
        if not found or not re.fullmatch(r"[0-9a-f]{8,64}", found.get("snapshot_id", "")):
            raise ValueError()
        return {key: found[key] for key in ("snapshot_id", "total_files_processed", "total_bytes_processed",
                                            "files_new", "files_changed", "files_unmodified", "data_added",
                                            "data_added_packed", "total_duration") if key in found}
    except (OSError, TypeError, ValueError):
        raise BackupError("backup_summary_missing_or_invalid") from None


def verify_marker(expected, restored):
    if Path(expected).read_bytes() != Path(restored).read_bytes():
        raise BackupError("restored_marker_mismatch")
    return {"ok": True, "method": "restic_dump_byte_comparison", "scope": "generated_nonsecret_marker_only"}


def guarded(p):
    return validate_volume(p, query_volume(p))


def perform(p, init=False, verify_restore=False, check_data=False):
    if os.geteuid() != EXPECTED_UID or os.getegid() != EXPECTED_GID:
        raise BackupError("must_run_as_uid_gid_1000")
    os.umask(0o077)
    validate_password_file(p["password_file"])
    work = private_directory(p["work_dir"])
    for name in ("cache", "tmp", "runs"):
        private_directory(work / name)
    ensure_container_identity(work)
    lock_fd = os.open(work / "runner.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if not init:
                # A scheduled invocation overlapping an existing writer is a
                # clean no-op, never evidence that a new backup completed.
                return {"ok": True, "status": "skipped_busy", "operation": "backup"}
            raise BackupError("backup_already_running") from None
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
        stage = private_directory(work / "runs" / run_id)
        summary = {"ok": False, "run_id": run_id, "stage": str(stage), "coverage": p.get("coverage", {})}
        try:
            summary["volume"] = guarded(p)
            if init:
                if p.get("new_repository") is not True:
                    raise BackupError("explicit_new_repository_profile_required")
                restic(p, stage, "init", ["init", "--repository-version", "2"])
                summary.update(ok=True, operation="init", repository_initialized=True)
            else:
                # Failure here is final: never interpret an auth/transport/lock
                # error as a reason to initialize a different/new repository.
                restic(p, stage, "repository-open", ["cat", "config"])
                plan = source_plan(p)
                write_json(stage / "source-plan.json", public_plan(plan))
                if not plan["ok"]:
                    raise BackupError("source_plan_blocked", {"issues": plan["issues"]})
                exports = private_directory(stage / "exports")
                logs = private_directory(stage / "private-logs")
                db_records = database_exports(p, exports, logs)
                sqlite_records = []
                exclusions = {item["path"] for item in plan["excluded"]}
                for path in plan["sqlite_files"]:
                    name = "sqlite-" + hashlib.sha256(path.encode()).hexdigest()[:24] + ".db"
                    record = sqlite_export(path, exports / name, p.get("sqlite_timeout_seconds", 120))
                    sqlite_records.append(record)
                    exclusions.update((path, path + "-wal", path + "-shm", path + "-journal"))
                # New databases appearing after the first scan must not silently
                # enter the snapshot as raw live files.
                fresh = source_plan(p)
                if not fresh["ok"] or fresh["sqlite_files"] != plan["sqlite_files"]:
                    raise BackupError("source_plan_changed_or_blocked", {"issues": fresh["issues"]})
                exclusions.update(item["path"] for item in fresh["excluded"])
                marker = exports / "backup-marker.json"
                write_json(marker, {"purpose": "nonsecret_restore_probe", "run_id": run_id,
                                    "nonce": uuid.uuid4().hex, "created_utc": datetime.now(timezone.utc).isoformat()})
                write_json(exports / "export-manifest.json", {
                    "run_id": run_id, "databases": db_records, "sqlite": sqlite_records,
                    "source_roots": p["source_roots"], "exclusions": sorted(exclusions),
                    "coverage": p.get("coverage", {}), "app_wide_quiescence_asserted": False,
                    "empty_directories": fresh["_empty_dirs"],
                    "selection": "explicit_scanned_files; empty directories recorded here without traversal"})
                exclude_file = stage / "restic-exclusions.txt"
                with exclude_file.open("x", encoding="utf-8") as stream:
                    stream.write("\n".join(literal_exclusion(path) for path in sorted(exclusions)) + "\n")
                selected = [path for path in fresh["_paths"] if path not in exclusions]
                selected += [container_path(p, path) for path in exports.iterdir() if path.is_file()]
                file_list = stage / "approved-files.raw"
                with file_list.open("xb") as stream:
                    for path in sorted(selected):
                        stream.write(os.fsencode(path) + b"\0")
                guarded(p)
                backup_args = ["backup", "--json", "--one-file-system", "--exclude-file", container_path(p, exclude_file),
                               "--files-from-raw", container_path(p, file_list), "--group-by", "host",
                               "--host", p.get("snapshot_host", "application-host"),
                               "--tag", p.get("snapshot_tag", "application-config"),
                               "--tag", "run:" + run_id]
                for pattern in PRIVATE_KEY_GLOBS + p.get("private_key_globs", []):
                    backup_args += ["--exclude", pattern]
                result_file = restic(p, stage, "backup", backup_args, include_sources=True)
                summary.update(backup_summary(result_file))
                snapshot = summary["snapshot_id"]
                guarded(p)
                metadata = restic(p, stage, "snapshot-metadata", ["snapshots", "--json", snapshot])
                try:
                    entries = json.loads(metadata.read_text())
                    if (len(entries) != 1 or not re.fullmatch(r"[0-9a-f]{64}", entries[0]["id"]) or
                            not entries[0]["id"].startswith(snapshot)):
                        raise ValueError()
                    summary["snapshot_id"] = entries[0]["id"]
                except (OSError, ValueError, KeyError, TypeError):
                    raise BackupError("snapshot_metadata_verification_failed") from None
                restic(p, stage, "repository-check", ["check"] + (["--read-data"] if check_data else []))
                summary["repository_check"] = "full_data" if check_data else "metadata"
                if verify_restore:
                    restored = restic(p, stage, "restored-marker", ["dump", summary["snapshot_id"], container_path(p, marker)])
                    summary["restore_probe"] = verify_marker(marker, restored)
                summary.update(ok=True, operation="backup", database_exports=len(db_records),
                               sqlite_exports=len(sqlite_records), plan_files=plan["regular_files"],
                               plan_bytes=plan["bytes"], excluded_paths=len(exclusions),
                               app_wide_quiescence_asserted=False)
            summary["final_volume"] = guarded(p)
            summary["completed_utc"] = datetime.now(timezone.utc).isoformat()
            if not init:
                atomic_json(work / "latest-success.json", summary)
            write_json(stage / "SUCCESS.json", summary)
            return summary
        except (BackupError, GuardError) as exc:
            summary.update(ok=False, error=str(exc))
            if isinstance(exc, BackupError):
                summary["details"] = exc.details
            write_json(stage / "FAILED.json", summary)
            raise BackupError(str(exc), summary) from None
    finally:
        os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--plan", action="store_true", help="Read-only source permission/SQLite/mount inventory; no dumps or repository operation")
    group.add_argument("--init", action="store_true", help="Explicit initialization only; requires new_repository=true")
    parser.add_argument("--verify-restore", action="store_true", help="Reconstruct and compare a generated marker after backup")
    parser.add_argument("--check-data", action="store_true", help="Read all repository data during the post-backup check")
    args = parser.parse_args(argv)
    def interrupted(signum, frame):
        raise BackupError("runner_interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        p = validate_profile(load_guard_profile(args.profile))
        if (args.plan or args.init) and (args.verify_restore or args.check_data):
            raise BackupError("verification_flags_require_backup_mode")
        if os.geteuid() != EXPECTED_UID or os.getegid() != EXPECTED_GID:
            raise BackupError("must_run_as_uid_gid_1000")
        if args.plan:
            result = public_plan(source_plan(p))
            result.update(mode="plan", target_verification="not_run_in_plan", database_dumps_executed=False)
        else:
            result = perform(p, args.init, args.verify_restore, args.check_data)
        print(json.dumps(result, separators=(",", ":"), allow_nan=False))
        return 0 if result["ok"] else 1
    except (BackupError, GuardError) as exc:
        data = {"ok": False, "error": str(exc)}
        if isinstance(exc, BackupError):
            data["details"] = exc.details
        print(json.dumps(data, separators=(",", ":")))
        return 1
    except (OSError, ValueError, sqlite3.Error):
        # Do not accidentally expose native error messages or credential data.
        print(json.dumps({"ok": False, "error": "local_operation_failed"}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
