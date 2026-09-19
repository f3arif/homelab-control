#!/usr/bin/env python3
"""Read-only HPENVY AFZ Control Hub source capture.

Runner-side only. The remote payload reads a fixed allowlist and emits JSON to
stdout; it performs no remote writes, service control, package changes, or
runtime mutation. Validated bytes are repackaged locally into a deterministic
ZIP before artifact upload.
"""
from __future__ import annotations

import argparse
import ast
import base64
import hashlib
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tomllib
import urllib.request
import zipfile
from datetime import datetime, timezone
from typing import Any

TARGET = "coolyo@100.71.26.69"
HEALTH_URL = "http://100.71.26.69:8789/health"
ALLOWED_FILES = ("app/main.py", "requirements.txt", "pyproject.toml", "Dockerfile")
REQUIRED_FILE = "app/main.py"
MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_TOTAL_BYTES = 10 * 1024 * 1024
MAX_REMOTE_JSON_BYTES = 15 * 1024 * 1024
OUTPUT_NAMES = (
    "controlhub-source.zip",
    "controlhub-manifest.json",
    "validation.txt",
    "sha256.txt",
)

TOKEN_PREFIX = re.compile(
    r"(?i)(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|"
    r"github_pat_[A-Za-z0-9_]{20,}|tskey-[A-Za-z0-9_-]{16,}|"
    r"AKIA[0-9A-Z]{16})"
)
PRIVATE_KEY = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
CREDENTIAL_URL = re.compile(r"(?i)[a-z][a-z0-9+.-]*://[^/\s:@]+:[^@\s/]+@")
JWT = re.compile(
    r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"
)

SENSITIVE_EXACT = {
    "afz_hub_token",
    "openai_api_key",
    "api_key",
    "access_token",
    "auth_token",
    "bearer_token",
    "token",
    "password",
    "passwd",
    "secret",
    "client_secret",
    "database_url",
    "connection_string",
    "dsn",
}


class CaptureError(RuntimeError):
    pass


def _norm_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def is_sensitive_key(value: object) -> bool:
    if not isinstance(value, str):
        return False
    key = _norm_key(value)
    return (
        key in SENSITIVE_EXACT
        or key.endswith("_token")
        or key.endswith("_password")
        or key.endswith("_passwd")
        or key.endswith("_secret")
        or key.endswith("_api_key")
        or key.endswith("_client_secret")
    )


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


REMOTE_READER = r"""
import base64
import hashlib
import json
import os
import pwd
import socket
import stat

ALLOWED = ("app/main.py", "requirements.txt", "pyproject.toml", "Dockerfile")
MAX_FILE = 5 * 1024 * 1024
MAX_TOTAL = 10 * 1024 * 1024

if socket.gethostname().lower() != "hpenvy":
    raise SystemExit(41)
if pwd.getpwuid(os.getuid()).pw_name != "coolyo":
    raise SystemExit(42)

expected_env = {
    "HOME": "/home/coolyo",
    "USER": "coolyo",
    "SHELL": "/bin/bash",
    "PATH": "/usr/bin:/bin",
    "LANG": "C",
    "LC_ALL": "C",
}
for key, value in expected_env.items():
    if os.environ.get(key) != value:
        raise SystemExit(43)
dangerous_env = {
    "BASH_ENV",
    "ENV",
    "TAR_OPTIONS",
    "PYTHONPATH",
    "PYTHONHOME",
    "PYTHONSTARTUP",
    "GIT_SSH_COMMAND",
}
if dangerous_env.intersection(os.environ):
    raise SystemExit(44)

required_os_flags = ("O_NOFOLLOW", "O_CLOEXEC", "O_DIRECTORY", "O_NONBLOCK")
if any(not hasattr(os, name) for name in required_os_flags):
    raise SystemExit(45)

def open_dir(name, *, dir_fd=None):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    return os.open(name, flags, dir_fd=dir_fd)

def read_regular(name, *, dir_fd, required):
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        if required:
            raise SystemExit(46)
        return None
    except OSError:
        raise SystemExit(47)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SystemExit(48)
        size = info.st_size
        if size <= 0 or size > MAX_FILE:
            raise SystemExit(49)
        chunks = []
        seen = 0
        while True:
            chunk = os.read(fd, min(65536, MAX_FILE + 1 - seen))
            if not chunk:
                break
            chunks.append(chunk)
            seen += len(chunk)
            if seen > MAX_FILE:
                raise SystemExit(50)
        data = b"".join(chunks)
        if len(data) != size:
            raise SystemExit(51)
        return data
    finally:
        os.close(fd)

home_fd = open_dir("/home/coolyo")
try:
    root_fd = open_dir("afz-control-hub", dir_fd=home_fd)
    try:
        app_fd = open_dir("app", dir_fd=root_fd)
        try:
            specs = (
                ("app/main.py", app_fd, "main.py", True),
                ("requirements.txt", root_fd, "requirements.txt", False),
                ("pyproject.toml", root_fd, "pyproject.toml", False),
                ("Dockerfile", root_fd, "Dockerfile", False),
            )
            files = []
            total = 0
            for rel, directory_fd, leaf, required in specs:
                data = read_regular(leaf, dir_fd=directory_fd, required=required)
                if data is None:
                    continue
                total += len(data)
                if total > MAX_TOTAL:
                    raise SystemExit(52)
                files.append(
                    {
                        "name": rel,
                        "size": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "data_b64": base64.b64encode(data).decode("ascii"),
                    }
                )
        finally:
            os.close(app_fd)
    finally:
        os.close(root_fd)
finally:
    os.close(home_fd)

names = [f["name"] for f in files]
if "app/main.py" not in names or len(names) != len(set(names)):
    raise SystemExit(53)

print(
    json.dumps(
        {
            "schema": "afz-controlhub-source-capture-v1",
            "host": "hpenvy",
            "user": "coolyo",
            "files": files,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
)
"""


def build_remote_command() -> str:
    encoded = base64.b64encode(REMOTE_READER.encode("utf-8")).decode("ascii")
    bootstrap = (
        "import base64;"
        f"exec(compile(base64.b64decode({encoded!r}),"
        "'<afz-controlhub-readonly-capture>','exec'))"
    )
    # Tailscale SSH command sessions are launched with a minimal server-side
    # environment. We additionally replace the child environment completely
    # and run isolated Python; no tar, profile, or package tooling is involved.
    return (
        "unset BASH_ENV ENV TAR_OPTIONS PYTHONPATH PYTHONHOME PYTHONSTARTUP; "
        "exec /usr/bin/env -i "
        "HOME=/home/coolyo USER=coolyo SHELL=/bin/bash PATH=/usr/bin:/bin "
        "LANG=C LC_ALL=C "
        "/usr/bin/python3 -I -S -c "
        + shlex.quote(bootstrap)
    )


def fetch_remote_envelope() -> dict[str, Any]:
    env = os.environ.copy()
    for name in (
        "BASH_ENV",
        "ENV",
        "TAR_OPTIONS",
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONSTARTUP",
        "GIT_SSH_COMMAND",
    ):
        env.pop(name, None)

    proc = subprocess.run(
        ["tailscale", "ssh", TARGET, build_remote_command()],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=45,
        env=env,
    )
    if proc.returncode != 0:
        raise CaptureError(f"remote capture failed with exit {proc.returncode}")
    if len(proc.stdout) <= 0 or len(proc.stdout) > MAX_REMOTE_JSON_BYTES:
        raise CaptureError("remote capture envelope size invalid")
    try:
        text = proc.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CaptureError("remote capture envelope is not UTF-8") from exc
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as exc:
        raise CaptureError("remote capture envelope is not strict JSON") from exc
    if not isinstance(obj, dict):
        raise CaptureError("remote capture envelope type invalid")
    return obj


def validate_envelope(obj: dict[str, Any]) -> dict[str, bytes]:
    if set(obj) != {"schema", "host", "user", "files"}:
        raise CaptureError("remote envelope fields invalid")
    if obj.get("schema") != "afz-controlhub-source-capture-v1":
        raise CaptureError("remote envelope schema invalid")
    if obj.get("host") != "hpenvy" or obj.get("user") != "coolyo":
        raise CaptureError("remote identity invalid")

    rows = obj.get("files")
    if not isinstance(rows, list) or not 1 <= len(rows) <= len(ALLOWED_FILES):
        raise CaptureError("remote file list invalid")

    decoded: dict[str, bytes] = {}
    total = 0
    for row in rows:
        if not isinstance(row, dict) or set(row) != {
            "name",
            "size",
            "sha256",
            "data_b64",
        }:
            raise CaptureError("remote file record fields invalid")
        name = row["name"]
        size = row["size"]
        digest = row["sha256"]
        encoded = row["data_b64"]
        if name not in ALLOWED_FILES or name in decoded:
            raise CaptureError("remote file name invalid or duplicated")
        if isinstance(size, bool) or not isinstance(size, int):
            raise CaptureError("remote file size type invalid")
        if size <= 0 or size > MAX_FILE_BYTES:
            raise CaptureError("remote file size outside bound")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise CaptureError("remote file hash invalid")
        if not isinstance(encoded, str):
            raise CaptureError("remote file payload type invalid")
        try:
            data = base64.b64decode(encoded, validate=True)
        except Exception as exc:
            raise CaptureError("remote file payload base64 invalid") from exc
        if len(data) != size or _sha(data) != digest:
            raise CaptureError("remote file payload integrity mismatch")
        total += size
        if total > MAX_TOTAL_BYTES:
            raise CaptureError("remote file total size outside bound")
        decoded[name] = data

    if REQUIRED_FILE not in decoded:
        raise CaptureError("required app/main.py missing")
    return decoded


def check_health() -> dict[str, str]:
    req = urllib.request.Request(HEALTH_URL, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            if response.status != 200:
                raise CaptureError("Control Hub health HTTP status invalid")
            body = response.read(4097)
    except CaptureError:
        raise
    except Exception as exc:
        raise CaptureError("Control Hub health request failed") from exc
    if len(body) > 4096:
        raise CaptureError("Control Hub health body too large")
    try:
        health = json.loads(body.decode("utf-8"))
    except Exception as exc:
        raise CaptureError("Control Hub health body invalid") from exc
    if not isinstance(health, dict):
        raise CaptureError("Control Hub health type invalid")
    if health.get("ok") is not True:
        raise CaptureError("Control Hub health not OK")
    if health.get("service") != "afz-control-hub":
        raise CaptureError("Control Hub service identity invalid")
    if health.get("mode") != "safe-readonly":
        raise CaptureError("Control Hub mode is not safe-readonly")
    version = health.get("version")
    if not isinstance(version, str) or re.fullmatch(
        r"[A-Za-z0-9._-]{1,80}", version
    ) is None:
        raise CaptureError("Control Hub version field invalid")
    return {
        "service": "afz-control-hub",
        "mode": "safe-readonly",
        "version": version,
    }


def _generic_secret_findings(name: str, text: str) -> list[tuple[int, str]]:
    findings: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if PRIVATE_KEY.search(line):
            findings.append((lineno, "private-key"))
        if TOKEN_PREFIX.search(line):
            findings.append((lineno, "token-prefix"))
        if CREDENTIAL_URL.search(line):
            findings.append((lineno, "credential-url"))
        if JWT.search(line):
            findings.append((lineno, "jwt"))
    return findings


def _literal_string(node: ast.AST | None) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _target_keys(node: ast.AST) -> list[str]:
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, ast.Attribute):
        return [node.attr]
    if isinstance(node, ast.Subscript):
        value = _literal_string(node.slice)
        return [value] if value is not None else []
    if isinstance(node, (ast.Tuple, ast.List)):
        out: list[str] = []
        for item in node.elts:
            out.extend(_target_keys(item))
        return out
    return []


class PythonSecretVisitor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.findings: list[tuple[int, str]] = []

    def _check_value(self, key: object, value: ast.AST | None, line: int) -> None:
        if not is_sensitive_key(key):
            return
        literal = _literal_string(value)
        if literal:
            self.findings.append((line, "literal-sensitive-assignment"))
        elif isinstance(value, ast.JoinedStr):
            if any(
                isinstance(part, ast.Constant)
                and isinstance(part.value, str)
                and part.value
                for part in value.values
            ):
                self.findings.append((line, "formatted-sensitive-assignment"))

    def visit_Assign(self, node: ast.Assign) -> None:
        for target in node.targets:
            for key in _target_keys(target):
                self._check_value(key, node.value, node.lineno)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        for key in _target_keys(node.target):
            self._check_value(key, node.value, node.lineno)
        self.generic_visit(node)

    def visit_Dict(self, node: ast.Dict) -> None:
        for key_node, value_node in zip(node.keys, node.values):
            key = _literal_string(key_node)
            self._check_value(key, value_node, getattr(value_node, "lineno", node.lineno))
        self.generic_visit(node)

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        positional = [*node.args.posonlyargs, *node.args.args]
        if node.args.defaults:
            for arg, default in zip(positional[-len(node.args.defaults) :], node.args.defaults):
                self._check_value(arg.arg, default, default.lineno)
        for arg, default in zip(node.args.kwonlyargs, node.args.kw_defaults):
            if default is not None:
                self._check_value(arg.arg, default, default.lineno)
        self.generic_visit(node)

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_Call(self, node: ast.Call) -> None:
        for kw in node.keywords:
            if kw.arg is not None:
                self._check_value(kw.arg, kw.value, kw.value.lineno)

        func_name = ""
        if isinstance(node.func, ast.Name):
            func_name = node.func.id
        elif isinstance(node.func, ast.Attribute):
            func_name = node.func.attr

        if func_name in {"getenv", "get"} and node.args:
            env_name = _literal_string(node.args[0])
            if is_sensitive_key(env_name):
                default_node: ast.AST | None = node.args[1] if len(node.args) > 1 else None
                for kw in node.keywords:
                    if kw.arg in {"default", "fallback"}:
                        default_node = kw.value
                default_value = _literal_string(default_node)
                if default_value:
                    self.findings.append(
                        (getattr(default_node, "lineno", node.lineno), "sensitive-env-default")
                    )
        self.generic_visit(node)


def _scan_python(text: str) -> list[tuple[int, str]]:
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        raise CaptureError("app/main.py is not valid Python") from exc
    visitor = PythonSecretVisitor()
    visitor.visit(tree)
    return visitor.findings


def _scan_toml(text: str) -> list[tuple[int, str]]:
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise CaptureError("pyproject.toml is invalid TOML") from exc
    findings: list[tuple[int, str]] = []

    def walk(value: object, key: str | None = None) -> None:
        if key is not None and is_sensitive_key(key):
            if isinstance(value, str) and value:
                findings.append((0, "toml-sensitive-value"))
        if isinstance(value, dict):
            for child_key, child_value in value.items():
                walk(child_value, str(child_key))
        elif isinstance(value, list):
            for child in value:
                walk(child, key)

    walk(data)
    return findings


_VAR_REF = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$")


def _docker_logical_lines(text: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    buf = ""
    start = 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        stripped = raw.strip()
        if not buf:
            start = lineno
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        if buf:
            out.append((start, buf))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def _scan_dockerfile(text: str) -> list[tuple[int, str]]:
    findings: list[tuple[int, str]] = []
    for lineno, logical in _docker_logical_lines(text):
        if not logical or logical.startswith("#"):
            continue
        parts = logical.split(None, 1)
        if len(parts) != 2 or parts[0].upper() not in {"ENV", "ARG"}:
            continue
        instruction, rest = parts[0].upper(), parts[1]
        try:
            tokens = shlex.split(rest, posix=True)
        except ValueError as exc:
            raise CaptureError("Dockerfile shell tokenization failed") from exc
        pairs: list[tuple[str, str]] = []
        if any("=" in token for token in tokens):
            for token in tokens:
                if "=" not in token:
                    continue
                key, value = token.split("=", 1)
                pairs.append((key, value))
        elif tokens:
            pairs.append((tokens[0], " ".join(tokens[1:])))
        for key, value in pairs:
            if is_sensitive_key(key) and value and _VAR_REF.fullmatch(value) is None:
                findings.append((lineno, f"docker-{instruction.lower()}-sensitive-value"))
    return findings


def scan_sources(files: dict[str, bytes]) -> None:
    findings: list[tuple[str, int, str]] = []
    for name, data in files.items():
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise CaptureError(f"{name} is not UTF-8") from exc
        if "\x00" in text:
            raise CaptureError(f"{name} contains NUL bytes")

        for line, kind in _generic_secret_findings(name, text):
            findings.append((name, line, kind))
        if name == "app/main.py":
            for line, kind in _scan_python(text):
                findings.append((name, line, kind))
        elif name == "pyproject.toml":
            for line, kind in _scan_toml(text):
                findings.append((name, line, kind))
        elif name == "Dockerfile":
            for line, kind in _scan_dockerfile(text):
                findings.append((name, line, kind))

    if findings:
        name, line, kind = findings[0]
        raise CaptureError(f"secret scan rejected {name}:{line}:{kind}")


def write_deterministic_zip(files: dict[str, bytes], destination: pathlib.Path) -> None:
    with zipfile.ZipFile(
        destination, mode="x", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as zf:
        for name in ALLOWED_FILES:
            if name not in files:
                continue
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (0o100644 & 0xFFFF) << 16
            info.flag_bits = 0
            zf.writestr(info, files[name])


def prepare_output_dir(path: pathlib.Path) -> None:
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink():
        raise CaptureError("output parent invalid")
    if path.exists() or path.is_symlink():
        raise CaptureError("output directory already exists")
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    if path.is_symlink() or not path.is_dir():
        raise CaptureError("output directory creation invalid")


def emit_outputs(
    output: pathlib.Path,
    files: dict[str, bytes],
    health: dict[str, str],
) -> None:
    prepare_output_dir(output)

    source_zip = output / "controlhub-source.zip"
    manifest_path = output / "controlhub-manifest.json"
    validation_path = output / "validation.txt"
    sha_path = output / "sha256.txt"

    write_deterministic_zip(files, source_zip)

    manifest = {
        "schema": "afz-controlhub-source-artifact-v1",
        "target": TARGET,
        "captured_at_utc": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "health": health,
        "files": [
            {
                "name": name,
                "size": len(files[name]),
                "sha256": _sha(files[name]),
            }
            for name in ALLOWED_FILES
            if name in files
        ],
        "source_zip_sha256": _sha(source_zip.read_bytes()),
        "secret_values_emitted": False,
        "remote_mutation_performed": False,
    }
    manifest_bytes = (
        json.dumps(manifest, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    manifest_path.write_bytes(manifest_bytes)

    validation_path.write_text(
        "REMOTE_ENVELOPE_VALIDATION=PASS\n"
        "SOURCE_SECRET_SCAN=PASS\n"
        "DETERMINISTIC_REPACK=PASS\n"
        "HEALTH_IDENTITY_VALIDATION=PASS\n"
        "REMOTE_MUTATION_PERFORMED=false\n",
        encoding="utf-8",
    )
    sha_path.write_text(
        f"{_sha(source_zip.read_bytes())}  controlhub-source.zip\n"
        f"{_sha(manifest_bytes)}  controlhub-manifest.json\n",
        encoding="utf-8",
    )

    actual = {p.name for p in output.iterdir()}
    if actual != set(OUTPUT_NAMES):
        raise CaptureError("output file set is not exact")
    if any(p.is_symlink() or not p.is_file() for p in output.iterdir()):
        raise CaptureError("output contains non-regular entry")


def capture(output: pathlib.Path) -> None:
    health = check_health()
    envelope = fetch_remote_envelope()
    files = validate_envelope(envelope)
    scan_sources(files)
    emit_outputs(output, files, health)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        capture(pathlib.Path(args.output))
    except CaptureError as exc:
        print(f"CAPTURE_RESULT=FAIL reason={exc}", file=sys.stderr)
        return 2
    except Exception:
        print("CAPTURE_RESULT=FAIL reason=unexpected-error", file=sys.stderr)
        return 3
    print("CAPTURE_RESULT=PASS")
    print("SECRET_VALUES_EMITTED=false")
    print("REMOTE_MUTATION_PERFORMED=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
