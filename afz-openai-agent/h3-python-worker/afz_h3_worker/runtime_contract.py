"""Evidence-bounded H3 runtime observations for Python migration R4.

This module records only facts captured from the live H3 worker by read-only
audits. Missing values stay unresolved rather than inheriting historical
settings from older worker hashes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


R4_CAPTURED_AT = "2026-08-30T13:39:36.6037991-04:00"
R4_HOST = "DESKTOP-H3R6CQN"


@dataclass(frozen=True)
class RuntimeFileIdentity:
    path: str
    sha256: str
    size_bytes: int
    line_count: int

    def __post_init__(self) -> None:
        if not self.path:
            raise ValueError("path required")
        if len(self.sha256) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in self.sha256):
            raise ValueError("sha256 must be 64 hexadecimal characters")
        if self.size_bytes < 1 or self.line_count < 1:
            raise ValueError("file size and line count must be positive")


GENERIC_WORKER = RuntimeFileIdentity(
    path=r"C:\AFZ\H3Worker\AFZ-H3-Worker.ps1",
    sha256="B61D8EB4E625549836C504D102BC0139D1C97786447E2EA071AC9DBC8F02795E",
    size_bytes=17633,
    line_count=306,
)

OLLAMA_TELEMETRY = RuntimeFileIdentity(
    path=r"C:\AFZ\H3Worker\AFZ-H3-OllamaTelemetry.ps1",
    sha256="BFEFD838E7E3AD3E9723FB47FADDC844AB534B382076C65082F739D5C9C4B30A",
    size_bytes=7001,
    line_count=64,
)

DIRECT_WORKER = RuntimeFileIdentity(
    path=r"C:\ProgramData\AFZ\H3Direct\AFZ-H3-Direct-Worker.ps1",
    sha256="BA417A98FB84972317ED0668FDCFFEF144B0944071841A73A18EB2BDC3109F61",
    size_bytes=4800,
    line_count=95,
)

GENERIC_QUEUE_RELATIVE = r"Queue\h3"
GENERIC_PROCESSING_RELATIVE = r"Processing\h3"
GENERIC_RESULTS_RELATIVE = r"Results\h3"
GENERIC_ARCHIVE_RELATIVE = r"Archive\h3"
GENERIC_HEARTBEAT_JSON = "h3.json"
GENERIC_HEARTBEAT_TEXT = "h3.txt"

CURRENTLY_OBSERVED_HEARTBEAT_FIELDS = frozenset(
    {
        "state",
        "detail",
        "queueCount",
        "ramPercent",
        "radioHilal35BState",
        "computeState",
        "ollamaReachable",
        "ollamaVersion",
        "ollamaState",
        "ollamaModelCount",
        "ollamaPrimaryModel",
        "ollamaVramBytes",
        "ollamaContextLength",
        "ollamaActiveTask",
        "gpuPercent",
        "vramPercent",
        "ollamaTelemetryAgeSeconds",
    }
)

CURRENTLY_OBSERVED_RESULT_FIELDS = frozenset(
    {
        "id",
        "project",
        "action",
        "ok",
        "worker",
        "computer",
        "version",
        "error",
        "result",
        "forcedSleep",
        "ollamaExposureChanged",
    }
)

GENERIC_QUEUE_ORDER = ("LastWriteTimeUtc", "Name")
GENERIC_READ_RETRY_COUNT = 10
GENERIC_READ_RETRY_SLEEP_SECONDS = 2
DIRECT_WORKER_POLL_SECONDS = 2
OLLAMA_TELEMETRY_POLL_SECONDS = 15
DIRECT_WORKER_EXECUTION_SCOPE = "h3-health-only"
DIRECT_WORKER_ROUTING_AUTHORITY = False
DIRECT_WORKER_PROJECT_EXECUTION = False
DIRECT_WORKER_RADIOHILAL35B_AUTHORITY = False

# R4 V1 did not capture these current values before its output budget was
# exhausted. Historical values must not silently promote into current facts.
CURRENT_GENERIC_WORKER_VERSION: str | None = None
CURRENT_GENERIC_POLL_SECONDS: int | None = None
CURRENT_HEAVY_RAM_CEILING_PERCENT: float | None = None
CURRENT_ALLOWED_ACTIONS: tuple[str, ...] | None = None
CURRENT_HEAVY_ACTIONS: tuple[str, ...] | None = None
CURRENT_MUTEX_NAME: str | None = None
CURRENT_TASK_CONTRACT: Mapping[str, object] | None = None


def current_contract_complete() -> bool:
    return all(
        value is not None
        for value in (
            CURRENT_GENERIC_WORKER_VERSION,
            CURRENT_GENERIC_POLL_SECONDS,
            CURRENT_HEAVY_RAM_CEILING_PERCENT,
            CURRENT_ALLOWED_ACTIONS,
            CURRENT_HEAVY_ACTIONS,
            CURRENT_MUTEX_NAME,
            CURRENT_TASK_CONTRACT,
        )
    )
