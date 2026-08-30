"""AFZ H3 shadow-worker primitives.

This package is intentionally non-authoritative. It does not claim jobs,
schedule work, install services, or own worker liveness.
"""

from .contracts import (
    CLAIM_SCHEMA_KNOWN,
    CompletionEnvelope,
    ContractError,
    ControlHubHealth,
    JobCreate,
    PortablePayload,
    WorkerExecutionResult,
)
from .parity import ParityReport, compare_process_results, sha256_file
from .process import ProcessResult, run_process
from .transport import (
    ClaimContractUnavailable,
    LiveTransportUnavailable,
    UnboundControlHubTransport,
)

__all__ = [
    "CLAIM_SCHEMA_KNOWN",
    "CompletionEnvelope",
    "ContractError",
    "ControlHubHealth",
    "JobCreate",
    "PortablePayload",
    "WorkerExecutionResult",
    "ClaimContractUnavailable",
    "LiveTransportUnavailable",
    "UnboundControlHubTransport",
    "ProcessResult",
    "run_process",
    "ParityReport",
    "compare_process_results",
    "sha256_file",
]
