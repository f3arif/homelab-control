# H3 Python worker shadow foundation (R2)

Status: **STAGED / NON-AUTHORITATIVE / NOT DEPLOYED**.

This directory is the side-by-side foundation for replacing selected H3 PowerShell worker plumbing with Python. It intentionally does **not** replace the AFZ execution fabric.

## Authority boundary

- Control Hub / PostgreSQL / Direct Fabric remains the live execution, lease, health, and routing authority.
- GitHub remains durable source and coordination.
- OneDrive / SharePoint remains emergency fallback only.
- This code has no scheduler, queue database, claim loop, retry policy, wake policy, or cross-worker routing logic.
- Prefect is not introduced here.

## R1 foundation

`afz_h3_worker/process.py` is the one permitted native-process boundary for the future worker. It uses argument arrays with `shell=False`, disables Git credential prompting, closes stdin by default, captures stdout/stderr, preserves the real child exit code, uses `CREATE_NO_WINDOW` on Windows, applies an explicit timeout, and terminates the child process tree on timeout.

`afz_h3_worker/parity.py` provides strict comparison primitives for legacy-vs-candidate exit status, stdout/stderr, deterministic artifact hashes, and semantic JSON comparisons where explicitly declared volatile fields are ignored.

`shadow_probe.py` is read-only. It can hash current legacy scripts and snapshot an existing heartbeat file. It does not call Control Hub, claim jobs, complete jobs, execute commands, install a service, or modify Scheduled Tasks.

## R2 typed Control Hub contracts

R2 adds `afz_h3_worker/contracts.py` and `afz_h3_worker/transport.py`. They are deliberately evidence-bounded to the existing Control Hub / Lenovo direct portable canary rather than guessing the H3 worker protocol.

Proven contract pieces modelled in R2:

- Control Hub health path: `/health`.
- Authenticated job-create path observed in the canary: `/api/jobs`.
- Worker-side paths observed in the direct worker/gateway: `/claim` and `/complete`.
- Portable action: `portable-powershell-github`.
- Portable job fields: `project`, `action`, `payload`, `required_capabilities`, `preferred_worker`, `max_attempts`.
- Portable payload fields: `repo`, `commit`, `path`, `sha256`, `timeout_seconds`.
- Portable execution result fields: worker/action/source identity, exact child exit code, stdout, stderr, computer, and `direct_transport=true`.
- Completion envelope fields: `job_id`, `ok`, `result`, `error`.

The **claim request/response schema is not yet proven**. R2 therefore sets `CLAIM_SCHEMA_KNOWN=False`, excludes claim from the known transport protocol, and provides only an `UnboundControlHubTransport` that performs no network I/O. Calling claim fails closed with `ClaimContractUnavailable`; health/completion I/O fails closed with `LiveTransportUnavailable`.

R2 contains no Control Hub URL, token, credential lookup, HTTP library, or service installer.

## Promotion gates

This code must not become a live worker until all of these are proven:

1. Recover current H3 Generic Worker/direct-worker runtime contracts: exact script hashes, heartbeat schema, claim request/response, lease/renewal behavior, cadence, external commands, and observable outputs.
2. Run `shadow_probe.py` on H3 without changing the existing worker.
3. Add a typed worker transport only after the exact claim/lease contract is recovered. It must consume existing Control Hub authority and must not add local scheduling/routing policy.
4. Run the same bounded canary through legacy and candidate implementations and compare real process exit, artifacts, external state, timeout behavior, and orphan-process count.
5. Only after parity, run plain `python.exe` under external Windows supervision (WinSW or NSSM). Do not use `pythonw.exe` and do not rely on an in-process watchdog for resurrection.
6. Independently monitor worker heartbeat outside the worker process.
7. Retire the corresponding legacy Scheduled Task individually only after an independently observed canary pass and rollback check.

## Local validation

```text
python -m compileall -q afz_h3_worker shadow_probe.py tests
python -m unittest discover -s tests -v
```
