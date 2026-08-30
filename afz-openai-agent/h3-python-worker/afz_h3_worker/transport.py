"""Unbound Control Hub transport boundary for the staged H3 Python worker.

R2 defines interfaces and fail-closed placeholders only. It performs no network
I/O and deliberately has no live claim implementation because the H3 claim
request/response contract has not yet been recovered authoritatively.
"""

from __future__ import annotations

from typing import Any, Mapping, Protocol, runtime_checkable

from .contracts import CompletionEnvelope, ControlHubHealth


class ClaimContractUnavailable(RuntimeError):
    """Raised when code attempts to use the not-yet-proven claim contract."""


class LiveTransportUnavailable(RuntimeError):
    """Raised when staged R2 code is asked to perform live Control Hub I/O."""


@runtime_checkable
class KnownControlHubTransport(Protocol):
    """Only operations whose payload contracts are already evidenced.

    A concrete implementation may be added only after the live H3 contract and
    authentication/storage requirements are audited. Claim is intentionally not
    part of this protocol.
    """

    def health(self) -> ControlHubHealth: ...

    def complete(self, envelope: CompletionEnvelope) -> Mapping[str, Any]: ...


class UnboundControlHubTransport:
    """Fail-closed placeholder proving that R2 has no live network authority."""

    network_enabled = False
    claim_schema_known = False
    routing_authority = False
    scheduling_authority = False

    def health(self) -> ControlHubHealth:
        raise LiveTransportUnavailable("live Control Hub transport is not implemented in R2")

    def complete(self, envelope: CompletionEnvelope) -> Mapping[str, Any]:
        if not isinstance(envelope, CompletionEnvelope):
            raise TypeError("envelope must be CompletionEnvelope")
        raise LiveTransportUnavailable("live completion transport is not implemented in R2")

    def claim(self, *args: Any, **kwargs: Any) -> None:
        del args, kwargs
        raise ClaimContractUnavailable(
            "H3 worker claim schema is unknown; recover and verify it before implementation"
        )
