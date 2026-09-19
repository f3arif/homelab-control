# Authenticated verifier boundary report

STATUS: HELD_FOR_INDEPENDENT_REVIEW

IMPLEMENTED: Canonical signed receipts, pinned public-certificate verification,
fixed Windows LocalMachine/CNG provider contract, test-only signer, and atomic
SQLite nonce replay defense. Installation and rollback remain plan-only.

VERIFIED: 105 passed, 0 failed/errors/skipped; baseline 78 preserved;
Ruff check/format and compileall exit 0; clean install/import exit 0 with
cryptography 50.0.1; vendored R3 hashes unchanged.

NOT VERIFIED: No Windows service identity, machine key, key ACL/non-exportability,
protected runtime, or separately anchored provisioning/admin attestation was
installed or proven. authenticated=false and authenticated_review_gate=NOT_VERIFIED.

BLOCKER: Independent review plus a separately authorized privileged installation
and cryptographically anchored installation-attestation design are required.

NEXT: Review this stacked draft only. Do not merge, install, deploy, enroll, or
production-enable from this report.

BRANCH: feature/hermes-autopilot-auth-verifier-boundary-20260918
BASE: 64e81820cad2e52e40ae4b3a23b822ddbca041fb
IMPLEMENTATION COMMIT: 624bb3224806c5d1961076e7435d2e3bea1257fc
DRAFT PR: pending creation
TEST COUNTS+EXITS: 105 passed; 0 failed/errors/skipped; pytest/Ruff/format/compileall 0
HASHES: R3 core 617f227717b7b0ecd500d5618664fae79472c8f5634b0ce74ae238255a6db651; test certificate aac2b2920726d63ffc2a9558705be7bcbd72da56dba6d55b6241c631e1d77cf7
CONFIG+LIVE CHANGES: 0; Control Hub calls: 0
ROLLBACK: close the draft PR and delete the feature branch; no runtime rollback required
RESUME KEY: AFZ-HERMES-AUTOPILOT-AUTH-VERIFIER-20260918
