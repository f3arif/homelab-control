# AFZ Direct Portable Windows Jobs

This directory is the only approved GitHub source prefix for the initial Direct Fabric portable-PowerShell canary lane.

## Execution contract

A Direct Fabric job may reference a script here only by:

- repository: `f3arif/homelab-control`
- exact 40-character Git commit SHA (never `main` or another moving ref)
- path under `afz-openai-agent/portable-jobs/`
- exact SHA-256 of the downloaded script bytes
- bounded timeout, initially 5–300 seconds
- maximum script size 65,536 bytes

The worker must download the exact-commit artifact, verify SHA-256, parse it with Windows PowerShell before execution, and require these markers near the beginning of the file:

```text
# AFZ_PORTABLE_WINDOWS=1
# AFZ_LENOVO_ALLOWED=1
# AFZ_DIRECT_PORTABLE=1
# AFZ_DIRECT_RISK=A0
```

No raw command, inline PowerShell, base64 command, arbitrary URL, branch name, or user-supplied executable path is accepted by this lane.

The first rollout is CANARY ONLY. It does not grant general project execution or routing authority, does not alter RadioHilal/H3 ownership, and must never dual-execute a job through the legacy OneDrive queue and Direct Fabric.
