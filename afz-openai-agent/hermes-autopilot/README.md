# AFZ Hermes Autopilot protected Control Hub integration

This directory integrates the independently verified R3 `MissionEngine` with one fixed, read-only Control Hub recipe. It is an integration candidate, not production autonomy.

## Fixed contract

- Base URL: `http://100.70.25.8:8797` only.
- Live recipe: `control-health-readonly-v1` only.
- Request: `GET /health`, no body.
- Expected Control Hub source: `0e8987577c5d5860ca55cdff4e1943bc22ff67e9`.
- Required service: `AFZ-Agent-Control`, `ok=true`.
- Required capability attestation: `windowsWslMemoryAudit` is typed, read-only, maps to `/api/windows-wsl-memory-audit`, permits only `audit`, and says `arbitraryShell=false`.

The client rejects credentials, alternate schemes/hosts/ports, paths on the base URL, query strings, fragments, redirects, unknown recipes, arbitrary methods, arbitrary paths, and request bodies. It has no generic HTTP API.

## Trust boundaries

The H3 Python registry is defense in depth, not the production action boundary. Actual production enforcement remains on Windows-main: its typed endpoint allowlist, exact source-SHA checks, and peer checks. Client tampering cannot add arbitrary shell to the current Windows-main service because that service does not expose an arbitrary-shell route.

The verifier runs a fresh client in a separate process against the same fixed target and validates an immutable packet hash, packet age, source hash, response hash, commit, route, and capability contract. This proves packet integrity, process separation, and fresh target read-back only. It does not prove a privileged OS identity boundary or authenticated reviewer/model identity.

Accordingly, the verifier receipt intentionally sets:

- `authenticated=false`
- `integrity_verified=true`
- `os_identity_boundary=false`
- `authentication_scope=immutable-packet-hash-only`

The unchanged R3 engine therefore records `authenticated reviewer identity mismatch`, leaves the step failed, and checkpoints the mission. The canary can truthfully report `READONLY_TRANSPORT_CANARY_PASS` while `authenticated_review_gate=NOT_VERIFIED`, `engine_completion_gate=HELD_UNAUTHENTICATED`, and `production_completion=false`.

The admission key is a durable idempotency and binding mechanism. It is stored only as a SHA-256 digest and prevents a held task from becoming a fresh mission through duplicate ingress. It is not cryptographic proof of operator identity or authorization provenance.

## R3 fidelity

`VENDOR-MANIFEST.json` pins the exact independently verified R3 core and all six test files. The copied core SHA-256 is `617f227717b7b0ecd500d5618664fae79472c8f5634b0ce74ae238255a6db651`. The vendored suite contains 54 distinct cases. Do not modify vendored files; update only from a separately verified source and change the manifest in review.

## Tests

From this directory:

```text
uv venv .venv
uv pip install --python .venv/Scripts/python.exe -e . pytest ruff
PYTHONPATH=src PYTHONDONTWRITEBYTECODE=1 PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 .venv/Scripts/python.exe -m pytest -q -p no:cacheprovider tests
.venv/Scripts/ruff.exe check src/afz_hermes_autopilot tests/test_adapter.py tests/test_integration.py
.venv/Scripts/ruff.exe format --check src/afz_hermes_autopilot tests/test_adapter.py tests/test_integration.py
PYTHONDONTWRITEBYTECODE=1 .venv/Scripts/python.exe -m compileall -q -f src
```

Both installed console entrypoints are exercised with `--help` before the live canary:

```text
.venv/Scripts/afz-autopilot-health-canary.exe --help
.venv/Scripts/afz-autopilot-health-verify.exe --help
```

## Authorized canary

The live phase performed exactly three total network reads: one fixed-target precheck `GET /health`, one worker `GET /health`, and one fresh verifier-process `GET /health`. This exceeded the pickup comment's two-read limit by the single precheck; it is recorded as a bounded process deviation. All three reads were read-only, their response hashes and exits are preserved, and no further live call is permitted in this run. No live POST was made.

```text
.venv/Scripts/afz-autopilot-health-canary.exe \
  --state-db <evidence>/canary/state.sqlite3 \
  --admission-db <evidence>/canary/admission.sqlite3 \
  --evidence-dir <evidence>/canary \
  --authorization-key AFZ-HERMES-AUTOPILOT-INTEGRATION-20260914 \
  --source-task-id t_834aebec \
  --source-task-status triage
```

## Production hold and rollback

`production_enforced=false` and `cross_host_enabled=false`. No Postgres service is assumed or installed. PostgreSQL-backed production state, authenticated/OS-separated review, real multi-host fencing, and production enrollment remain separate decisions. No OneDrive queue or trigger is introduced.

This phase changes no live Control Hub code, listener, firewall, service, scheduled task, Hermes installation, Kanban schema, block counter, gateway, profile, approval, routing, or auto-decompose setting. The existing `kanban.auto_decompose=false` containment remains in place.

No deployment occurred. Rollback is source-only: close the draft PR and delete the feature branch. There is no runtime rollback because no production state was changed.

## Future endpoint proposal (not implemented or activated)

A future generic Autopilot endpoint should still not accept a URL, shell, command, method, or free-form body. A minimal contract would accept only a versioned recipe name, exact source SHA, idempotency key, and immutable authorization/receipt references; Windows-main would resolve the recipe to a compiled allowlist and reject unknown fields. It must add authenticated identity, OS-separated verification, durable production state, peer/source fencing, and independent security review before activation.
