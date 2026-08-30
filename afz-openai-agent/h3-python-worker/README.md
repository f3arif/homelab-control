# H3 Python worker shadow foundation (R3)

Status: **STAGED / NON-AUTHORITATIVE / NOT DEPLOYED**.

This directory is the side-by-side foundation for replacing selected H3 PowerShell worker plumbing with Python. It intentionally does **not** replace the AFZ execution fabric.

## Authority boundary

- Control Hub / PostgreSQL / Direct Fabric remains the live execution, lease, health, and routing authority.
- GitHub remains durable source and coordination.
- OneDrive / SharePoint remains emergency fallback only.
- This code has no scheduler, queue database, autonomous claim loop, retry policy, wake policy, or cross-worker routing logic.
- Prefect is not introduced here.
- R3 contains no Control Hub URL, token, credential lookup, HTTP library, service installer, Scheduled Task mutation, or H3 activation hook.

## R1 foundation

`afz_h3_worker/process.py` is the one permitted native-process boundary for the future worker. It uses argument arrays with `shell=False`, disables Git credential prompting, closes stdin by default, captures stdout/stderr, preserves the real child exit code, uses `CREATE_NO_WINDOW` on Windows, applies an explicit timeout, and terminates the child process tree on timeout.

`afz_h3_worker/parity.py` provides strict comparison primitives for legacy-vs-candidate exit status, stdout/stderr, deterministic artifact hashes, and semantic JSON comparisons where explicitly declared volatile fields are ignored.

`shadow_probe.py` remains read-only. It hashes legacy scripts and snapshots an existing heartbeat file; it does not claim or complete jobs, execute commands, install a service, or modify Scheduled Tasks.

## R2 typed canary contracts

R2 introduced evidence-bounded models for the portable `portable-powershell-github` canary, its job-create payload, direct-executor result envelope, and the fail-closed `UnboundControlHubTransport`.

## R3 recovered worker contract

R3 incorporates the archived AFZ Control Hub source capture from August 25, 2026. The worker-side heartbeat, claim, finite lease, and canonical completion contracts are now known rather than guessed.

Proven Control Hub routes and shapes:

- Health: `GET /health`.
- Worker heartbeat: `POST /api/workers/{worker_id}/heartbeat` with `state`, `capabilities`, `metadata`, and `current_job_id`.
- Worker claim: `POST /api/workers/{worker_id}/claim` with **no request body**; query parameters are `lease_seconds` and, in the newer captured contract, `strict_preferred`.
- `lease_seconds` defaults to 60 and the server clamps it to 15–7200 seconds.
- A successful claim returns `job_id`, `project`, `action`, `payload`, `required_capabilities`, `attempt`, and `lease_until`; an idle claim returns `{"ok": true, "job": null}`.
- Canonical completion: `POST /api/jobs/{job_id}/complete` with `worker_id`, `ok`, `result`, and `error`; completion succeeds only for the current lease owner.
- Heartbeat acknowledgement: `ok`, `worker_id`.
- Completion acknowledgement: `ok`, `status`, where status is `COMPLETED` or `FAILED`.

`CLAIM_SCHEMA_KNOWN=True` in R3. `LEASE_RENEWAL_SCHEMA_KNOWN=False`: no lease-renew endpoint was present in the captured Control Hub source or diagnostic archive, so the staged worker must not invent renewal semantics. Jobs therefore have a finite captured lease contract until a newer authoritative Hub contract proves otherwise.

The distinction between the older direct gateway and canonical Control Hub is preserved intentionally: `/claim` and `/complete` remain documented as direct-gateway paths, while the canonical Hub uses `/api/workers/{worker_id}/claim` and `/api/jobs/{job_id}/complete`.

`UnboundControlHubTransport` now exposes typed heartbeat/claim/completion methods but **all live I/O still fails closed** with `LiveTransportUnavailable`. Its flags remain `network_enabled=False`, `routing_authority=False`, and `scheduling_authority=False`. Lease renewal fails with `LeaseRenewalContractUnavailable`.

## Promotion gates

This code must not become a live worker until all of these are satisfied:

1. Recover the current H3 runtime-local Generic Worker/direct-worker script hashes, heartbeat identity/capabilities, cadence, external commands, and observable outputs.
2. Run `shadow_probe.py` on H3 without changing the existing worker.
3. Add a live Control Hub transport only after current endpoint/auth reachability is revalidated. It must consume the existing Hub contract and must not add scheduling/routing authority.
4. Because no renewal contract is known, choose a bounded canary whose worst-case execution plus reporting fits safely inside the claimed lease, or first prove a newer Hub renewal contract.
5. Run the same bounded canary through legacy and candidate implementations and compare real child exit code, artifacts, external state, timeout behavior, and orphan-process count.
6. Only after parity, run plain `python.exe` under external Windows supervision (WinSW or NSSM). Do not use `pythonw.exe` and do not rely on an in-process watchdog for resurrection.
7. Independently monitor worker heartbeat outside the worker process.
8. Retire the corresponding legacy Scheduled Task individually only after an independently observed canary pass and rollback check.

## Local validation

```text
python -m compileall -q afz_h3_worker shadow_probe.py tests
python -m unittest discover -s tests -v
```
