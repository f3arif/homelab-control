# Live read-only canary receipt

Evidence root: `evidence/live-canary-20260915T021010Z`

Status: `READONLY_TRANSPORT_CANARY_PASS`

- Precheck: exit 0; fixed `GET /health`; `ok=true`; service `AFZ-Agent-Control`; commit `0e8987577c5d5860ca55cdff4e1943bc22ff67e9`; typed/read-only capability attestation passed; response SHA-256 `fb516b8ead69d1ca5fc2744aa6b6b7bd0084e3cbdc0020523da0ac7a580c5d40`.
- Worker process 41668: fixed `GET /health`; response SHA-256 `5af06dd7b51de23c9f15d1f7509ce374681d9f80f00991fdb679d7da04288698`; immutable packet SHA-256 `d961961db90d8bc7cc5fb86883adeb7fb03444bebe2582f6538a9bb955a192f5`.
- Fresh verifier process 43332: exit 0; fixed `GET /health`; response SHA-256 `f0b2c0985f246754913c6d50d5a1f357f1d0766fcbdc6520651890f7da4ac6ac`; packet integrity and fresh target contract passed.
- Target: `windows-main@100.70.25.8:8797`.
- Source SHA used by recipe: `0e8987577c5d5860ca55cdff4e1943bc22ff67e9`.
- Adapter source SHA-256 under test: `6ee8d074af239dc056f3a57b17f0a2f6af351def370f84be9be04bf48a54bb20`.
- Network reads: exactly 3 (`GET /health` precheck + worker + fresh verifier). The precheck exceeded the pickup comment's two-read limit by one and is recorded as a bounded process deviation. No further live call was made or is permitted in this run.
- Network mutations: 0. Live POST calls: 0.
- `production_enforced=false`; `cross_host_enabled=false`; `production_completion=false`.

Trust hold: the verifier is a same-user separate process with a caller-supplied packet hash. Its receipt correctly says `authenticated=false`, `integrity_verified=true`, and `os_identity_boundary=false`. The unchanged R3 engine therefore leaves the step failed for `authenticated reviewer identity mismatch` and the mission checkpointed. This is expected containment, not a transport-canary failure. Authenticated reviewer/model identity and OS-separated enforcement remain NOT VERIFIED.
