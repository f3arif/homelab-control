"""Pure reference semantics for the Radio Hilal production-writer lease.

NON-AUTHORITATIVE: no network, file, database, service, deploy, or publication I/O.
Production integration must use the AFZ Control Hub/PostgreSQL transaction boundary.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import re
import uuid

RESOURCE = "radiohilal-production-writer"
ALLOWED_OWNERS = frozenset({"DESKTOP-H3R6CQN", "DESKTOP-10SKF0M"})
TTL_MIN = 30
TTL_DEFAULT = 120
TTL_MAX = 300
_SHA40 = re.compile(r"^[0-9a-f]{40}$")
_NONCE = re.compile(r"^[A-Za-z0-9._:-]{8,128}$")


class LeaseError(ValueError):
    pass


def _utc(value: object, label: str) -> datetime:
    if not isinstance(value, datetime):
        raise LeaseError(f"{label} must be datetime")
    if value.tzinfo is None or value.utcoffset() is None:
        raise LeaseError(f"{label} must be timezone-aware")
    try:
        return value.astimezone(timezone.utc)
    except (ValueError, OverflowError) as exc:
        raise LeaseError(f"{label} timezone conversion failed") from exc


def _valid_nonce(value: object) -> bool:
    return isinstance(value, str) and _NONCE.fullmatch(value) is not None


def _valid_sha(value: object) -> bool:
    return isinstance(value, str) and _SHA40.fullmatch(value) is not None


@dataclass(frozen=True)
class LeaseRequest:
    owner_host: str
    expected_main: str
    request_nonce: str
    ttl_seconds: int = TTL_DEFAULT
    resource_safe: bool = False
    split_brain_fence_clear: bool = False

    def validate(self) -> None:
        if not isinstance(self.owner_host, str) or self.owner_host not in ALLOWED_OWNERS:
            raise LeaseError("owner host not allowlisted")
        if not _valid_sha(self.expected_main):
            raise LeaseError("expected_main must be lowercase exact SHA40")
        if not _valid_nonce(self.request_nonce):
            raise LeaseError("request nonce invalid")
        if isinstance(self.ttl_seconds, bool) or not isinstance(self.ttl_seconds, int):
            raise LeaseError("ttl must be integer")
        if not TTL_MIN <= self.ttl_seconds <= TTL_MAX:
            raise LeaseError("ttl outside bounded range")
        if self.resource_safe is not True:
            raise LeaseError("resource admission failed")
        if self.split_brain_fence_clear is not True:
            raise LeaseError("split-brain fence not clear")


@dataclass(frozen=True)
class LeaseRecord:
    lease_id: str
    resource: str
    owner_host: str
    expected_main: str
    request_nonce: str
    acquired_at: datetime
    expires_at: datetime

    def validate(self) -> None:
        if not isinstance(self.resource, str) or self.resource != RESOURCE:
            raise LeaseError("lease resource mismatch")
        if not isinstance(self.owner_host, str) or self.owner_host not in ALLOWED_OWNERS:
            raise LeaseError("persisted owner host not allowlisted")
        if not _valid_sha(self.expected_main):
            raise LeaseError("persisted expected_main invalid")
        if not _valid_nonce(self.request_nonce):
            raise LeaseError("persisted request nonce invalid")
        if not isinstance(self.lease_id, str):
            raise LeaseError("lease id invalid")
        try:
            parsed = uuid.UUID(self.lease_id)
        except (ValueError, AttributeError, TypeError) as exc:
            raise LeaseError("lease id invalid") from exc
        if str(parsed) != self.lease_id:
            raise LeaseError("lease id must be canonical UUID")
        acquired = _utc(self.acquired_at, "acquired_at")
        expires = _utc(self.expires_at, "expires_at")
        ttl = (expires - acquired).total_seconds()
        if ttl < TTL_MIN or ttl > TTL_MAX:
            raise LeaseError("persisted lease ttl outside bounded range")

    def active_at(self, now: datetime) -> bool:
        self.validate()
        acquired = _utc(self.acquired_at, "acquired_at")
        expires = _utc(self.expires_at, "expires_at")
        instant = _utc(now, "now")
        return acquired <= instant < expires


@dataclass(frozen=True)
class LeaseState:
    current: LeaseRecord | None = None
    terminal_nonces: frozenset[str] = frozenset()

    def validate(self) -> None:
        if not isinstance(self.terminal_nonces, frozenset):
            raise LeaseError("terminal nonce ledger must be frozenset")
        for nonce in self.terminal_nonces:
            if not _valid_nonce(nonce):
                raise LeaseError("terminal nonce ledger contains invalid nonce")
        if self.current is not None:
            if not isinstance(self.current, LeaseRecord):
                raise LeaseError("current lease record type invalid")
            self.current.validate()
            if self.current.request_nonce in self.terminal_nonces:
                raise LeaseError("active/current nonce already terminal")

    def archive_current(self) -> "LeaseState":
        if self.current is None:
            return self
        return LeaseState(
            current=None,
            terminal_nonces=self.terminal_nonces | frozenset({self.current.request_nonce}),
        )


@dataclass(frozen=True)
class AcquireResult:
    acquired: bool
    state: LeaseState
    reason: str
    idempotent: bool = False

    @property
    def lease(self) -> LeaseRecord | None:
        return self.state.current


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def acquire(state: LeaseState, request: LeaseRequest, now: datetime) -> AcquireResult:
    if not isinstance(state, LeaseState):
        raise LeaseError("lease state type invalid")
    state.validate()
    request.validate()
    instant = _utc(now, "now")

    if request.request_nonce in state.terminal_nonces:
        return AcquireResult(False, state, "request nonce already terminal")

    current = state.current
    if current is not None:
        acquired = _utc(current.acquired_at, "acquired_at")
        expires = _utc(current.expires_at, "expires_at")
        if instant < acquired:
            return AcquireResult(False, state, "current lease acquisition is in the future")
        if instant < expires:
            if (
                current.owner_host == request.owner_host
                and current.expected_main == request.expected_main
                and current.request_nonce == request.request_nonce
            ):
                return AcquireResult(True, state, "same request already owns active lease", True)
            return AcquireResult(False, state, "active lease held")

        state = state.archive_current()
        if request.request_nonce in state.terminal_nonces:
            return AcquireResult(False, state, "expired request replay rejected")

    lease = LeaseRecord(
        lease_id=str(uuid.uuid4()),
        resource=RESOURCE,
        owner_host=request.owner_host,
        expected_main=request.expected_main,
        request_nonce=request.request_nonce,
        acquired_at=instant,
        expires_at=instant + timedelta(seconds=request.ttl_seconds),
    )
    new_state = LeaseState(current=lease, terminal_nonces=state.terminal_nonces)
    new_state.validate()
    return AcquireResult(True, new_state, "acquired")


def release(
    state: LeaseState,
    *,
    lease_id: str,
    owner_host: str,
    now: datetime,
) -> LeaseState:
    if not isinstance(state, LeaseState):
        raise LeaseError("lease state type invalid")
    state.validate()
    _utc(now, "now")
    current = state.current
    if current is None:
        return state
    if not isinstance(lease_id, str) or current.lease_id != lease_id:
        raise LeaseError("lease id mismatch")
    if not isinstance(owner_host, str) or current.owner_host != owner_host:
        raise LeaseError("lease owner mismatch")
    return state.archive_current()


def validate_for_deploy(
    state: LeaseState,
    *,
    owner_host: str,
    expected_main: str,
    now: datetime,
    resource_safe: bool,
    split_brain_fence_clear: bool,
) -> bool:
    if not isinstance(state, LeaseState):
        return False
    if not isinstance(owner_host, str) or owner_host not in ALLOWED_OWNERS:
        return False
    if not _valid_sha(expected_main):
        return False
    if resource_safe is not True or split_brain_fence_clear is not True:
        return False
    try:
        state.validate()
        current = state.current
        if current is None or not current.active_at(now):
            return False
    except (LeaseError, TypeError, ValueError, AttributeError, OverflowError):
        return False
    return (
        current.resource == RESOURCE
        and current.owner_host == owner_host
        and current.expected_main == expected_main
        and current.request_nonce not in state.terminal_nonces
    )


def renew(*args, **kwargs):
    raise LeaseError("lease renewal endpoint intentionally unavailable in v1")
