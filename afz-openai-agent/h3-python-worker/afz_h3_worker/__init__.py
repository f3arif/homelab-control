"""AFZ H3 shadow-worker primitives.

This package is intentionally non-authoritative. It does not claim jobs,
schedule work, install services, or own worker liveness.
"""

from .process import ProcessResult, run_process
from .parity import ParityReport, compare_process_results, sha256_file

__all__ = [
    "ProcessResult",
    "run_process",
    "ParityReport",
    "compare_process_results",
    "sha256_file",
]
