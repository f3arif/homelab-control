# Authenticated verifier installation and rollback plan

Status: plan only. Nothing in this candidate installs a service, creates an
identity or key, changes a certificate store/ACL, opens a listener, or enables
production.

## Fixed future contract

- Service name: `AFZHermesVerifier`
- Identity: `NT SERVICE\\AFZHermesVerifier` with its fixed service SID
- Binary: `C:\\Program Files\\AFZ\\HermesVerifier\\afz-hermes-verifier.exe`
- IPC: local named pipe `npipe://./pipe/afz-hermes-verifier-v1`; no TCP listener
- Certificate store: `LocalMachine\\My`
- Key provider: Windows CNG, machine-scoped and non-exportable
- Private-key ACL: service SID only, plus the minimum Windows administrative
  principals required for recovery
- Trust input visible to the worker: pinned public certificate and SHA-256
  thumbprint only
- Runtime input: versioned receipt/packet references only; no URL, shell,
  command, method, arbitrary body, or private-key material

## Future authorization and installation sequence

Any future privileged installer must default to `Audit`/dry-run and refuse
mutation unless a separately issued sentinel exactly names the service,
machine, binary hash, certificate thumbprint, service SID, and this phase's
resume key. The sentinel must be checked before every mutation and must not be
accepted from an environment variable or request body.

1. Audit the expected Windows machine, service absence/presence, fixed path,
   service SID, certificate store, key provider/export policy, key ACL, named
   pipe ACL, binary hash, and existing rollback material.
2. Obtain explicit future authorization for that exact audited state. This
   document and the current task are not that authorization.
3. Create or select the machine-scoped non-exportable certificate/key under an
   administrator-controlled provisioning path; never expose private key bytes.
4. Install the pinned binary at the fixed path and register the fixed service
   under the dedicated virtual service identity.
5. Apply least-privilege key and pipe ACLs to the service SID; deny worker and
   ordinary interactive-user signing access.
6. Start only after configuration and binary hashes are re-read. Run local
   negative tests before any production enrollment.
7. Produce a cryptographically anchored installation attestation from a
   separate provisioning/admin trust root. It must bind machine identity,
   service identity/SID, binary/source hash, certificate thumbprint/key id,
   key non-exportability and ACL observations, protected runtime, issuance and
   expiry times, and a replay-protected challenge. A matching worker-supplied
   JSON object is not an attestation.
8. Independently verify that attestation and the service's signed receipt before
   any later code is permitted to set `authenticated=true`.

No generic shell or URL execution is part of this sequence. No Control Hub
network request is required for installation validation.

## Rollback

Before install, capture service configuration, file/certificate identifiers,
ACLs, and hashes. Rollback must stop and remove only `AFZHermesVerifier`, remove
only the exact pinned binary and certificate/key created by the authorized
install, restore any pre-existing ACL/config state from the captured record,
remove the named-pipe ACL, and verify no listener/service/key remains. Never
delete a certificate or key by broad subject-name search.

For this source-only phase, rollback is limited to closing the draft PR and
deleting `feature/hermes-autopilot-auth-verifier-boundary-20260918`; there is no
runtime rollback because no installation occurred.