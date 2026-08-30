# H3 Python worker shadow foundation (R1)

Status: **STAGED / NON-AUTHORITATIVE / NOT DEPLOYED**.

This directory is the first side-by-side step toward replacing selected H3 PowerShell worker plumbing with Python. It intentionally does **not** replace the AFZ execution fabric.

## Authority boundary

- Control Hub / PostgreSQL / Direct Fabric remains the live execution, lease, health, and routing authority.
- GitHub remains durable source and coordination.
- OneDrive / SharePoint remains emergency fallback only.
- This R1 code has no scheduler, queue database, claim loop, retry policy, wake policy, or cross-worker routing logic.
- Prefect is not introduced here.

## Included in R1

`afz_h3_worker/process.py` is the one permitted native-process boundary for the future worker. It uses argument arrays with `shell=False`, disables Git credential prompting, closes stdin by default, captures stdout/stderr, preserves the real child exit code, uses `CREATE_NO_WINDOW` on Windows, applies an explicit timeout, and terminates the child process tree on timeout.

`afz_h3_worker/parity.py` provides strict comparison primitives for legacy-vs-candidate exit status, stdout/stderr, deterministic artifact hashes, and semantic JSON comparisons where explicitly declared volatile fields are ignored.

`shadow_probe.py` is read-only. It can hash current legacy scripts and snapshot an existing heartbeat file. It does not call Control Hub, claim jobs, complete jobs, execute commands, install a service, or modify Scheduled Tasks.

## Promotion gates

R1 must not become a live worker until all of these are proven:

1. Capture the current H3 Generic Worker and telemetry contract: exact script hashes, heartbeat schema, queue/claim semantics, cadence, external commands, and observable outputs.
2. Run `shadow_probe.py` on H3 without changing the existing worker.
3. Add a typed Control Hub client that only consumes the existing claim/lease contract; do not add local scheduling policy.
4. Run the same bounded canary through legacy and candidate implementations and compare the real process exit, artifacts, external state, timeout behavior, and orphan-process count.
5. Only after parity, run `python.exe` under external Windows supervision (WinSW or NSSM). Do not use `pythonw.exe` and do not rely on an in-process watchdog for resurrection.
6. Retire the corresponding legacy Scheduled Task individually only after an independently observed canary pass and rollback check.

## Local validation

```text
python -m compileall -q afz_h3_worker shadow_probe.py tests
python -m unittest discover -s tests -v
```
