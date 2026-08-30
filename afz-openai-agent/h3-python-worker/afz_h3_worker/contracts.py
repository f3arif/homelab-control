"""Typed, evidence-bounded Control Hub contracts for the staged H3 worker.

R3 incorporates the archived AFZ Control Hub source capture from 2026-08-25.
Claim, heartbeat, and canonical completion schemas are now known. No lease-renew
endpoint was present in the captured Hub source, so renewal remains explicitly
unknown and must not be invented by the staged worker.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
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
CONTROL_HUB_WORKER_HEARTBEAT_PATH = "/api/workers/{worker_id}/heartbeat"
CONTROL_HUB_WORKER_CLAIM_PATH = "/api/workers/{worker_id}/claim"
CONTROL_HUB_JOB_COMPLETE_PATH = "/api/jobs/{job_id}/complete"
DIRECT_GATEWAY_CLAIM_PATH = "/claim"
DIRECT_GATEWAY_COMPLETE_PATH = "/complete"

CLAIM_SCHEMA_KNOWN = True
LEASE_RENEWAL_SCHEMA_KNOWN = False
LEASE_SECONDS_DEFAULT = 60
LEASE_SECONDS_MIN = 15
LEASE_SECONDS_MAX = 7200

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


def _optional_string(value: Any, label: str) -> str | None:
    if value is None:
        return None
    return _string(value, label)


def _int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError(f"{label} must be an integer")
    return value


def _bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ContractError(f"{label} must be boolean")
    return value


def _string_tuple(value: Any, label: str, *, allow_empty: bool = True) -> tuple[str, ...]:
    if not isinstance(value, (list, tuple)):
        raise ContractError(f"{label} must be an array")
    values = tuple(_string(item, f"{label} item") for item in value)
    if not allow_empty and not values:
        raise ContractError(f"{label} must not be empty")
    if len(values) != len(set(values)):
        raise ContractError(f"{label} must not contain duplicates")
    return values


def _dict_copy(value: Any, label: str) -> dict[str, Any]:
    data = _mapping(value, label)
    return {str(key): item for key, item in data.items()}


def _iso_timestamp(value: Any, label: str) -> str:
    text = _string(value, label)
    candidate = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise ContractError(f"{label} must be ISO-8601") from exc
    return text


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
    """Strict portable-canary job shape proven by the typed canary patch."""

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
        caps = _string_tuple(data["required_capabilities"], "required_capabilities", allow_empty=False)
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
    """Portable direct-executor result proven by the Lenovo canary."""

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
        if data["direct_transport"] is not True:
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
    """Legacy direct-gateway completion envelope observed in the canary worker."""

    job_id: str
    ok: bool
    result: WorkerExecutionResult
    error: str | None

    KEYS = frozenset({"job_id", "ok", "result", "error"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "CompletionEnvelope":
        data = _mapping(raw, "completion envelope")
        _exact_keys(data, cls.KEYS, "completion envelope")
        error_raw = data["error"]
        if error_raw is not None and not isinstance(error_raw, str):
            raise ContractError("completion error must be string or null")
        return cls(
            job_id=_string(data["job_id"], "job_id"),
            ok=_bool(data["ok"], "completion ok"),
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
        return cls(
            ok=_bool(data.get("ok"), "health ok"),
            service=_string(data.get("service"), "health service"),
            version=_string(data.get("version"), "health version"),
            mode=_string(data.get("mode"), "health mode"),
        )


@dataclass(frozen=True)
class HeartbeatRequest:
    state: str = "READY"
    capabilities: tuple[str, ...] = ()
    metadata: dict[str, Any] | None = None
    current_job_id: str | None = None

    KEYS = frozenset({"state", "capabilities", "metadata", "current_job_id"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "HeartbeatRequest":
        data = _mapping(raw, "heartbeat")
        _exact_keys(data, cls.KEYS, "heartbeat")
        return cls(
            state=_string(data["state"], "heartbeat state"),
            capabilities=_string_tuple(data["capabilities"], "heartbeat capabilities"),
            metadata=_dict_copy(data["metadata"], "heartbeat metadata"),
            current_job_id=_optional_string(data["current_job_id"], "current_job_id"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "capabilities": list(self.capabilities),
            "metadata": dict(self.metadata or {}),
            "current_job_id": self.current_job_id,
        }


@dataclass(frozen=True)
class HeartbeatAck:
    ok: bool
    worker_id: str

    KEYS = frozenset({"ok", "worker_id"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "HeartbeatAck":
        data = _mapping(raw, "heartbeat ack")
        _exact_keys(data, cls.KEYS, "heartbeat ack")
        return cls(ok=_bool(data["ok"], "heartbeat ack ok"), worker_id=_string(data["worker_id"], "worker_id"))


@dataclass(frozen=True)
class ClaimRequest:
    lease_seconds: int = LEASE_SECONDS_DEFAULT
    strict_preferred: bool = False

    @classmethod
    def create(
        cls,
        lease_seconds: int = LEASE_SECONDS_DEFAULT,
        strict_preferred: bool = False,
    ) -> "ClaimRequest":
        return cls(
            lease_seconds=_int(lease_seconds, "lease_seconds"),
            strict_preferred=_bool(strict_preferred, "strict_preferred"),
        )

    @property
    def effective_lease_seconds(self) -> int:
        return max(LEASE_SECONDS_MIN, min(LEASE_SECONDS_MAX, self.lease_seconds))

    def to_query(self) -> dict[str, Any]:
        return {
            "lease_seconds": self.lease_seconds,
            "strict_preferred": self.strict_preferred,
        }


@dataclass(frozen=True)
class ClaimedJob:
    job_id: str
    project: str
    action: str
    payload: dict[str, Any]
    required_capabilities: tuple[str, ...]
    attempt: int
    lease_until: str

    KEYS = frozenset(
        {"job_id", "project", "action", "payload", "required_capabilities", "attempt", "lease_until"}
    )

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "ClaimedJob":
        data = _mapping(raw, "claimed job")
        _exact_keys(data, cls.KEYS, "claimed job")
        attempt = _int(data["attempt"], "attempt")
        if attempt < 1:
            raise ContractError("attempt must be at least 1 after claim")
        return cls(
            job_id=_string(data["job_id"], "job_id"),
            project=_string(data["project"], "project"),
            action=_string(data["action"], "action"),
            payload=_dict_copy(data["payload"], "payload"),
            required_capabilities=_string_tuple(data["required_capabilities"], "required_capabilities"),
            attempt=attempt,
            lease_until=_iso_timestamp(data["lease_until"], "lease_until"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "project": self.project,
            "action": self.action,
            "payload": dict(self.payload),
            "required_capabilities": list(self.required_capabilities),
            "attempt": self.attempt,
            "lease_until": self.lease_until,
        }


@dataclass(frozen=True)
class ClaimResponse:
    ok: bool
    job: ClaimedJob | None
    mode: str | None = None

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "ClaimResponse":
        data = _mapping(raw, "claim response")
        allowed = frozenset({"ok", "job", "mode"})
        actual = frozenset(str(key) for key in data.keys())
        if not frozenset({"ok", "job"}).issubset(actual) or not actual.issubset(allowed):
            raise ContractError("claim response keys mismatch")
        ok = _bool(data["ok"], "claim ok")
        job_raw = data["job"]
        job = None if job_raw is None else ClaimedJob.from_mapping(_mapping(job_raw, "job"))
        mode = _optional_string(data.get("mode"), "claim mode")
        if mode is not None and job is not None:
            raise ContractError("shadow-mode claim response must not contain a job")
        return cls(ok=ok, job=job, mode=mode)

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {"ok": self.ok, "job": self.job.to_dict() if self.job else None}
        if self.mode is not None:
            result["mode"] = self.mode
        return result


@dataclass(frozen=True)
class ControlHubCompletionRequest:
    """Canonical body for POST /api/jobs/{job_id}/complete."""

    worker_id: str
    ok: bool
    result: dict[str, Any]
    error: str | None

    KEYS = frozenset({"worker_id", "ok", "result", "error"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "ControlHubCompletionRequest":
        data = _mapping(raw, "control hub completion")
        _exact_keys(data, cls.KEYS, "control hub completion")
        error = data["error"]
        if error is not None and not isinstance(error, str):
            raise ContractError("completion error must be string or null")
        return cls(
            worker_id=_string(data["worker_id"], "worker_id"),
            ok=_bool(data["ok"], "completion ok"),
            result=_dict_copy(data["result"], "completion result"),
            error=error,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "worker_id": self.worker_id,
            "ok": self.ok,
            "result": dict(self.result),
            "error": self.error,
        }


@dataclass(frozen=True)
class CompletionAck:
    ok: bool
    status: str

    KEYS = frozenset({"ok", "status"})
    STATUSES = frozenset({"COMPLETED", "FAILED"})

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "CompletionAck":
        data = _mapping(raw, "completion ack")
        _exact_keys(data, cls.KEYS, "completion ack")
        status = _string(data["status"], "completion status")
        if status not in cls.STATUSES:
            raise ContractError("completion status must be COMPLETED or FAILED")
        return cls(ok=_bool(data["ok"], "completion ack ok"), status=status)
