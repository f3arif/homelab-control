# H3 Python worker shadow foundation (R4)

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

Current Generic Worker constants are now verified against that exact SHA:

- version `1.0.0`;
- target `DESKTOP-H3R6CQN`;
- mutex `Local\AFZH3GenericWorker`;
- poll interval 12 seconds;
- heavy-RAM hold threshold 88%;
- max captured output 120,000 characters;
- heavy actions: `h3-dotnet-build`, `h3-npm-build`, `h3-npm-test`, `h3-tsc`;
- allowed actions: `h3-status`, `h3-powershell-parse`, `h3-json-validate`, `h3-python-compile`, `h3-file-hash`, plus the four heavy actions.

The Generic file queue uses `Queue\h3`, `Processing\h3`, `Results\h3`, `Archive\h3`, oldest `LastWriteTimeUtc,Name` first, with ten read retries at two seconds. Heavy jobs are held when RAM is at/above the threshold or RadioHilal35B is `BUSY`.

The current heartbeat schema includes worker identity/state, queue/RAM/RadioHilal state, Ollama/model/context/activity, GPU/VRAM telemetry, `allowedActions`, `forcedSleep`, and `ollamaExposureChanged`. The R4 V2 live sample was `READY`, queue 0, RAM 53.2%, RadioHilal35B `READY`, compute `IDLE`, and was only 9.5 seconds old when captured.

Launch evidence is intentionally precise about time:

- At 01:32 EDT the `AFZ H3 Direct Worker` and `AFZ H3 Generic Worker` Scheduled Task definitions were verified as user `Faiz`, `Interactive`, `Limited`, and changed for **future launches only** to hidden `wscript.exe //B //Nologo` VBS launchers; the existing live PIDs were explicitly preserved.
- At 13:51 EDT, those exact preserved PIDs were still live: Direct `13612`, Generic `12112`. Therefore R4 records launcher-definition + live-PID continuity; it does **not** claim the task XML was freshly re-read at 13:51.
- Generic Worker and Ollama telemetry also have current HKCU Run definitions through hidden `wscript.exe` VBS launchers. Current telemetry PID was `23032`.
- All observed worker processes remain in session 1. The eventual Python service stage must move the candidate under external service supervision rather than relying on this interactive-session architecture.

`afz_h3_worker/runtime_contract.py` is the machine-readable R4 evidence boundary. It is not a deployment configuration file and grants no runtime authority.

## Next promotion gates

R4 permits the next **non-authoritative parity** step only. It does not authorize cutover.

1. Run the Python `shadow_probe.py` on H3 against the exact pinned Generic Worker SHA and heartbeat schema, with no worker/task changes.
2. Select a bounded canary that can execute safely inside the finite lease contract; do not depend on lease renewal unless a newer authoritative Hub contract proves it.
3. Run the same bounded canary through legacy and candidate implementations and compare the real child exit code, stdout/stderr semantics, deterministic artifact hashes, externally visible state, timeout behavior, and orphan-process count.
4. Only after parity, add a live Control Hub transport with no scheduler/routing authority.
5. Only after independent canary proof, run plain `python.exe` under WinSW or NSSM with service recovery and external heartbeat monitoring. Do not use `pythonw.exe` and do not use an in-process watchdog as the resurrection mechanism.
6. Retire one corresponding legacy launcher at a time only after rollback has also been proven.

## Local validation

```text
python -m compileall -q afz_h3_worker shadow_probe.py tests
python -m unittest discover -s tests -v
```
