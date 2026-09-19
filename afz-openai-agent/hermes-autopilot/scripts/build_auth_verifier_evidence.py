"""Build fail-closed authenticated-verifier evidence and public fixtures."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
if str(TESTS) not in sys.path:
    sys.path.insert(0, str(TESTS))

from support.test_only_signer import TEST_ONLY_LABEL, TestOnlySigner

from afz_hermes_autopilot.authenticated_verifier import (
    InstallationPolicy,
    NonceLedger,
    ReceiptExpectations,
    SignerTrustPolicy,
    build_receipt_claims,
    sign_receipt,
    verify_signed_receipt,
)

EVIDENCE = ROOT / "evidence" / "auth-verifier"
BASE_HEAD = "64e81820cad2e52e40ae4b3a23b822ddbca041fb"
BRANCH = "feature/hermes-autopilot-auth-verifier-boundary-20260918"
CONTROL_SOURCE_SHA = "0e8987577c5d5860ca55cdff4e1943bc22ff67e9"
MACHINE = "DESKTOP-10SKF0M"
SERVICE = r"NT SERVICE\AFZHermesVerifier"
SID = "S-1-5-80-123456789-234567890-345678901-456789012-567890123"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args: str) -> str:
    process = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return process.stdout.strip()


def main() -> int:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((ROOT / "VENDOR-MANIFEST.json").read_text(encoding="utf-8"))
    expected_vendor = manifest["source"]["files"]
    observed_vendor = {name: digest(ROOT / name) for name in expected_vendor}
    if observed_vendor != expected_vendor:
        raise RuntimeError("vendored R3 hash mismatch")

    suite = ET.parse(EVIDENCE / "full-suite.xml").getroot()
    cases = list(suite.iter("testcase"))
    failures = sum(case.find("failure") is not None for case in cases)
    errors = sum(case.find("error") is not None for case in cases)
    skipped = sum(case.find("skipped") is not None for case in cases)
    vendor_cases = sum("vendor" in str(case.get("classname", "")) for case in cases)
    authenticated_cases = sum(
        "test_authenticated_verifier" in str(case.get("classname", ""))
        for case in cases
    )
    if (
        len(cases),
        vendor_cases,
        authenticated_cases,
        failures,
        errors,
        skipped,
    ) != (105, 54, 27, 0, 0, 0):
        raise RuntimeError("test evidence count mismatch")
    for name in (
        "full-suite",
        "ruff-check",
        "ruff-format",
        "compileall",
        "clean-install",
        "clean-import",
        "clean-installed-packages",
    ):
        if (EVIDENCE / f"{name}.exit.txt").read_text(encoding="utf-8").strip() != "0":
            raise RuntimeError(f"{name} exit mismatch")

    packages = json.loads(
        (EVIDENCE / "clean-installed-packages.json").read_text(encoding="utf-8")
    )
    versions = {item["name"]: item["version"] for item in packages}
    cryptography_version = versions.get("cryptography")
    if not cryptography_version:
        raise RuntimeError("clean environment omitted cryptography")

    signer = TestOnlySigner()
    expected = ReceiptExpectations(
        packet_sha256="1" * 64,
        source_sha256="2" * 64,
        target_identity="windows-main@100.70.25.8:8797",
        recipe="control-health-readonly-v1",
        control_hub_source_sha=CONTROL_SOURCE_SHA,
        fresh_read_sha256="3" * 64,
        authorization_binding_sha256="4" * 64,
    )
    claims = build_receipt_claims(
        expectations=expected,
        verifier_machine_identity=MACHINE,
        verifier_service_identity=SERVICE,
        verifier_service_sid=SID,
        signer_thumbprint=signer.thumbprint,
        signer_key_id=signer.key_id,
        signature_algorithm=signer.algorithm,
        signer_provider=signer.provider_kind,
        issued_unix=1_999,
        expires_unix=2_060,
        nonce="public-fixture-nonce-000000000000",
    )
    document = sign_receipt(claims, signer)
    trust = SignerTrustPolicy(
        signer_thumbprint=signer.thumbprint,
        signer_key_id=signer.key_id,
        signature_algorithm=signer.algorithm,
        certificate_pem=signer.certificate_pem,
        provider_kind=signer.provider_kind,
        test_only=True,
        verifier_machine_identity=MACHINE,
        verifier_service_identity=SERVICE,
        verifier_service_sid=SID,
    )
    install = InstallationPolicy(
        verifier_machine_identity=MACHINE,
        verifier_service_identity=SERVICE,
        verifier_service_sid=SID,
        service_name="AFZHermesVerifier",
        runtime_path=r"C:\Program Files\AFZ\HermesVerifier\afz-hermes-verifier.exe",
        ipc_contract="npipe://./pipe/afz-hermes-verifier-v1",
        signer_thumbprint=signer.thumbprint,
        signer_key_id=signer.key_id,
        installed_source_sha256="5" * 64,
    )
    with tempfile.TemporaryDirectory(prefix="afz-auth-verifier-evidence-") as temporary:
        verified = verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(Path(temporary) / "nonces.sqlite3"),
            now_unix=2_000,
            installation_policy=install,
        )
    if verified.authenticated or verified.authenticated_review_gate != "NOT_VERIFIED":
        raise RuntimeError("test signer incorrectly unlocked authentication")

    certificate_path = EVIDENCE / "TEST_ONLY-public-certificate.pem"
    receipt_path = EVIDENCE / "TEST_ONLY-signed-receipt.json"
    certificate_path.write_text(signer.certificate_pem, encoding="ascii")
    receipt_path.write_text(
        json.dumps(document, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )

    implementation_head = git("rev-parse", "HEAD")
    artifact_paths = [
        EVIDENCE / "baseline-78.xml",
        EVIDENCE / "full-suite.xml",
        EVIDENCE / "full-suite.stdout.txt",
        EVIDENCE / "clean-installed-packages.json",
        EVIDENCE / "ruff-check.stdout.txt",
        EVIDENCE / "ruff-format.stdout.txt",
        certificate_path,
        receipt_path,
    ]
    result = {
        "schema": "afz-authenticated-verifier-boundary-result-v1",
        "generated_utc": datetime.now(UTC).isoformat(),
        "status": "HELD_FOR_INDEPENDENT_REVIEW",
        "base_head": BASE_HEAD,
        "implementation_head": implementation_head,
        "branch": BRANCH,
        "tests": {
            "baseline": 78,
            "total": len(cases),
            "vendored_r3": vendor_cases,
            "authenticated_verifier": authenticated_cases,
            "failures": failures,
            "errors": errors,
            "skipped": skipped,
            "exit": 0,
        },
        "quality": {
            "ruff_check_exit": 0,
            "ruff_format_exit": 0,
            "compileall_exit": 0,
            "clean_install_exit": 0,
            "clean_import_exit": 0,
            "cryptography_version": cryptography_version,
        },
        "trust": {
            "signature_integrity_verified": True,
            "signer_provider": TEST_ONLY_LABEL,
            "test_signer_certificate_sha256": signer.thumbprint,
            "installation_contract_matches": False,
            "installation_attestation_verified": False,
            "authenticated": False,
            "authenticated_review_gate": "NOT_VERIFIED",
            "production_enforced": False,
            "cross_host_enabled": False,
        },
        "r3_fidelity": {"verified": True, "files": observed_vendor},
        "live_control_hub_calls": 0,
        "config_changes": 0,
        "service_changes": 0,
        "certificate_store_changes": 0,
        "artifact_sha256": {
            str(path.relative_to(ROOT)).replace("\\", "/"): digest(path)
            for path in artifact_paths
        },
    }
    (ROOT / "AUTH-VERIFIER-RESULT.json").write_text(
        json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    report = f"""# Authenticated verifier boundary report

STATUS: HELD_FOR_INDEPENDENT_REVIEW

IMPLEMENTED: Canonical signed receipts, pinned public-certificate verification,
fixed Windows LocalMachine/CNG provider contract, test-only signer, and atomic
SQLite nonce replay defense. Installation and rollback remain plan-only.

VERIFIED: {len(cases)} passed, 0 failed/errors/skipped; baseline 78 preserved;
Ruff check/format and compileall exit 0; clean install/import exit 0 with
cryptography {cryptography_version}; vendored R3 hashes unchanged.

NOT VERIFIED: No Windows service identity, machine key, key ACL/non-exportability,
protected runtime, or separately anchored provisioning/admin attestation was
installed or proven. authenticated=false and authenticated_review_gate=NOT_VERIFIED.

BLOCKER: Independent review plus a separately authorized privileged installation
and cryptographically anchored installation-attestation design are required.

NEXT: Review this stacked draft only. Do not merge, install, deploy, enroll, or
production-enable from this report.

BRANCH: {BRANCH}
BASE: {BASE_HEAD}
IMPLEMENTATION COMMIT: {implementation_head}
DRAFT PR: pending creation
TEST COUNTS+EXITS: 105 passed; 0 failed/errors/skipped; pytest/Ruff/format/compileall 0
HASHES: R3 core {observed_vendor["src/afz_autopilot/core.py"]}; test certificate {signer.thumbprint}
CONFIG+LIVE CHANGES: 0; Control Hub calls: 0
ROLLBACK: close the draft PR and delete the feature branch; no runtime rollback required
RESUME KEY: AFZ-HERMES-AUTOPILOT-AUTH-VERIFIER-20260918
"""
    (ROOT / "AUTH-VERIFIER-REPORT.md").write_text(report, encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
