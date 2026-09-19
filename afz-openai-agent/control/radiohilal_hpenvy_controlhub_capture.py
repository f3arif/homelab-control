#!/usr/bin/env python3
"""Read-only HPENVY AFZ Control Hub source capture.

The already-authorized Tailscale SSH SFTP subsystem is the only remote
execution boundary. One SFTP session establishes the target host key through
the fixed tailnet identity, then a second SFTP session pins that key and reads
only app/main.py. No login shell, remote command, tar, service control, package
change, HTTP request, or remote write is performed.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import pathlib
import re
try:
    import resource
except ImportError:  # pragma: no cover - Windows review host
    resource = None
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


MAX_KNOWN_HOSTS_BYTES = 1024 * 1024
REMOTE_TIMEOUT_SECONDS = 45


def build_hostkey_probe_batch() -> str:
    return "pwd\nquit\n"


def build_source_fetch_batch() -> str:
    return f"get {REMOTE_PATH} source.py\nquit\n"


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


def _sftp_args(
    *,
    sftp: str,
    tailscale: str,
    batch: pathlib.Path,
    known_hosts: pathlib.Path,
    strict_host_key: str,
) -> list[str]:
    if strict_host_key not in {"accept-new", "yes"}:
        raise CaptureError("SFTP host-key mode invalid")
    return [
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
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        f"StrictHostKeyChecking={strict_host_key}",
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


def _sftp_child_env(home: pathlib.Path) -> dict[str, str]:
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }


def establish_pinned_host_key_via_sftp(runner_temp: pathlib.Path) -> bytes:
    if os.name != "posix":
        raise CaptureError("host-key probe requires POSIX GitHub runner")
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
        prefix="radiohilal-hostkey-probe-",
        dir=runner_temp,
    ) as td:
        stage = pathlib.Path(td)
        home = stage / "home"
        home.mkdir(mode=0o700)
        batch = stage / "batch.txt"
        known_hosts = stage / "known_hosts"
        batch.write_text(build_hostkey_probe_batch(), encoding="utf-8", newline="\n")
        os.chmod(batch, 0o600)
        args = _sftp_args(
            sftp=sftp,
            tailscale=tailscale,
            batch=batch,
            known_hosts=known_hosts,
            strict_host_key="accept-new",
        )
        try:
            proc = subprocess.run(
                args,
                cwd=stage,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=REMOTE_TIMEOUT_SECONDS,
                env=_sftp_child_env(home),
                preexec_fn=_make_file_limit(MAX_KNOWN_HOSTS_BYTES + 4096),
            )
        except subprocess.TimeoutExpired as exc:
            raise CaptureError("SFTP host-key probe timed out") from exc
        if proc.returncode != 0:
            raise CaptureError(
                f"SFTP host-key probe failed with exit {proc.returncode}"
            )
        info = _is_regular_nonsymlink(known_hosts)
        if info.st_size <= 0 or info.st_size > MAX_KNOWN_HOSTS_BYTES:
            raise CaptureError("known_hosts capture size invalid")
        try:
            known_text = known_hosts.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise CaptureError("known_hosts capture is not UTF-8") from exc
        return filter_target_known_hosts(known_text)


def fetch_source_via_pinned_sftp(
    runner_temp: pathlib.Path,
    known_hosts_bytes: bytes,
) -> bytes:
    if os.name != "posix":
        raise CaptureError("source capture requires POSIX GitHub runner")
    try:
        filtered = filter_target_known_hosts(
            known_hosts_bytes.decode("utf-8", errors="strict")
        )
    except UnicodeDecodeError as exc:
        raise CaptureError("known_hosts input is not UTF-8") from exc
    if filtered != known_hosts_bytes:
        raise CaptureError("known_hosts input is not canonical filtered form")
    if runner_temp.is_symlink() or not runner_temp.is_dir():
        raise CaptureError("RUNNER_TEMP directory invalid")
    sftp = shutil.which("sftp")
    tailscale = shutil.which("tailscale")
    if not sftp or not os.path.isabs(sftp):
        raise CaptureError("sftp executable missing")
    if not tailscale or not os.path.isabs(tailscale):
        raise CaptureError("tailscale executable missing")
    if any(ch.isspace() for ch in tailscale):
        raise CaptureError("tailscale executable path contains whitespace")

    with tempfile.TemporaryDirectory(
        prefix="radiohilal-source-sftp-",
        dir=runner_temp,
    ) as td:
        stage = pathlib.Path(td)
        home = stage / "home"
        home.mkdir(mode=0o700)
        batch = stage / "batch.txt"
        known_hosts = stage / "known_hosts"
        source_path = stage / "source.py"
        known_hosts.write_bytes(known_hosts_bytes)
        os.chmod(known_hosts, 0o600)
        batch.write_text(build_source_fetch_batch(), encoding="utf-8", newline="\n")
        os.chmod(batch, 0o600)
        args = _sftp_args(
            sftp=sftp,
            tailscale=tailscale,
            batch=batch,
            known_hosts=known_hosts,
            strict_host_key="yes",
        )
        try:
            proc = subprocess.run(
                args,
                cwd=stage,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=REMOTE_TIMEOUT_SECONDS,
                env=_sftp_child_env(home),
                preexec_fn=_make_file_limit(MAX_FILE_BYTES + 4096),
            )
        except subprocess.TimeoutExpired as exc:
            raise CaptureError("SFTP source capture timed out") from exc
        if proc.returncode != 0:
            raise CaptureError(
                f"SFTP source capture failed with exit {proc.returncode}"
            )
        info = _is_regular_nonsymlink(source_path)
        if info.st_size <= 0 or info.st_size > MAX_FILE_BYTES:
            raise CaptureError("SFTP source capture size invalid")
        data = source_path.read_bytes()
        if len(data) != info.st_size:
            raise CaptureError("SFTP source capture size changed during read")
        return data


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


def _is_empty_value(node: ast.AST | None, constants: dict[str, object]) -> bool:
    if node is None:
        return True
    if isinstance(node, ast.Constant) and node.value is None:
        return True
    value = _static_value(node, constants)
    return value in {"", b""}


def _is_os_environ(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.Attribute)
        and node.attr == "environ"
        and isinstance(node.value, ast.Name)
        and node.value.id == "os"
    )


def _is_safe_dynamic_secret_source(
    node: ast.AST | None,
    constants: dict[str, object],
) -> bool:
    if node is None:
        return False
    if isinstance(node, ast.Subscript) and _is_os_environ(node.value):
        key = _static_value(node.slice, constants)
        return is_sensitive_key(key)
    if isinstance(node, ast.Call):
        env_key = None
        if (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "getenv"
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "os"
        ):
            env_key = _static_value(node.args[0], constants) if node.args else None
        elif (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "get"
            and _is_os_environ(node.func.value)
        ):
            env_key = _static_value(node.args[0], constants) if node.args else None
        if is_sensitive_key(env_key):
            default_node = node.args[1] if len(node.args) > 1 else None
            for kw in node.keywords:
                if kw.arg in {"default", "fallback"}:
                    default_node = kw.value
                elif kw.arg is not None:
                    return False
            return _is_empty_value(default_node, constants)
        return False
    if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.Or):
        saw_dynamic = False
        for item in node.values:
            if _is_safe_dynamic_secret_source(item, constants):
                saw_dynamic = True
                continue
            if _is_empty_value(item, constants):
                continue
            return False
        return saw_dynamic
    return False


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
        if _is_safe_dynamic_secret_source(value_node, self.constants):
            return
        value = _static_value(value_node, self.constants)
        if _static_is_nonempty(value):
            self.findings.append((line, "literal-sensitive-assignment"))
            return
        if _is_empty_value(value_node, self.constants):
            return
        if isinstance(value_node, ast.JoinedStr):
            if any(
                isinstance(part, ast.Constant)
                and isinstance(part.value, str)
                and part.value
                for part in value_node.values
            ):
                self.findings.append((line, "formatted-sensitive-assignment"))
                return
        self.findings.append((line, "unsupported-sensitive-expression"))

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
                self.visit(default)
        for arg, default in zip(node.args.kwonlyargs, node.args.kw_defaults):
            if default is not None:
                self._record_sensitive_value(arg.arg, default, default.lineno)
                self.visit(default)

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
                self.visit(default)
        for arg, default in zip(node.args.kwonlyargs, node.args.kw_defaults):
            if default is not None:
                self._record_sensitive_value(arg.arg, default, default.lineno)
                self.visit(default)
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
        "transport": "tailscale-sftp-hostkey-probe-plus-pinned-sftp-source-read",
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
        "SFTP_HOSTKEY_PROBE=PASS\n"
        "PINNED_SFTP_SOURCE_READ=PASS\n"
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

    known_hosts_bytes = establish_pinned_host_key_via_sftp(runner_temp)
    source = fetch_source_via_pinned_sftp(
        runner_temp,
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
