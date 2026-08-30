"""Unbound Control Hub worker transport boundary for staged H3 R3.

The heartbeat, claim, and canonical completion payload contracts are now known
from an archived Control Hub source capture. R3 still performs no network I/O:
there is no URL, token lookup, HTTP library, service install, or worker loop.
Lease renewal remains unsupported because no renewal route was present in the
captured Hub source.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from .contracts import (
    ClaimRequest,
    ClaimResponse,
    CompletionAck,
    ControlHubCompletionRequest,
    ControlHubHealth,
    HeartbeatAck,
    HeartbeatRequest,
)


class LiveTransportUnavailable(RuntimeError):
    """Raised when staged code is asked to perform live Control Hub I/O."""


class LeaseRenewalContractUnavailable(RuntimeError):
    """Raised when code attempts to use a lease-renew route not in the captured contract."""


@runtime_checkable
class KnownControlHubTransport(Protocol):
    """Worker-side operations evidenced by the captured Control Hub source."""

    def health(self) -> ControlHubHealth: ...

    def heartbeat(self, worker_id: str, heartbeat: HeartbeatRequest) -> HeartbeatAck: ...

    def claim(self, worker_id: str, request: ClaimRequest) -> ClaimResponse: ...

    def complete(
        self,
        job_id: str,
        completion: ControlHubCompletionRequest,
    ) -> CompletionAck: ...


class UnboundControlHubTransport:
    """Fail-closed placeholder proving R3 has contract knowledge but no live I/O."""

    network_enabled = False
    claim_schema_known = True
    lease_renewal_schema_known = False
    routing_authority = False
    scheduling_authority = False

    def health(self) -> ControlHubHealth:
        raise LiveTransportUnavailable("live Control Hub transport is not implemented in R3")

    def heartbeat(self, worker_id: str, heartbeat: HeartbeatRequest) -> HeartbeatAck:
        if not isinstance(worker_id, str) or not worker_id:
            raise TypeError("worker_id must be a non-empty string")
        if not isinstance(heartbeat, HeartbeatRequest):
            raise TypeError("heartbeat must be HeartbeatRequest")
        raise LiveTransportUnavailable("live heartbeat transport is not implemented in R3")

    def claim(self, worker_id: str, request: ClaimRequest) -> ClaimResponse:
        if not isinstance(worker_id, str) or not worker_id:
            raise TypeError("worker_id must be a non-empty string")
        if not isinstance(request, ClaimRequest):
            raise TypeError("request must be ClaimRequest")
        raise LiveTransportUnavailable("live claim transport is not implemented in R3")

    def complete(
        self,
        job_id: str,
        completion: ControlHubCompletionRequest,
    ) -> CompletionAck:
        if not isinstance(job_id, str) or not job_id:
            raise TypeError("job_id must be a non-empty string")
        if not isinstance(completion, ControlHubCompletionRequest):
            raise TypeError("completion must be ControlHubCompletionRequest")
        raise LiveTransportUnavailable("live completion transport is not implemented in R3")

    def renew_lease(self, *args: object, **kwargs: object) -> None:
        del args, kwargs
        raise LeaseRenewalContractUnavailable(
            "no Control Hub lease-renew endpoint was present in the captured source"
        )
