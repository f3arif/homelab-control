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

@dataclass(frozen=True)
class LeaseRequest:
    owner_host: str
    expected_main: str
    request_nonce: str
    ttl_seconds: int = TTL_DEFAULT
    resource_safe: bool = False
    split_brain_fence_clear: bool = False

    def validate(self) -> None:
        if self.owner_host not in ALLOWED_OWNERS:
            raise LeaseError("owner host not allowlisted")
        if not _SHA40.fullmatch(self.expected_main):
            raise LeaseError("expected_main must be lowercase exact SHA40")
        if not _NONCE.fullmatch(self.request_nonce):
            raise LeaseError("request nonce invalid")
        if isinstance(self.ttl_seconds, bool) or not TTL_MIN <= self.ttl_seconds <= TTL_MAX:
            raise LeaseError("ttl outside bounded range")
        if not self.resource_safe:
            raise LeaseError("resource admission failed")
        if not self.split_brain_fence_clear:
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
        if self.resource != RESOURCE:
            raise LeaseError("lease resource mismatch")
        if self.owner_host not in ALLOWED_OWNERS:
            raise LeaseError("persisted owner host not allowlisted")
        if not _SHA40.fullmatch(self.expected_main):
            raise LeaseError("persisted expected_main invalid")
        if not _NONCE.fullmatch(self.request_nonce):
            raise LeaseError("persisted request nonce invalid")
        try:
            parsed = uuid.UUID(self.lease_id)
        except (ValueError, AttributeError, TypeError) as exc:
            raise LeaseError("lease id invalid") from exc
        if str(parsed) != self.lease_id:
            raise LeaseError("lease id must be canonical UUID")
        if self.acquired_at.tzinfo is None or self.expires_at.tzinfo is None:
            raise LeaseError("persisted lease timestamps must be timezone-aware")
        ttl = (self.expires_at - self.acquired_at).total_seconds()
        if ttl < TTL_MIN or ttl > TTL_MAX:
            raise LeaseError("persisted lease ttl outside bounded range")

    def active_at(self, now: datetime) -> bool:
        self.validate()
        if now.tzinfo is None:
            raise LeaseError("now must be timezone-aware")
        return now < self.expires_at

@dataclass(frozen=True)
class AcquireResult:
    acquired: bool
    lease: LeaseRecord | None
    reason: str
    idempotent: bool = False

def utc_now() -> datetime:
    return datetime.now(timezone.utc)

def acquire(current: LeaseRecord | None, request: LeaseRequest, now: datetime) -> AcquireResult:
    request.validate()
    if now.tzinfo is None:
        raise LeaseError("now must be timezone-aware")
    if current:
        current.validate()
    if current and current.active_at(now):
        if (current.owner_host == request.owner_host
                and current.expected_main == request.expected_main
                and current.request_nonce == request.request_nonce):
            return AcquireResult(True, current, "same request already owns active lease", True)
        return AcquireResult(False, current, "active lease held")

    lease = LeaseRecord(
        lease_id=str(uuid.uuid4()),
        resource=RESOURCE,
        owner_host=request.owner_host,
        expected_main=request.expected_main,
        request_nonce=request.request_nonce,
        acquired_at=now,
        expires_at=now + timedelta(seconds=request.ttl_seconds),
    )
    return AcquireResult(True, lease, "acquired")

def release(current: LeaseRecord | None, *, lease_id: str, owner_host: str, now: datetime) -> LeaseRecord | None:
    if current is None:
        return None
    if not current.active_at(now):
        return None
    if current.lease_id != lease_id:
        raise LeaseError("lease id mismatch")
    if current.owner_host != owner_host:
        raise LeaseError("lease owner mismatch")
    return None

def validate_for_deploy(
    current: LeaseRecord | None,
    *,
    owner_host: str,
    expected_main: str,
    now: datetime,
    resource_safe: bool,
    split_brain_fence_clear: bool,
) -> bool:
    if now.tzinfo is None:
        return False
    if owner_host not in ALLOWED_OWNERS or not _SHA40.fullmatch(expected_main):
        return False
    if not resource_safe or not split_brain_fence_clear:
        return False
    if current is None:
        return False
    try:
        if not current.active_at(now):
            return False
    except LeaseError:
        return False
    return (current.resource == RESOURCE
            and current.owner_host == owner_host
            and current.expected_main == expected_main)

def renew(*args, **kwargs):
    raise LeaseError("lease renewal endpoint intentionally unavailable in v1")