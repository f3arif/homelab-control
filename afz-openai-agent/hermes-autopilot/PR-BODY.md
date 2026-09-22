## Summary

- Adds a fixed-route Python adapter around the independently verified R3 `MissionEngine` under `afz-openai-agent/hermes-autopilot/`.
- Pins the Control Hub to `http://100.70.25.8:8797`, source `0e8987577c5d5860ca55cdff4e1943bc22ff67e9`, and recipe `control-health-readonly-v1` (`GET /health`, no body).
- Rejects credentials, alternate host/port/scheme, query, fragment, redirects, unknown paths/methods/bodies, commit mismatch, capability mismatch, stale/tampered packets, duplicate/rebound admission, and network timeout.
- Vendors the independently verified R3 source and 54-case suite with exact hashes.
- Adds durable authorization-key binding/idempotency without treating that key as authenticated identity proof.

## Verification

- Full local suite: 78 passed, 0 failed/errors/skips, child exit 0.
  - Vendored R3: 54 distinct cases.
  - Adapter/integration: 24 cases.
- Ruff check/format and compileall pass for new integration code.
- Both installed console entrypoints and both module entrypoints return help with exit 0.
- R3 core SHA-256: `617f227717b7b0ecd500d5618664fae79472c8f5634b0ce74ae238255a6db651`.
- Independent R3 receipt SHA-256: `17269514e5cd4567b49787b87df4b9a7f01b47592cf2ee9b066b5b2e969913f0`.

## Live read-only canary

Status: `READONLY_TRANSPORT_CANARY_PASS`.

Exactly three H3-to-Windows-main `GET /health` reads occurred: fixed precheck, worker, and fresh verifier process. The precheck exceeded the worker pickup comment's two-read limit by one and is recorded as a bounded process deviation. No further live Control Hub call was made after the finding.

- Precheck response SHA-256: `fb516b8ead69d1ca5fc2744aa6b6b7bd0084e3cbdc0020523da0ac7a580c5d40`.
- Worker response SHA-256: `5af06dd7b51de23c9f15d1f7509ce374681d9f80f00991fdb679d7da04288698`.
- Immutable packet SHA-256: `d961961db90d8bc7cc5fb86883adeb7fb03444bebe2582f6538a9bb955a192f5`.
- Fresh verifier response SHA-256: `f0b2c0985f246754913c6d50d5a1f357f1d0766fcbdc6520651890f7da4ac6ac`.
- Worker PID 41668; verifier PID 43332; both exits 0.
- All reads attested `ok=true`, service `AFZ-Agent-Control`, exact commit, and typed/read-only/no-arbitrary-shell capability metadata.
- Live POST/mutation calls: 0.

## Trust hold

The same-user verifier process proves packet integrity, process separation, and fresh target read-back, not authenticated reviewer/model identity or a privileged OS boundary. The receipt intentionally has `authenticated=false`, `integrity_verified=true`, and `os_identity_boundary=false`. The unchanged R3 engine therefore records `authenticated reviewer identity mismatch`, leaves the step failed, and checkpoints the mission.

- `authenticated_review_gate=NOT_VERIFIED`
- `engine_completion_gate=HELD_UNAUTHENTICATED`
- `production_completion=false`
- `production_enforced=false`
- `cross_host_enabled=false`
- `authorization_provenance_verified=false`

## Boundaries and rollback

No merge, deployment, release, service/listener/firewall/scheduled-task change, Postgres installation, Hermes native patch, gateway/profile/approval/routing change, auto-decompose change, production task enrollment, OneDrive dependency, or dirty Windows-main checkout operation occurred. Existing `kanban.auto_decompose=false` remains unchanged.

Rollback: close this draft PR and delete the feature branch. No runtime rollback is required because nothing was deployed.

## Review focus

- Fixed URL/recipe enforcement and redirect behavior.
- Packet age/hash/source/response contract validation.
- Honest separation of transport-canary PASS from authenticated review HOLD.
- Admission key binding as idempotency only, not operator identity.
- Preservation of the vendored R3 hashes and 54-case behavior suite.

## Independent lint correction

An independent reviewer reproduced Ruff `I001` on the first draft-PR head, so the earlier Ruff-PASS claim was withdrawn. The second/final authorized correction adds an explicit isort section split between `pytest` and the local package imports in `tests/test_adapter.py`; it changes no runtime behavior and does not suppress `I001`.

On the final correction tree, the README-documented Ruff command exits 0, a repository-root verifier invocation also exits 0, `ruff format --check` exits 0, `compileall` exits 0, and the full suite reports 78 passed with zero failures/errors/skips. Exact stdout, stderr, exit files, hashes, and the correction receipt are under `evidence/correction-attempt2/`.

No live Control Hub request was repeated. The earlier total remains exactly three read-only `GET /health` calls, including the disclosed one-read precheck variance. The authenticated-review/OS-identity gate remains `NOT_VERIFIED`; production remains held.
