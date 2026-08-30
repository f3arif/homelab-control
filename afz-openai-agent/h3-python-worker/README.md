# H3 Python worker shadow foundation (R5)

Status: **STAGED / NON-AUTHORITATIVE / NOT DEPLOYED**.

This directory is the side-by-side foundation for replacing selected H3 PowerShell worker plumbing with Python. It intentionally does **not** replace the AFZ execution fabric.

## Authority boundary

- Control Hub / PostgreSQL / Direct Fabric remains the live execution, lease, health, and routing authority.
- GitHub remains durable source and coordination.
- OneDrive / SharePoint remains emergency fallback only.
- This code has no scheduler, queue database, autonomous claim loop, retry policy, wake policy, or cross-worker routing logic.
- Prefect is not introduced here.
- There is still no Control Hub URL, token, credential lookup, HTTP library, service installer, Scheduled Task mutation, or Python-worker activation hook in this directory.

## R1 foundation

`afz_h3_worker/process.py` is the one permitted native-process boundary for the future worker. It uses argument arrays with `shell=False`, disables Git credential prompting, closes stdin by default, captures stdout/stderr, preserves the real child exit code, uses `CREATE_NO_WINDOW` on Windows, applies an explicit timeout, and terminates the child process tree on timeout.

`afz_h3_worker/parity.py` provides strict comparison primitives for legacy-vs-candidate exit status, stdout/stderr, deterministic artifact hashes, and semantic JSON comparisons where explicitly declared volatile fields are ignored.

`shadow_probe.py` remains read-only. It hashes legacy scripts and snapshots an existing heartbeat file; it does not claim or complete jobs, execute commands, install a service, or modify Scheduled Tasks.

## R2 typed canary contracts

R2 introduced evidence-bounded models for the portable `portable-powershell-github` canary, its job-create payload, direct-executor result envelope, and the fail-closed `UnboundControlHubTransport`.

## R3 recovered Control Hub worker contract

R3 incorporated the archived AFZ Control Hub source capture from August 25, 2026. The worker-side heartbeat, claim, finite lease, and canonical completion contracts are known rather than guessed.

- Health: `GET /health`.
- Worker heartbeat: `POST /api/workers/{worker_id}/heartbeat`.
- Worker claim: `POST /api/workers/{worker_id}/claim`, no body, `lease_seconds` default 60 and server clamp 15–7200, with newer `strict_preferred` support.
- Claim result fields: `job_id`, `project`, `action`, `payload`, `required_capabilities`, `attempt`, `lease_until`.
- Canonical completion: `POST /api/jobs/{job_id}/complete` with `worker_id`, `ok`, `result`, and `error`.
- `CLAIM_SCHEMA_KNOWN=True` and `LEASE_RENEWAL_SCHEMA_KNOWN=False`; **no lease-renew endpoint** was present in the captured source or diagnostic archive, so renewal is not invented.
- The legacy direct-gateway `/claim` and `/complete` envelopes remain modelled separately from canonical Hub routes.

`UnboundControlHubTransport` still performs no live I/O: `network_enabled=False`, `routing_authority=False`, `scheduling_authority=False`.

## R4 live H3 runtime contract

R4 used bounded read-only H3 audits on August 30, 2026 to pin the runtime that the Python candidate must match.

Current file identities:

- Generic worker: `C:\AFZ\H3Worker\AFZ-H3-Worker.ps1`, SHA-256 `B61D8EB4E625549836C504D102BC0139D1C97786447E2EA071AC9DBC8F02795E`, 17,633 bytes / 306 lines.
- Ollama telemetry: `C:\AFZ\H3Worker\AFZ-H3-OllamaTelemetry.ps1`, SHA-256 `BFEFD838E7E3AD3E9723FB47FADDC844AB534B382076C65082F739D5C9C4B30A`, 7,001 bytes / 64 lines.
- H3 Direct worker: `C:\ProgramData\AFZ\H3Direct\AFZ-H3-Direct-Worker.ps1`, SHA-256 `BA417A98FB84972317ED0668FDCFFEF144B0944071841A73A18EB2BDC3109F61`, 4,800 bytes / 95 lines.

Current Generic Worker constants are verified against that exact SHA: version `1.0.0`, target `DESKTOP-H3R6CQN`, mutex `Local\AFZH3GenericWorker`, 12-second poll, 88% heavy-RAM hold threshold, 120,000-character max captured output, and the nine current allowed actions.

The Generic file queue uses `Queue\h3`, `Processing\h3`, `Results\h3`, `Archive\h3`, oldest `LastWriteTimeUtc,Name` first, with ten read retries at two seconds. Heavy jobs are held when RAM is at/above the threshold or RadioHilal35B is `BUSY`.

The current heartbeat schema includes worker identity/state, queue/RAM/RadioHilal state, Ollama/model/context/activity, GPU/VRAM telemetry, `allowedActions`, `forcedSleep`, and `ollamaExposureChanged`.

Launch evidence is intentionally precise about time: Direct and Generic future Scheduled Task launches were changed to hidden `wscript.exe` VBS launchers at 01:32 EDT without restarting the preserved live PIDs; at 13:51 EDT those exact PIDs were still live. R4 therefore records launcher-definition + PID-continuity evidence and does not claim a fresh task-XML read at 13:51.

## R5 deterministic `h3-file-hash` candidate

R5 selects the smallest deterministic legacy action before any live Python transport is introduced.

A real legacy `h3-file-hash` canary was run against the pinned Generic Worker file itself. It completed successfully in 0.2 seconds and produced:

- `FILE_HASH : READ ONLY`
- `PATH=C:\AFZ\H3Worker\AFZ-H3-Worker.ps1`
- `SHA256=B61D8EB4E625549836C504D102BC0139D1C97786447E2EA071AC9DBC8F02795E`
- `ForcedSleep=False`
- `OllamaExposureChanged=False`

The current worker's `Write-Result` contract serializes the action payload as `result` and renders each `result.summary` entry into the text artifact. `afz_h3_worker/actions.py` therefore implements the candidate as exactly one local read-only action returning:

```text
{"summary":["FILE_HASH : READ ONLY","PATH=<resolved path>","SHA256=<uppercase SHA-256>"]}
```

The candidate resolves the requested file before hashing, requires it to be inside an explicitly supplied read-only root, rejects directories/out-of-root paths, and performs no subprocess or network I/O. It does not write AFZ queue/result/archive files and is not wired into Control Hub or any live H3 launcher.

R5 unit tests pin the uppercase digest and exact three-line payload shape and prove the path guard fails closed. This is candidate-contract validation only; **live H3 legacy-vs-Python execution parity is still required before promotion**.

## Next promotion gates

R5 permits a bounded, non-authoritative live shadow comparison only. It does not authorize cutover.

1. Place/run the exact GitHub R5 candidate transiently on H3 without replacing or restarting the Generic Worker.
2. Hash the same pinned Generic Worker file through legacy `h3-file-hash` and the Python candidate and compare exact resolved path, uppercase SHA-256, summary order, candidate exit status, and orphan-process count.
3. Confirm the legacy heartbeat remains healthy and the worker PID/launcher state is unchanged after the candidate run.
4. Only after that parity proof, select the next deterministic read-only action or add a bounded Control Hub transport with no scheduler/routing authority.
5. Only after broader parity, run plain `python.exe` under WinSW or NSSM with service recovery and external heartbeat monitoring. Do not use `pythonw.exe` and do not use an in-process watchdog as the resurrection mechanism.
6. Retire one corresponding legacy launcher at a time only after rollback has also been proven.

## Local validation

```text
python -m compileall -q afz_h3_worker shadow_probe.py tests
python -m unittest discover -s tests -v
```
