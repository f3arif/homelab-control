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

import hashlib
import json
import shutil
import time
from pathlib import Path

from hermes_constants import get_hermes_home
from hermes_cli.active_sessions import ActiveSessionRegistryError, _FileLock, _read_entries, _write_entries


def emit(obj, code=0):
    print(json.dumps(obj, separators=(",", ":"), sort_keys=True))
    raise SystemExit(code)


def backup_and_write_empty(state: Path, classification: str, mutation: str, base: dict):
    stamp = time.strftime("%Y%m%dT%H%M%S")
    backup = state.with_name(f"active_sessions.json.afz-pre-schema-repair-{stamp}.bak")
    shutil.copy2(state, backup)
    _write_entries(state, [])
    verified = _read_entries(state, strict=True)
    if verified != []:
        emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_REPAIR_VERIFY_FAILED", "mutation": mutation, "backupPath": str(backup)}, 45)
    emit({**base, "ok": True, "classification": classification, "mutation": mutation, "backupPath": str(backup), "entryCount": 0, "strictValidation": "PASS", "newShape": "entries-object"})


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
    with _FileLock(lock):
        # Re-read only after acquiring the same lock Hermes uses. Never make a
        # mutation decision from an unlocked snapshot.
        try:
            raw_locked = state.read_text(encoding="utf-8-sig")
        except Exception as exc:
            emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_READ_FAILED", "mutation": "NONE", "errorType": type(exc).__name__}, 42)

        size_bytes = len(raw_locked.encode("utf-8"))
        digest = hashlib.sha256(raw_locked.encode("utf-8")).hexdigest()
        normalized = "".join(raw_locked.split())

        try:
            parsed_locked = json.loads(raw_locked)
        except Exception as exc:
            # Safe repair is intentionally narrow. These are empty registry
            # objects missing only their final closing brace. They cannot encode
            # an owner/session entry. Anything else fails closed.
            truncated_empty = normalized in {
                '{"sessions":[]',
                '{"entries":[]',
            }
            if truncated_empty:
                backup_and_write_empty(
                    state,
                    "HERMES_SESSION_REGISTRY_TRUNCATED_EMPTY_REPAIRED",
                    "TRUNCATED_EMPTY_TO_ENTRIES",
                    base,
                )
            emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_INVALID_JSON", "mutation": "NONE", "sizeBytes": size_bytes, "sha256": digest, "errorType": type(exc).__name__}, 43)

        try:
            entries = _read_entries(state, strict=True)
            emit({**base, "ok": True, "classification": "HERMES_SESSION_REGISTRY_ALREADY_VALID", "mutation": "NONE", "entryCount": len(entries), "shape": "entries-compatible", "sizeBytes": size_bytes, "strictValidation": "PASS"})
        except ActiveSessionRegistryError:
            pass

        legacy_empty = (
            isinstance(parsed_locked, dict)
            and set(parsed_locked.keys()) == {"sessions"}
            and isinstance(parsed_locked.get("sessions"), list)
            and len(parsed_locked["sessions"]) == 0
        )
        empty_object = isinstance(parsed_locked, dict) and len(parsed_locked) == 0
        if legacy_empty:
            backup_and_write_empty(
                state,
                "HERMES_SESSION_REGISTRY_LEGACY_EMPTY_SCHEMA_REPAIRED",
                "LEGACY_EMPTY_SESSIONS_TO_ENTRIES",
                base,
            )
        if empty_object:
            backup_and_write_empty(
                state,
                "HERMES_SESSION_REGISTRY_EMPTY_OBJECT_REPAIRED",
                "EMPTY_OBJECT_TO_ENTRIES",
                base,
            )

        shape = "other-invalid"
        if isinstance(parsed_locked, dict) and "sessions" in parsed_locked:
            shape = "sessions-object"
        elif isinstance(parsed_locked, dict) and "entries" in parsed_locked:
            shape = "entries-object-invalid"
        elif isinstance(parsed_locked, list):
            shape = "list-invalid"
        emit({**base, "ok": False, "classification": "HERMES_SESSION_REGISTRY_INVALID_NOT_SAFE_TO_AUTO_REPAIR", "mutation": "NONE", "shape": shape, "sizeBytes": size_bytes, "sha256": digest, "strictValidation": "FAIL"}, 44)
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

Write-Output $output
exit $code
