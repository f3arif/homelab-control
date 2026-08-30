"""AFZ H3 shadow-worker primitives.

This package is intentionally non-authoritative. It models proven worker
contracts and local execution/parity primitives, but it does not perform live
Control Hub I/O, schedule work, install services, or own worker liveness.
"""

from .actions import ActionContractError, h3_file_hash, resolve_readonly_file
from .contracts import (
    CLAIM_SCHEMA_KNOWN,
    LEASE_RENEWAL_SCHEMA_KNOWN,
    CompletionAck,
    CompletionEnvelope,
    ContractError,
    ControlHubCompletionRequest,
    ControlHubHealth,
    ClaimRequest,
    ClaimResponse,
    ClaimedJob,
    HeartbeatAck,
    HeartbeatRequest,
    JobCreate,
    PortablePayload,
    WorkerExecutionResult,
)
from .parity import ParityReport, compare_process_results, sha256_file
from .process import ProcessResult, run_process
from .transport import (
    LeaseRenewalContractUnavailable,
    LiveTransportUnavailable,
    UnboundControlHubTransport,
)

__all__ = [
    "ActionContractError",
    "h3_file_hash",
    "resolve_readonly_file",
    "CLAIM_SCHEMA_KNOWN",
    "LEASE_RENEWAL_SCHEMA_KNOWN",
    "CompletionAck",
    "CompletionEnvelope",
    "ContractError",
    "ControlHubCompletionRequest",
    "ControlHubHealth",
    "ClaimRequest",
    "ClaimResponse",
    "ClaimedJob",
    "HeartbeatAck",
    "HeartbeatRequest",
    "JobCreate",
    "PortablePayload",
    "WorkerExecutionResult",
    "LeaseRenewalContractUnavailable",
    "LiveTransportUnavailable",
    "UnboundControlHubTransport",
    "ProcessResult",
    "run_process",
    "ParityReport",
    "compare_process_results",
    "sha256_file",
]
