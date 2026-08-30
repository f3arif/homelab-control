"""Typed, evidence-bounded Control Hub contracts for the staged H3 worker.

Only fields observed in the existing AFZ Control Hub / direct-worker canary are
modelled here. The live worker claim request/response schema is intentionally
not guessed and remains unavailable until it is recovered from runtime/source.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any, Mapping


PORTABLE_ACTION = "portable-powershell-github"
PORTABLE_REPO = "f3arif/homelab-control"
PORTABLE_PATH = "afz-openai-agent/portable-jobs/lenovo-direct-canary-r1.ps1"
PORTABLE_PROJECT = "AFZ-Direct-Canary"
PORTABLE_WORKER = "lenovo-direct-1"
PORTABLE_CAPABILITIES = frozenset({"windows", "lenovo", "github-portable-powershell"})

CONTROL_HUB_HEALTH_PATH = "/health"
CONTROL_HUB_CREATE_JOB_PATH = "/api/jobs"
OBSERVED_WORKER_CLAIM_PATH = "/claim"
OBSERVED_WORKER_COMPLETE_PATH = "/complete"
CLAIM_SCHEMA_KNOWN = False

_SHA40 = re.compile(r"^[0-9a-fA-F]{40}$")
_SHA64 = re.compile(r"^[0-9a-fA-F]{64}$")


class ContractError(ValueError):
    """Raised when data violates a proven AFZ contract."""


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ContractError(f"{label} must be an object")
    return value


def _exact_keys(value: Mapping[str, Any], expected: frozenset[str], label: str) -> None:
    actual = frozenset(str(key) for key in value.keys())
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ContractError(f"{label} keys mismatch missing={missing} extra={extra}")


def _string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise ContractError(f"{label} must be a string")
    if not allow_empty and not value:
        raise ContractError(f"{label} must not be empty")
    return value


def _int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError(f"{label} must be an integer")
    return value


@dataclass(frozen=True)
class PortablePayload:
    repo: str
    commit: str
    path: str
    sha256: str
    timeout_seconds: int

    KEYS = frozenset({"repo", "commit", "path", "sha256", "timeout_seconds"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "PortablePayload":
        data = _mapping(raw, "portable payload")
        _exact_keys(data, cls.KEYS, "portable payload")
        repo = _string(data["repo"], "repo")
        commit = _string(data["commit"], "commit")
        path = _string(data["path"], "path")
        sha256 = _string(data["sha256"], "sha256")
        timeout_seconds = _int(data["timeout_seconds"], "timeout_seconds")
        if repo != PORTABLE_REPO:
            raise ContractError("portable repo not allowlisted")
        if not _SHA40.fullmatch(commit):
            raise ContractError("portable commit must be exact 40-character SHA")
        if path != PORTABLE_PATH:
            raise ContractError("portable canary path mismatch")
        if not _SHA64.fullmatch(sha256):
            raise ContractError("portable sha256 must be 64 hexadecimal characters")
        if timeout_seconds < 5 or timeout_seconds > 300:
            raise ContractError("portable timeout out of range")
        return cls(repo, commit, path, sha256.lower(), timeout_seconds)

    def to_dict(self) -> dict[str, Any]:
        return {
            "repo": self.repo,
            "commit": self.commit,
            "path": self.path,
            "sha256": self.sha256,
            "timeout_seconds": self.timeout_seconds,
        }


@dataclass(frozen=True)
class JobCreate:
    project: str
    action: str
    payload: PortablePayload
    required_capabilities: tuple[str, ...]
    preferred_worker: str
    max_attempts: int

    KEYS = frozenset(
        {
            "project",
            "action",
            "payload",
            "required_capabilities",
            "preferred_worker",
            "max_attempts",
        }
    )

    @classmethod
    def from_portable_canary_mapping(cls, raw: Mapping[str, Any]) -> "JobCreate":
        data = _mapping(raw, "job create")
        _exact_keys(data, cls.KEYS, "job create")
        project = _string(data["project"], "project")
        action = _string(data["action"], "action")
        preferred_worker = _string(data["preferred_worker"], "preferred_worker")
        max_attempts = _int(data["max_attempts"], "max_attempts")
        caps_raw = data["required_capabilities"]
        if not isinstance(caps_raw, (list, tuple)) or not caps_raw:
            raise ContractError("required_capabilities must be a non-empty array")
        caps = tuple(_string(item, "required capability") for item in caps_raw)
        if len(caps) != len(set(caps)):
            raise ContractError("required_capabilities must not contain duplicates")
        if project != PORTABLE_PROJECT:
            raise ContractError("portable canary project mismatch")
        if action != PORTABLE_ACTION:
            raise ContractError("portable action mismatch")
        if preferred_worker != PORTABLE_WORKER:
            raise ContractError("portable canary worker mismatch")
        if frozenset(caps) != PORTABLE_CAPABILITIES:
            raise ContractError("portable canary capabilities mismatch")
        if max_attempts != 1:
            raise ContractError("portable canary max_attempts must be 1")
        return cls(
            project=project,
            action=action,
            payload=PortablePayload.from_mapping(_mapping(data["payload"], "payload")),
            required_capabilities=caps,
            preferred_worker=preferred_worker,
            max_attempts=max_attempts,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "project": self.project,
            "action": self.action,
            "payload": self.payload.to_dict(),
            "required_capabilities": list(self.required_capabilities),
            "preferred_worker": self.preferred_worker,
            "max_attempts": self.max_attempts,
        }


@dataclass(frozen=True)
class WorkerExecutionResult:
    worker: str
    action: str
    repo: str
    commit: str
    path: str
    sha256: str
    timeout_seconds: int
    exit_code: int
    stdout: str
    stderr: str
    computer: str
    direct_transport: bool

    KEYS = frozenset(
        {
            "worker",
            "action",
            "repo",
            "commit",
            "path",
            "sha256",
            "timeout_seconds",
            "exit_code",
            "stdout",
            "stderr",
            "computer",
            "direct_transport",
        }
    )

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "WorkerExecutionResult":
        data = _mapping(raw, "worker execution result")
        _exact_keys(data, cls.KEYS, "worker execution result")
        payload = PortablePayload.from_mapping(
            {
                "repo": data["repo"],
                "commit": data["commit"],
                "path": data["path"],
                "sha256": data["sha256"],
                "timeout_seconds": data["timeout_seconds"],
            }
        )
        worker = _string(data["worker"], "worker")
        action = _string(data["action"], "action")
        if worker != PORTABLE_WORKER:
            raise ContractError("worker result worker mismatch")
        if action != PORTABLE_ACTION:
            raise ContractError("worker result action mismatch")
        direct_transport = data["direct_transport"]
        if direct_transport is not True:
            raise ContractError("worker result direct_transport must be true")
        return cls(
            worker=worker,
            action=action,
            repo=payload.repo,
            commit=payload.commit,
            path=payload.path,
            sha256=payload.sha256,
            timeout_seconds=payload.timeout_seconds,
            exit_code=_int(data["exit_code"], "exit_code"),
            stdout=_string(data["stdout"], "stdout", allow_empty=True),
            stderr=_string(data["stderr"], "stderr", allow_empty=True),
            computer=_string(data["computer"], "computer"),
            direct_transport=True,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "worker": self.worker,
            "action": self.action,
            "repo": self.repo,
            "commit": self.commit,
            "path": self.path,
            "sha256": self.sha256,
            "timeout_seconds": self.timeout_seconds,
            "exit_code": self.exit_code,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "computer": self.computer,
            "direct_transport": self.direct_transport,
        }


@dataclass(frozen=True)
class CompletionEnvelope:
    job_id: str
    ok: bool
    result: WorkerExecutionResult
    error: str | None

    KEYS = frozenset({"job_id", "ok", "result", "error"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "CompletionEnvelope":
        data = _mapping(raw, "completion envelope")
        _exact_keys(data, cls.KEYS, "completion envelope")
        ok = data["ok"]
        if not isinstance(ok, bool):
            raise ContractError("completion ok must be boolean")
        error_raw = data["error"]
        if error_raw is not None and not isinstance(error_raw, str):
            raise ContractError("completion error must be string or null")
        return cls(
            job_id=_string(data["job_id"], "job_id"),
            ok=ok,
            result=WorkerExecutionResult.from_mapping(_mapping(data["result"], "result")),
            error=error_raw,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "ok": self.ok,
            "result": self.result.to_dict(),
            "error": self.error,
        }


@dataclass(frozen=True)
class ControlHubHealth:
    ok: bool
    service: str
    version: str
    mode: str

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "ControlHubHealth":
        data = _mapping(raw, "control hub health")
        ok = data.get("ok")
        if not isinstance(ok, bool):
            raise ContractError("health ok must be boolean")
        return cls(
            ok=ok,
            service=_string(data.get("service"), "health service"),
            version=_string(data.get("version"), "health version"),
            mode=_string(data.get("mode"), "health mode"),
        )
