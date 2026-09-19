#!/usr/bin/env python3
"""Read-only HPENVY AFZ Control Hub source capture.

The already-authorized Tailscale SSH SFTP subsystem is used only to attest the
target user's login shell from /etc/passwd. The source itself is read by one
fixed noninteractive command that immediately execs isolated Python and opens
main.py through directory file descriptors with O_NOFOLLOW. No tar, service
control, package changes, HTTP requests, or remote writes are performed.
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
try:
    import resource
except ImportError:  # pragma: no cover - Windows review host
    resource = None
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

TARGET = "coolyo@100.71.26.69"
TARGET_USER = "coolyo"
TARGET_HOST = "100.71.26.69"
REMOTE_PATH = "/home/coolyo/afz-control-hub/app/main.py"

MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_METADATA_BYTES = 64 * 1024
SFTP_TIMEOUT_SECONDS = 45

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


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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


PASSWD_REMOTE_PATH = "/etc/passwd"
MAX_PASSWD_BYTES = 1024 * 1024
MAX_KNOWN_HOSTS_BYTES = 1024 * 1024
MAX_ENVELOPE_BYTES = 8 * 1024 * 1024
REMOTE_TIMEOUT_SECONDS = 45


def build_shell_attestation_batch() -> str:
    return (
        f"@get {PASSWD_REMOTE_PATH} passwd.txt\n"
        "@quit\n"
    )


def _make_file_limit(limit: int):
    def apply_limit() -> None:
        if resource is None:
            raise CaptureError("POSIX resource limits unavailable")
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    return apply_limit


def _is_regular_nonsymlink(path: pathlib.Path) -> os.stat_result:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise CaptureError(f"local capture file is not regular: {path.name}")
    return info


def parse_attested_bash_login_shell(text: str) -> str:
    if "\x00" in text:
        raise CaptureError("passwd capture contains NUL")
    matches = []
    for line in text.splitlines():
        fields = line.split(":")
        if len(fields) == 7 and fields[0] == TARGET_USER:
            matches.append(fields)
    if len(matches) != 1:
        raise CaptureError("target user passwd entry not unique")
    fields = matches[0]
    if fields[5] != "/home/coolyo":
        raise CaptureError("target user home directory unexpected")
    shell = fields[6]
    if shell not in {"/bin/bash", "/usr/bin/bash"}:
        raise CaptureError("target user login shell is not Bash")
    return shell


def filter_target_known_hosts(text: str) -> bytes:
    if "\x00" in text or len(text.encode("utf-8")) > MAX_KNOWN_HOSTS_BYTES:
        raise CaptureError("known_hosts capture invalid")
    selected: list[str] = []
    for raw in text.splitlines():
        parts = raw.split()
        if len(parts) != 3 or parts[0] != TARGET_HOST:
            continue
        host, key_type, key_data = parts
        if re.fullmatch(r"[A-Za-z0-9@._+-]{3,100}", key_type) is None:
            raise CaptureError("known_hosts key type invalid")
        if re.fullmatch(r"[A-Za-z0-9+/=]{20,2000}", key_data) is None:
            raise CaptureError("known_hosts key data invalid")
        selected.append(f"{host} {key_type} {key_data}")
    if not selected:
        raise CaptureError("target SSH host key missing")
    if len(selected) != len(set(selected)):
        raise CaptureError("duplicate target SSH host key")
    return ("\n".join(selected) + "\n").encode("utf-8")


def attest_bash_login_shell_via_sftp(
    runner_temp: pathlib.Path,
) -> tuple[str, bytes]:
    if os.name != "posix":
        raise CaptureError("shell attestation requires POSIX GitHub runner")

    sftp = shutil.which("sftp")
    tailscale = shutil.which("tailscale")
    if not sftp or not os.path.isabs(sftp):
        raise CaptureError("sftp executable missing")
    if not tailscale or not os.path.isabs(tailscale):
        raise CaptureError("tailscale executable missing")
    if any(ch.isspace() for ch in tailscale):
        raise CaptureError("tailscale executable path contains whitespace")
    if runner_temp.is_symlink() or not runner_temp.is_dir():
        raise CaptureError("RUNNER_TEMP directory invalid")

    with tempfile.TemporaryDirectory(
        prefix="radiohilal-shell-attest-",
        dir=runner_temp,
    ) as td:
        stage = pathlib.Path(td)
        home = stage / "home"
        home.mkdir(mode=0o700)
        batch = stage / "batch.txt"
        passwd_path = stage / "passwd.txt"
        known_hosts_path = stage / "known_hosts"

        batch.write_text(
            build_shell_attestation_batch(),
            encoding="utf-8",
            newline="\n",
        )
        os.chmod(batch, 0o600)

        args = [
            sftp,
            "-q",
            "-F",
            "none",
            "-B",
            "32768",
            "-R",
            "1",
            "-b",
            str(batch),
            "-o",
            f"UserKnownHostsFile={known_hosts_path}",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "CanonicalizeHostname=no",
            "-o",
            "HashKnownHosts=no",
            "-o",
            f"ProxyCommand={tailscale} nc %h %p",
            "-o",
            "ForwardX11=no",
            "-o",
            "PermitLocalCommand=no",
            "-o",
            "ClearAllForwardings=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "ForwardAgent=no",
            "-o",
            "SendEnv=-*",
            "-o",
            "LogLevel=ERROR",
            TARGET,
        ]
        child_env = {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "LANG": "C",
            "LC_ALL": "C",
        }
        try:
            proc = subprocess.run(
                args,
                cwd=stage,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=REMOTE_TIMEOUT_SECONDS,
                env=child_env,
                preexec_fn=_make_file_limit(
                    max(MAX_PASSWD_BYTES, MAX_KNOWN_HOSTS_BYTES) + 4096
                ),
            )
        except subprocess.TimeoutExpired as exc:
            raise CaptureError("SFTP shell attestation timed out") from exc
        if proc.returncode != 0:
            raise CaptureError(
                f"SFTP shell attestation failed with exit {proc.returncode}"
            )

        info = _is_regular_nonsymlink(passwd_path)
        if info.st_size <= 0 or info.st_size > MAX_PASSWD_BYTES:
            raise CaptureError("passwd capture size invalid")
        try:
            text = passwd_path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise CaptureError("passwd capture is not UTF-8") from exc

        known_info = _is_regular_nonsymlink(known_hosts_path)
        if (
            known_info.st_size <= 0
            or known_info.st_size > MAX_KNOWN_HOSTS_BYTES
        ):
            raise CaptureError("known_hosts capture size invalid")
        try:
            known_text = known_hosts_path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise CaptureError("known_hosts capture is not UTF-8") from exc
        filtered_known_hosts = filter_target_known_hosts(known_text)

    return parse_attested_bash_login_shell(text), filtered_known_hosts


REMOTE_READER = r"""
import base64
import hashlib
import json
import os
import pwd
import socket
import stat

MAX_FILE = 5 * 1024 * 1024
DANGEROUS_ENV = {
    "BASH_ENV",
    "ENV",
    "PYTHONPATH",
    "PYTHONHOME",
    "PYTHONSTARTUP",
    "TAR_OPTIONS",
    "GIT_SSH_COMMAND",
}

if socket.gethostname().lower() != "hpenvy":
    raise SystemExit(41)
if pwd.getpwuid(os.getuid()).pw_name != "coolyo":
    raise SystemExit(42)
if DANGEROUS_ENV.intersection(os.environ):
    raise SystemExit(43)
if os.environ.get("HOME") != "/home/coolyo":
    raise SystemExit(44)
if os.environ.get("USER") != "coolyo":
    raise SystemExit(45)
if os.path.basename(os.environ.get("SHELL", "")) != "bash":
    raise SystemExit(46)

required_flags = ("O_NOFOLLOW", "O_CLOEXEC", "O_DIRECTORY", "O_NONBLOCK")
if any(not hasattr(os, name) for name in required_flags):
    raise SystemExit(47)

def open_dir(name, *, dir_fd=None):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    return os.open(name, flags, dir_fd=dir_fd)

def read_regular(name, *, dir_fd):
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    fd = os.open(name, flags, dir_fd=dir_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SystemExit(48)
        if info.st_size <= 0 or info.st_size > MAX_FILE:
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
        if len(data) != info.st_size:
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
            data = read_regular("main.py", dir_fd=app_fd)
        finally:
            os.close(app_fd)
    finally:
        os.close(root_fd)
finally:
    os.close(home_fd)

print(json.dumps({
    "schema": "afz-controlhub-source-capture-v2",
    "host": "hpenvy",
    "user": "coolyo",
    "size": len(data),
    "sha256": hashlib.sha256(data).hexdigest(),
    "data_b64": base64.b64encode(data).decode("ascii"),
}, separators=(",", ":"), sort_keys=True))
"""


def build_remote_reader_command() -> str:
    encoded = base64.b64encode(REMOTE_READER.encode("utf-8")).decode("ascii")
    bootstrap = (
        "import base64;"
        f"exec(compile(base64.b64decode({encoded!r}),"
        "'<afz-controlhub-readonly-capture>','exec'))"
    )
    return "exec /usr/bin/python3 -I -S -c " + shlex.quote(bootstrap)


def _reject_duplicate_json_keys(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise CaptureError(f"duplicate JSON key rejected: {key}")
        obj[key] = value
    return obj


def _decode_remote_envelope(raw: bytes) -> bytes:
    if len(raw) <= 0 or len(raw) > MAX_ENVELOPE_BYTES:
        raise CaptureError("remote capture envelope size invalid")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CaptureError("remote capture envelope is not UTF-8") from exc
    try:
        obj = json.loads(text, object_pairs_hook=_reject_duplicate_json_keys)
    except CaptureError:
        raise
    except json.JSONDecodeError as exc:
        raise CaptureError("remote capture envelope is not strict JSON") from exc
    if not isinstance(obj, dict):
        raise CaptureError("remote capture envelope type invalid")
    if set(obj) != {"schema", "host", "user", "size", "sha256", "data_b64"}:
        raise CaptureError("remote capture envelope fields invalid")
    if obj["schema"] != "afz-controlhub-source-capture-v2":
        raise CaptureError("remote capture envelope schema invalid")
    if obj["host"] != "hpenvy" or obj["user"] != TARGET_USER:
        raise CaptureError("remote capture identity invalid")

    size = obj["size"]
    digest = obj["sha256"]
    encoded = obj["data_b64"]
    if isinstance(size, bool) or not isinstance(size, int):
        raise CaptureError("remote source size type invalid")
    if size <= 0 or size > MAX_FILE_BYTES:
        raise CaptureError("remote source size outside bound")
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise CaptureError("remote source hash invalid")
    if not isinstance(encoded, str):
        raise CaptureError("remote source payload type invalid")
    try:
        data = base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise CaptureError("remote source payload base64 invalid") from exc
    if len(data) != size or _sha(data) != digest:
        raise CaptureError("remote source payload integrity mismatch")
    return data


def fetch_source_via_identity_bound_exec(
    runner_temp: pathlib.Path,
    login_shell: str,
    known_hosts_bytes: bytes,
) -> bytes:
    if os.name != "posix":
        raise CaptureError("source capture requires POSIX GitHub runner")
    if login_shell not in {"/bin/bash", "/usr/bin/bash"}:
        raise CaptureError("Bash login shell attestation missing")

    ssh = shutil.which("ssh")
    tailscale = shutil.which("tailscale")
    if not ssh or not os.path.isabs(ssh):
        raise CaptureError("ssh executable missing")
    if not tailscale or not os.path.isabs(tailscale):
        raise CaptureError("tailscale executable missing")
    if any(ch.isspace() for ch in tailscale):
        raise CaptureError("tailscale executable path contains whitespace")
    if runner_temp.is_symlink() or not runner_temp.is_dir():
        raise CaptureError("RUNNER_TEMP directory invalid")
    filtered = filter_target_known_hosts(
        known_hosts_bytes.decode("utf-8", errors="strict")
    )
    if filtered != known_hosts_bytes:
        raise CaptureError("known_hosts input is not canonical filtered form")

    with tempfile.TemporaryDirectory(
        prefix="radiohilal-source-exec-",
        dir=runner_temp,
    ) as td:
        stage = pathlib.Path(td)
        home = stage / "home"
        home.mkdir(mode=0o700)
        known_hosts = stage / "known_hosts"
        known_hosts.write_bytes(known_hosts_bytes)
        os.chmod(known_hosts, 0o600)
        stdout_path = stage / "envelope.json"
        args = [
            ssh,
            "-F",
            "none",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "CanonicalizeHostname=no",
            "-o",
            f"ProxyCommand={tailscale} nc %h %p",
            "-o",
            "ForwardX11=no",
            "-o",
            "PermitLocalCommand=no",
            "-o",
            "ClearAllForwardings=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "ForwardAgent=no",
            "-o",
            "RequestTTY=no",
            "-o",
            "SendEnv=-*",
            "-o",
            "LogLevel=ERROR",
            "-l",
            TARGET_USER,
            TARGET_HOST,
            build_remote_reader_command(),
        ]
        child_env = {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "LANG": "C",
            "LC_ALL": "C",
        }

        with stdout_path.open("xb") as stdout_file:
            try:
                proc = subprocess.run(
                    args,
                    cwd=stage,
                    stdin=subprocess.DEVNULL,
                    stdout=stdout_file,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=REMOTE_TIMEOUT_SECONDS,
                    env=child_env,
                    preexec_fn=_make_file_limit(MAX_ENVELOPE_BYTES + 4096),
                )
            except subprocess.TimeoutExpired as exc:
                raise CaptureError("remote source capture timed out") from exc

        if proc.returncode != 0:
            raise CaptureError(
                f"remote source capture failed with exit {proc.returncode}"
            )
        info = _is_regular_nonsymlink(stdout_path)
        if info.st_size <= 0 or info.st_size > MAX_ENVELOPE_BYTES:
            raise CaptureError("remote capture envelope file size invalid")
        return _decode_remote_envelope(stdout_path.read_bytes())

def _static_value(node: ast.AST | None, constants: dict[str, object]) -> object:
    if node is None:
        return None
    if isinstance(node, ast.Constant):
        if isinstance(node.value, (str, bytes, int, float, bool, type(None))):
            return node.value
        return None
    if isinstance(node, ast.Name):
        return constants.get(node.id)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = _static_value(node.left, constants)
        right = _static_value(node.right, constants)
        if isinstance(left, str) and isinstance(right, str):
            return left + right
        if isinstance(left, bytes) and isinstance(right, bytes):
            return left + right
        return None
    if isinstance(node, ast.BoolOp):
        values = [_static_value(item, constants) for item in node.values]
        for value in values:
            if _static_is_nonempty(value):
                return value
        if all(value is not None for value in values):
            return values[-1] if values else None
        return None
    if isinstance(node, ast.IfExp):
        body = _static_value(node.body, constants)
        alternate = _static_value(node.orelse, constants)
        if _static_is_nonempty(body):
            return body
        if _static_is_nonempty(alternate):
            return alternate
        if body is not None and alternate is not None and body == alternate:
            return body
        return None
    if isinstance(node, ast.JoinedStr):
        parts: list[str] = []
        for part in node.values:
            if isinstance(part, ast.Constant) and isinstance(part.value, str):
                parts.append(part.value)
            elif isinstance(part, ast.FormattedValue):
                value = _static_value(part.value, constants)
                if isinstance(value, (str, int, float, bool)):
                    parts.append(str(value))
                else:
                    return None
            else:
                return None
        return "".join(parts)
    return None


def _static_is_nonempty(value: object) -> bool:
    if value is None:
        return False
    if isinstance(value, (str, bytes)):
        return len(value) > 0
    return True


def _subscript_key(node: ast.Subscript, constants: dict[str, object]) -> str | None:
    value = _static_value(node.slice, constants)
    return value if isinstance(value, str) else None


def _target_keys(node: ast.AST, constants: dict[str, object]) -> list[str]:
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, ast.Attribute):
        return [node.attr]
    if isinstance(node, ast.Subscript):
        key = _subscript_key(node, constants)
        return [key] if key is not None else []
    if isinstance(node, (ast.Tuple, ast.List)):
        out: list[str] = []
        for item in node.elts:
            out.extend(_target_keys(item, constants))
        return out
    return []


def _target_value_pairs(
    target: ast.AST,
    value: ast.AST,
) -> list[tuple[ast.AST, ast.AST]]:
    if isinstance(target, (ast.Tuple, ast.List)):
        if isinstance(value, (ast.Tuple, ast.List)) and len(target.elts) == len(value.elts):
            out: list[tuple[ast.AST, ast.AST]] = []
            for child_target, child_value in zip(target.elts, value.elts):
                out.extend(_target_value_pairs(child_target, child_value))
            return out
        return [(child, value) for child in target.elts]
    return [(target, value)]


class PythonSecretVisitor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.findings: list[tuple[int, str]] = []
        self.constants: dict[str, object] = {}

    def _record_sensitive_value(
        self,
        key: object,
        value_node: ast.AST | None,
        line: int,
    ) -> None:
        if not is_sensitive_key(key):
            return
        value = _static_value(value_node, self.constants)
        if _static_is_nonempty(value):
            self.findings.append((line, "literal-sensitive-assignment"))
            return
        if isinstance(value_node, ast.JoinedStr):
            if any(
                isinstance(part, ast.Constant)
                and isinstance(part.value, str)
                and part.value
                for part in value_node.values
            ):
                self.findings.append((line, "formatted-sensitive-assignment"))

    def _update_constant(self, target: ast.AST, value_node: ast.AST) -> None:
        if not isinstance(target, ast.Name):
            return
        value = _static_value(value_node, self.constants)
        if value is None:
            self.constants.pop(target.id, None)
        else:
            self.constants[target.id] = value


    def _visit_assignment_pair(self, target: ast.AST, value: ast.AST) -> None:
        for key in _target_keys(target, self.constants):
            self._record_sensitive_value(key, value, getattr(value, "lineno", target.lineno))
        self._update_constant(target, value)

    def visit_Assign(self, node: ast.Assign) -> None:
        for target in node.targets:
            for child_target, child_value in _target_value_pairs(target, node.value):
                self._visit_assignment_pair(child_target, child_value)
        self.visit(node.value)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            for child_target, child_value in _target_value_pairs(node.target, node.value):
                self._visit_assignment_pair(child_target, child_value)
            self.visit(node.value)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        self._visit_assignment_pair(node.target, node.value)
        self.visit(node.value)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        for key in _target_keys(node.target, self.constants):
            self._record_sensitive_value(key, node.value, node.lineno)
        self.visit(node.value)

    def visit_Dict(self, node: ast.Dict) -> None:
        for key_node, value_node in zip(node.keys, node.values):
            key = _static_value(key_node, self.constants)
            self._record_sensitive_value(
                key,
                value_node,
                getattr(value_node, "lineno", node.lineno),
            )
        self.generic_visit(node)

    def _check_function_defaults(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
        positional = [*node.args.posonlyargs, *node.args.args]
        if node.args.defaults:
            for arg, default in zip(
                positional[-len(node.args.defaults) :],
                node.args.defaults,
            ):
                self._record_sensitive_value(arg.arg, default, default.lineno)
        for arg, default in zip(node.args.kwonlyargs, node.args.kw_defaults):
            if default is not None:
                self._record_sensitive_value(arg.arg, default, default.lineno)

    def _visit_function(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
        self._check_function_defaults(node)
        for decorator in node.decorator_list:
            self.visit(decorator)
        if node.returns is not None:
            self.visit(node.returns)
        saved = self.constants
        self.constants = dict(saved)
        for arg in [
            *node.args.posonlyargs,
            *node.args.args,
            *node.args.kwonlyargs,
        ]:
            self.constants.pop(arg.arg, None)
        if node.args.vararg is not None:
            self.constants.pop(node.args.vararg.arg, None)
        if node.args.kwarg is not None:
            self.constants.pop(node.args.kwarg.arg, None)
        for statement in node.body:
            self.visit(statement)
        self.constants = saved

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._visit_function(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self._visit_function(node)

    def visit_Lambda(self, node: ast.Lambda) -> None:
        positional = [*node.args.posonlyargs, *node.args.args]
        if node.args.defaults:
            for arg, default in zip(
                positional[-len(node.args.defaults) :],
                node.args.defaults,
            ):
                self._record_sensitive_value(arg.arg, default, default.lineno)
        for arg, default in zip(node.args.kwonlyargs, node.args.kw_defaults):
            if default is not None:
                self._record_sensitive_value(arg.arg, default, default.lineno)
        self.visit(node.body)

    def visit_Call(self, node: ast.Call) -> None:
        for kw in node.keywords:
            if kw.arg is not None:
                self._record_sensitive_value(kw.arg, kw.value, kw.value.lineno)

        func_name = ""
        if isinstance(node.func, ast.Name):
            func_name = node.func.id
        elif isinstance(node.func, ast.Attribute):
            func_name = node.func.attr

        if func_name in {"getenv", "get"} and node.args:
            env_name = _static_value(node.args[0], self.constants)
            if is_sensitive_key(env_name):
                default_node: ast.AST | None = node.args[1] if len(node.args) > 1 else None
                for kw in node.keywords:
                    if kw.arg in {"default", "fallback"}:
                        default_node = kw.value
                default_value = _static_value(default_node, self.constants)
                if _static_is_nonempty(default_value):
                    self.findings.append(
                        (
                            getattr(default_node, "lineno", node.lineno),
                            "sensitive-env-default",
                        )
                    )

        if func_name == "setattr" and len(node.args) >= 3:
            key = _static_value(node.args[1], self.constants)
            self._record_sensitive_value(key, node.args[2], node.lineno)

        self.generic_visit(node)


def scan_python_source(data: bytes) -> None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CaptureError("app/main.py is not UTF-8") from exc
    if "\x00" in text:
        raise CaptureError("app/main.py contains NUL bytes")

    generic: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if PRIVATE_KEY.search(line):
            generic.append((lineno, "private-key"))
        if TOKEN_PREFIX.search(line):
            generic.append((lineno, "token-prefix"))
        if CREDENTIAL_URL.search(line):
            generic.append((lineno, "credential-url"))
        if JWT.search(line):
            generic.append((lineno, "jwt"))
    if generic:
        line, kind = generic[0]
        raise CaptureError(f"secret scan rejected app/main.py:{line}:{kind}")

    try:
        tree = ast.parse(text, filename="app/main.py")
    except SyntaxError as exc:
        raise CaptureError("app/main.py is not valid Python") from exc

    # Scan parser-folded/static string expressions too, not only physical
    # source lines, so adjacent/concatenated literals cannot split a token.
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Constant, ast.BinOp, ast.JoinedStr)):
            continue
        value = _static_value(node, {})
        if isinstance(value, bytes):
            try:
                candidate = value.decode("utf-8")
            except UnicodeDecodeError:
                continue
        elif isinstance(value, str):
            candidate = value
        else:
            continue
        kind = None
        if PRIVATE_KEY.search(candidate):
            kind = "private-key"
        elif TOKEN_PREFIX.search(candidate):
            kind = "token-prefix"
        elif CREDENTIAL_URL.search(candidate):
            kind = "credential-url"
        elif JWT.search(candidate):
            kind = "jwt"
        if kind is not None:
            raise CaptureError(
                f"secret scan rejected app/main.py:{getattr(node, 'lineno', 0)}:{kind}"
            )

    visitor = PythonSecretVisitor()
    visitor.visit(tree)
    if visitor.findings:
        line, kind = visitor.findings[0]
        raise CaptureError(f"secret scan rejected app/main.py:{line}:{kind}")


def prepare_output_dir(path: pathlib.Path, runner_temp: pathlib.Path) -> None:
    if path.name != "radiohilal-controlhub-capture":
        raise CaptureError("output directory name invalid")
    if path.parent.resolve(strict=True) != runner_temp.resolve(strict=True):
        raise CaptureError("output must be a direct child of RUNNER_TEMP")
    if path.exists() or path.is_symlink():
        raise CaptureError("output directory already exists")
    path.mkdir(mode=0o700)
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise CaptureError("output directory creation invalid")


def write_deterministic_zip(source: bytes, destination: pathlib.Path) -> None:
    with zipfile.ZipFile(
        destination,
        mode="x",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as zf:
        info = zipfile.ZipInfo(REMOTE_PATH.lstrip("/"), date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = (0o100644 & 0xFFFF) << 16
        info.flag_bits = 0
        zf.writestr(info, source)


def emit_outputs(
    output: pathlib.Path,
    runner_temp: pathlib.Path,
    source: bytes,
) -> None:
    prepare_output_dir(output, runner_temp)

    source_zip = output / "controlhub-source.zip"
    manifest_path = output / "controlhub-manifest.json"
    validation_path = output / "validation.txt"
    sha_path = output / "sha256.txt"

    write_deterministic_zip(source, source_zip)
    source_zip_bytes = source_zip.read_bytes()

    manifest = {
        "schema": "afz-controlhub-source-artifact-v2",
        "target": TARGET,
        "remote_path": REMOTE_PATH,
        "transport": "tailscale-sftp-attestation-plus-pinned-openssh-identity-bound-exec",
        "captured_at_utc": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "source": {
            "size": len(source),
            "sha256": _sha(source),
        },
        "source_zip_sha256": _sha(source_zip_bytes),
        "secret_values_emitted": False,
        "remote_mutation_performed": False,
    }
    manifest_bytes = (
        json.dumps(manifest, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    manifest_path.write_bytes(manifest_bytes)

    validation_path.write_text(
        "SFTP_SHELL_ATTESTATION=PASS\n"
        "IDENTITY_BOUND_NOFOLLOW_READ=PASS\n"
        "SOURCE_SECRET_SCAN=PASS\n"
        "DETERMINISTIC_REPACK=PASS\n"
        "REMOTE_MUTATION_PERFORMED=false\n",
        encoding="utf-8",
    )
    sha_path.write_text(
        f"{_sha(source_zip_bytes)}  controlhub-source.zip\n"
        f"{_sha(manifest_bytes)}  controlhub-manifest.json\n",
        encoding="utf-8",
    )

    actual = {p.name for p in output.iterdir()}
    if actual != set(OUTPUT_NAMES):
        raise CaptureError("output file set is not exact")
    for p in output.iterdir():
        info = p.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise CaptureError("output contains non-regular entry")


def capture(output: pathlib.Path) -> None:
    runner_temp_text = os.environ.get("RUNNER_TEMP")
    if not runner_temp_text:
        raise CaptureError("RUNNER_TEMP missing")
    runner_temp = pathlib.Path(runner_temp_text)
    if runner_temp.is_symlink() or not runner_temp.is_dir():
        raise CaptureError("RUNNER_TEMP invalid")

    login_shell, known_hosts_bytes = attest_bash_login_shell_via_sftp(
        runner_temp
    )
    source = fetch_source_via_identity_bound_exec(
        runner_temp,
        login_shell,
        known_hosts_bytes,
    )
    scan_python_source(source)
    emit_outputs(output, runner_temp, source)


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
