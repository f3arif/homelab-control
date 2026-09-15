# Commander quota fallback via AFZ typed RemoteOps

**Status:** proposed operational fallback  
**Workflow:** `AFZ-AUTOMATION-FABRIC-V1`  
**Purpose:** keep headless Windows operations available when Remote Desktop Commander is quota-blocked or unavailable.

## Routing

1. Use Remote Desktop Commander when available.
2. If Commander is unavailable or quota-blocked, use the existing GitHub-fast-signal → Push Deploy Watcher path.
3. The watcher may invoke only explicitly implemented typed handlers. It must not expose arbitrary shell execution.
4. Live machine mutation remains local to the existing AFZ worker/runtime. GitHub carries source/config/request state and durable evidence.
5. OneDrive/SharePoint remains diagnostic/backup-only and is never read as a command queue.

## Windows-main Docker typed lane

Handler: `Invoke-WindowsMain-Docker-Lifecycle.ps1`

Allowed actions:

- `status`
- `stop`
- `start`
- `restart`

Explicitly blocked:

- container removal
- image removal
- volume deletion
- Docker prune
- arbitrary shell commands

Requests are host-bound to `DESKTOP-10SKF0M`, validated by schema and request ID, and persisted under `C:\ProgramData\AFZ\OpenAIAgent\jobs\windowsmain-docker-lifecycle`.

The result mirror under `AFZ Shared\AFZ Workers\Results` is emergency observability only. It is not a control source.

## Current canary

Request `windowsmain-docker-lifecycle-20260915-stop-idle-r1` stops and disables auto-restart for:

- `n8n`
- `code-server`
- `technitium`

This is reversible and intentionally does not remove containers or persistent data.

## Safety

A request with `allow_remove`, `allow_volume_delete`, or `allow_prune` set true is rejected. Destructive cleanup stays outside this fallback lane and remains subject to the existing AFZ destructive-action gate.
