#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

function Emit([object]$Object, [int]$ExitCode = 0) {
    $Object | ConvertTo-Json -Depth 12 -Compress
    exit $ExitCode
}

if ($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN') {
    Emit ([ordered]@{ok=$false;classification='HERMES_SESSION_REGISTRY_WRONG_HOST';host=$env:COMPUTERNAME;mutation='NONE'}) 30
}

$hermesRoot = Join-Path $env:LOCALAPPDATA 'hermes'
$python = Join-Path $hermesRoot 'hermes-agent\venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Emit ([ordered]@{ok=$false;classification='HERMES_SESSION_REGISTRY_PYTHON_MISSING';host=$env:COMPUTERNAME;mutation='NONE';python=$python}) 41
}

$tempPy = Join-Path $env:TEMP ('afz-hermes-session-registry-' + [guid]::NewGuid().ToString('N') + '.py')
$py = @'
from __future__ import annotations

import json
import shutil
import sys
import time
from pathlib import Path

from hermes_constants import get_hermes_home
from hermes_cli.active_sessions import ActiveSessionRegistryError, _FileLock, _read_entries, _write_entries


def emit(obj, code=0):
    print(json.dumps(obj, separators=(",", ":"), sort_keys=True))
    raise SystemExit(code)

home = Path(get_hermes_home())
state = home / "runtime" / "active_sessions.json"
lock = home / "runtime" / "active_sessions.lock"
base = {
    "host": "DESKTOP-H3R6CQN",
    "hermesHome": str(home),
    "statePath": str(state),
    "lockPath": str(lock),
    "providerTouched": False,
    "modelGenerationStarted": False,
    "ollamaMutationStarted": False,
    "gatewayProcessStopped": False,
}

if not state.exists():
    emit({**base, "ok": True, "classification": "HERMES_SESSION_REGISTRY_MISSING_SAFE", "mutation": "NONE", "strictValidation": "missing-is-empty"})

try:
    raw = state.read_text(encoding="utf-8-sig")
except Exception as exc:
    emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_READ_FAILED", "mutation": "NONE", "errorType": type(exc).__name__}, 42)

try:
    parsed = json.loads(raw)
    parse_ok = True
except Exception as exc:
    parsed = None
    parse_ok = False
    parse_error = type(exc).__name__

shape = "unknown"
if isinstance(parsed, dict):
    if "entries" in parsed:
        shape = "entries-object"
    elif "sessions" in parsed:
        shape = "sessions-object"
elif isinstance(parsed, list):
    shape = "list"

legacy_empty = (
    isinstance(parsed, dict)
    and set(parsed.keys()) == {"sessions"}
    and isinstance(parsed.get("sessions"), list)
    and len(parsed["sessions"]) == 0
)

try:
    with _FileLock(lock):
        # Re-read after acquiring the same lock Hermes uses so the decision is based
        # on serialized state, not the pre-lock snapshot above.
        raw_locked = state.read_text(encoding="utf-8-sig")
        try:
            parsed_locked = json.loads(raw_locked)
        except Exception as exc:
            emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_INVALID_JSON", "mutation": "NONE", "sizeBytes": len(raw_locked.encode("utf-8")), "errorType": type(exc).__name__}, 43)

        try:
            entries = _read_entries(state, strict=True)
            emit({**base, "ok": True, "classification": "HERMES_SESSION_REGISTRY_ALREADY_VALID", "mutation": "NONE", "entryCount": len(entries), "shape": "entries-compatible", "sizeBytes": len(raw_locked.encode("utf-8")), "strictValidation": "PASS"})
        except ActiveSessionRegistryError:
            pass

        legacy_empty_locked = (
            isinstance(parsed_locked, dict)
            and set(parsed_locked.keys()) == {"sessions"}
            and isinstance(parsed_locked.get("sessions"), list)
            and len(parsed_locked["sessions"]) == 0
        )
        if not legacy_empty_locked:
            emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_INVALID_NOT_SAFE_TO_AUTO_REPAIR", "mutation": "NONE", "shape": ("sessions-object" if isinstance(parsed_locked, dict) and "sessions" in parsed_locked else "other-invalid"), "sizeBytes": len(raw_locked.encode("utf-8")), "strictValidation": "FAIL"}, 44)

        stamp = time.strftime("%Y%m%dT%H%M%S")
        backup = state.with_name(f"active_sessions.json.afz-pre-schema-repair-{stamp}.bak")
        shutil.copy2(state, backup)
        _write_entries(state, [])
        verified = _read_entries(state, strict=True)
        if verified != []:
            emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_REPAIR_VERIFY_FAILED", "mutation": "LEGACY_EMPTY_SCHEMA_CONVERTED", "backupPath": str(backup)}, 45)
        emit({**base, "ok": True, "classification": "HERMES_SESSION_REGISTRY_LEGACY_EMPTY_SCHEMA_REPAIRED", "mutation": "LEGACY_EMPTY_SESSIONS_TO_ENTRIES", "backupPath": str(backup), "entryCount": 0, "strictValidation": "PASS", "newShape": "entries-object"})
except RuntimeError as exc:
    emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_LOCK_UNAVAILABLE", "mutation": "NONE", "errorType": type(exc).__name__}, 46)
except SystemExit:
    raise
except Exception as exc:
    emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_REPAIR_EXCEPTION", "mutation": "NONE", "errorType": type(exc).__name__}, 47)
'@

[IO.File]::WriteAllText($tempPy, $py, (New-Object Text.UTF8Encoding($false)))
try {
    $output = (& $python $tempPy 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $tempPy -Force -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($output)) {
    Emit ([ordered]@{ok=$false;classification='HERMES_SESSION_REGISTRY_NO_OUTPUT';host=$env:COMPUTERNAME;mutation='NONE';exitCode=$code}) 48
}

# The Python helper emits one compact JSON object. Preserve it verbatim for the
# GitHub Actions log while using its exit code as the workflow success/failure gate.
Write-Output $output
exit $code
