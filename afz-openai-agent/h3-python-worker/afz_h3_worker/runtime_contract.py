"""Evidence-bounded H3 runtime observations for Python migration R4.

Only facts captured from the live H3 host are recorded here. Where a launcher
definition was verified earlier than the runtime snapshot, the verification
instant and PID-continuity evidence are preserved explicitly instead of being
represented as a fresh task read.
"""

from __future__ import annotations

from dataclasses import dataclass


R4_CAPTURED_AT = "2026-08-30T13:51:45.4011987-04:00"
R4_HOST = "DESKTOP-H3R6CQN"
TASK_LAUNCHER_VERIFIED_AT = "2026-08-30T01:32:15.7797175-04:00"


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


@dataclass(frozen=True)
class TaskLauncherEvidence:
    task_name: str
    user: str
    logon_type: str
    run_level: str
    execute: str
    arguments: str
    pid_after_definition_change: int
    pid_at_r4_snapshot: int

    @property
    def live_pid_continuity(self) -> bool:
        return self.pid_after_definition_change == self.pid_at_r4_snapshot


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
        "timestamp",
        "computer",
        "pid",
        "version",
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
        "allowedActions",
        "forcedSleep",
        "ollamaExposureChanged",
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

CURRENT_GENERIC_WORKER_VERSION = "1.0.0"
CURRENT_GENERIC_POLL_SECONDS = 12
CURRENT_HEAVY_RAM_CEILING_PERCENT = 88.0
CURRENT_MAX_OUTPUT_CHARS = 120000
CURRENT_MUTEX_NAME = r"Local\AFZH3GenericWorker"
CURRENT_HEAVY_ACTIONS = (
    "h3-dotnet-build",
    "h3-npm-build",
    "h3-npm-test",
    "h3-tsc",
)
CURRENT_ALLOWED_ACTIONS = (
    "h3-status",
    "h3-powershell-parse",
    "h3-json-validate",
    "h3-python-compile",
    "h3-file-hash",
    "h3-dotnet-build",
    "h3-npm-build",
    "h3-npm-test",
    "h3-tsc",
)
CURRENT_ALLOWED_WORK_ROOT_EXPRESSIONS = (
    r"C:\Projects",
    r"C:\OpenWebUI",
    "$Staging",
)
CURRENT_READONLY_ROOT_EXPRESSIONS = (
    r"C:\Projects",
    r"C:\OpenWebUI",
    r"C:\AFZ",
    "$Staging",
)

GENERIC_RUNKEY_NAME = "AFZ H3 Generic Worker"
GENERIC_RUNKEY_COMMAND = (
    r'"C:\windows\System32\wscript.exe" //B //Nologo '
    r'"C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Run-Hidden.vbs"'
)
TELEMETRY_RUNKEY_NAME = "AFZ H3 Ollama Telemetry"
TELEMETRY_RUNKEY_COMMAND = (
    r'"C:\windows\System32\wscript.exe" //B //Nologo '
    r'"C:\AFZ\H3Worker\Run-AFZ-H3-OllamaTelemetry-Run-Hidden.vbs"'
)

DIRECT_TASK_LAUNCHER = TaskLauncherEvidence(
    task_name="AFZ H3 Direct Worker",
    user="Faiz",
    logon_type="Interactive",
    run_level="Limited",
    execute=r"C:\windows\System32\wscript.exe",
    arguments=r'//B //Nologo "C:\ProgramData\AFZ\H3Direct\Run-AFZ-H3-Direct-Worker-Task-Hidden.vbs"',
    pid_after_definition_change=13612,
    pid_at_r4_snapshot=13612,
)

GENERIC_TASK_LAUNCHER = TaskLauncherEvidence(
    task_name="AFZ H3 Generic Worker",
    user="Faiz",
    logon_type="Interactive",
    run_level="Limited",
    execute=r"C:\windows\System32\wscript.exe",
    arguments=r'//B //Nologo "C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Task-Hidden.vbs"',
    pid_after_definition_change=12112,
    pid_at_r4_snapshot=12112,
)

CURRENT_GENERIC_PID = 12112
CURRENT_TELEMETRY_PID = 23032
CURRENT_DIRECT_PID = 13612
CURRENT_WORKER_SESSION_ID = 1


def current_contract_complete() -> bool:
    """Whether R4 has enough evidence to proceed to non-authoritative parity.

    This does not claim that Scheduled Task XML was freshly re-read at 13:51.
    It requires the last verified hidden launcher definitions plus continuity of
    the exact live worker PIDs into the current R4 snapshot.
    """

    return DIRECT_TASK_LAUNCHER.live_pid_continuity and GENERIC_TASK_LAUNCHER.live_pid_continuity
