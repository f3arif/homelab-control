"""Acceptance tests for the authenticated verifier boundary candidate."""

from __future__ import annotations

import copy
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path

import pytest
from support.test_only_signer import TEST_ONLY_LABEL, TestOnlySigner

from afz_hermes_autopilot.authenticated_verifier import (
    InstallationContractError,
    InstallationPolicy,
    NonceLedger,
    ReceiptExpectations,
    ReceiptVerificationError,
    ReplayDetected,
    SignerTrustPolicy,
    WindowsMachineCertificateProviderConfig,
    build_receipt_claims,
    sign_receipt,
    validate_installation_contract,
    verify_signed_receipt,
)

SHA_PACKET = "1" * 64
SHA_SOURCE = "2" * 64
SHA_FRESH = "3" * 64
SHA_AUTH = "4" * 64
SHA_RUNTIME = "5" * 64
MACHINE = "DESKTOP-10SKF0M"
SERVICE = r"NT SERVICE\AFZHermesVerifier"
SID = "S-1-5-80-123456789-234567890-345678901-456789012-567890123"
RUNTIME = r"C:\Program Files\AFZ\HermesVerifier\afz-hermes-verifier.exe"
IPC = r"npipe://./pipe/afz-hermes-verifier-v1"


def make_case(
    tmp_path: Path,
    *,
    nonce: str = "n" * 32,
    now: int = 2_000,
    signer: TestOnlySigner | None = None,
):
    signer = signer or TestOnlySigner()
    expected = ReceiptExpectations(
        packet_sha256=SHA_PACKET,
        source_sha256=SHA_SOURCE,
        target_identity="windows-main@100.70.25.8:8797",
        recipe="control-health-readonly-v1",
        control_hub_source_sha="0e8987577c5d5860ca55cdff4e1943bc22ff67e9",
        fresh_read_sha256=SHA_FRESH,
        authorization_binding_sha256=SHA_AUTH,
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
        issued_unix=now - 1,
        expires_unix=now + 60,
        nonce=nonce,
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
    install_policy = InstallationPolicy(
        verifier_machine_identity=MACHINE,
        verifier_service_identity=SERVICE,
        verifier_service_sid=SID,
        service_name="AFZHermesVerifier",
        runtime_path=RUNTIME,
        ipc_contract=IPC,
        signer_thumbprint=signer.thumbprint,
        signer_key_id=signer.key_id,
        installed_source_sha256=SHA_RUNTIME,
    )
    attestation = {
        "schema": "afz-windows-verifier-installation-attestation-v1",
        "verifier_machine_identity": MACHINE,
        "verifier_service_identity": SERVICE,
        "verifier_service_sid": SID,
        "service_name": "AFZHermesVerifier",
        "runtime_path": RUNTIME,
        "ipc_contract": IPC,
        "certificate_store_location": "LocalMachine",
        "certificate_store_name": "My",
        "key_provider": "WindowsCNG",
        "key_non_exportable": True,
        "private_key_acl_sid": SID,
        "protected_runtime": True,
        "signer_thumbprint": signer.thumbprint,
        "signer_key_id": signer.key_id,
        "installed_source_sha256": SHA_RUNTIME,
        "production_enforced": False,
        "cross_host_enabled": False,
    }
    return signer, expected, document, trust, install_policy, attestation, now


def verify_case(tmp_path: Path, *, nonce: str = "n" * 32, attestation=None):
    _, expected, document, trust, install_policy, default_attestation, now = make_case(
        tmp_path, nonce=nonce
    )
    return verify_signed_receipt(
        document,
        expected=expected,
        signer_policy=trust,
        nonce_ledger=NonceLedger(tmp_path / "nonce.sqlite3"),
        now_unix=now,
        installation_policy=install_policy,
        installation_attestation=(
            default_attestation if attestation == "default" else attestation
        ),
    )


def test_test_only_signed_receipt_validates_but_gate_remains_not_verified(
    tmp_path: Path,
) -> None:
    result = verify_case(tmp_path)

    assert result.integrity_verified is True
    assert result.authenticated is False
    assert result.authenticated_review_gate == "NOT_VERIFIED"
    assert result.signer_provider == TEST_ONLY_LABEL
    assert result.installation_attestation_verified is False
    assert result.installation_contract_matches is False


@pytest.mark.parametrize(
    "field,value",
    [
        ("packet_sha256", "a" * 64),
        ("fresh_read_sha256", "b" * 64),
        ("authorization_binding_sha256", "c" * 64),
        ("source_sha256", "d" * 64),
    ],
)
def test_tampered_signed_binding_fails_closed(
    tmp_path: Path, field: str, value: str
) -> None:
    _, expected, document, trust, install_policy, _, now = make_case(tmp_path)
    document["receipt"][field] = value

    with pytest.raises(ReceiptVerificationError, match="signature"):
        verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(tmp_path / "nonce.sqlite3"),
            now_unix=now,
            installation_policy=install_policy,
        )


@pytest.mark.parametrize("changed", ["key_id", "thumbprint", "signer", "algorithm"])
def test_wrong_signer_key_thumbprint_or_algorithm_fails_closed(
    tmp_path: Path, changed: str
) -> None:
    signer, expected, document, trust, install_policy, _, now = make_case(tmp_path)
    if changed == "key_id":
        trust = replace(trust, signer_key_id="wrong-key")
    elif changed == "thumbprint":
        trust = replace(trust, signer_thumbprint="a" * 64)
    elif changed == "signer":
        other = TestOnlySigner(key_id=signer.key_id)
        trust = replace(
            trust,
            certificate_pem=other.certificate_pem,
            signer_thumbprint=other.thumbprint,
        )
    else:
        document["receipt"]["signature_algorithm"] = "UNKNOWN_ALGORITHM"

    with pytest.raises(ReceiptVerificationError):
        verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(tmp_path / "nonce.sqlite3"),
            now_unix=now,
            installation_policy=install_policy,
        )


@pytest.mark.parametrize(
    "issued,expires,error", [(2001, 2060, "future"), (1900, 1999, "expired")]
)
def test_future_and_expired_receipts_fail_closed(
    tmp_path: Path, issued: int, expires: int, error: str
) -> None:
    signer, expected, _, trust, install_policy, _, now = make_case(tmp_path)
    claims = build_receipt_claims(
        expectations=expected,
        verifier_machine_identity=MACHINE,
        verifier_service_identity=SERVICE,
        verifier_service_sid=SID,
        signer_thumbprint=signer.thumbprint,
        signer_key_id=signer.key_id,
        signature_algorithm=signer.algorithm,
        signer_provider=signer.provider_kind,
        issued_unix=issued,
        expires_unix=expires,
        nonce="t" * 32,
    )
    document = sign_receipt(claims, signer)

    with pytest.raises(ReceiptVerificationError, match=error):
        verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(tmp_path / "nonce.sqlite3"),
            now_unix=now,
            installation_policy=install_policy,
        )


@pytest.mark.parametrize(
    "signer,error",
    [
        (TestOnlySigner(not_before_unix=2_001, not_after_unix=3_000), "not yet valid"),
        (TestOnlySigner(not_before_unix=1_000, not_after_unix=1_999), "expired"),
    ],
)
def test_signing_certificate_must_be_valid_at_verification_time(
    tmp_path: Path, signer: TestOnlySigner, error: str
) -> None:
    _, expected, document, trust, install_policy, _, now = make_case(
        tmp_path, signer=signer
    )

    ledger_path = tmp_path / "nonce.sqlite3"
    with pytest.raises(ReceiptVerificationError, match=error):
        verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(ledger_path),
            now_unix=now,
            installation_policy=install_policy,
        )
    with sqlite3.connect(ledger_path) as db:
        assert db.execute("SELECT COUNT(*) FROM verifier_nonces").fetchone()[0] == 0


def test_nonce_replay_is_durable_and_atomic_under_concurrent_verification(
    tmp_path: Path,
) -> None:
    _, expected, document, trust, install_policy, _, now = make_case(tmp_path)
    ledger_path = tmp_path / "nonce.sqlite3"

    def attempt(_: int) -> str:
        try:
            verify_signed_receipt(
                copy.deepcopy(document),
                expected=expected,
                signer_policy=trust,
                nonce_ledger=NonceLedger(ledger_path),
                now_unix=now,
                installation_policy=install_policy,
            )
            return "accepted"
        except ReplayDetected:
            return "replayed"

    with ThreadPoolExecutor(max_workers=8) as pool:
        outcomes = list(pool.map(attempt, range(8)))

    assert outcomes.count("accepted") == 1
    assert outcomes.count("replayed") == 7
    with sqlite3.connect(ledger_path) as db:
        assert db.execute("SELECT COUNT(*) FROM verifier_nonces").fetchone()[0] == 1
    with pytest.raises(ReplayDetected):
        verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(ledger_path),
            now_unix=now,
            installation_policy=install_policy,
        )


@pytest.mark.parametrize(
    "forbidden",
    ["private_key", "private_key_path", "private_key_env", "private_key_body"],
)
def test_production_provider_config_rejects_worker_controlled_private_key_inputs(
    forbidden: str,
) -> None:
    config = {
        "pinned_thumbprint": "a" * 64,
        "key_id": "afz-hermes-verifier-prod-v1",
        "verifier_service_identity": SERVICE,
        "verifier_service_sid": SID,
        forbidden: "worker-controlled-secret-material",
    }
    with pytest.raises(ValueError, match="unsupported"):
        WindowsMachineCertificateProviderConfig.from_mapping(config)


def test_production_provider_contract_is_fixed_to_local_machine_cng() -> None:
    config = WindowsMachineCertificateProviderConfig.from_mapping(
        {
            "pinned_thumbprint": "a" * 64,
            "key_id": "afz-hermes-verifier-prod-v1",
            "verifier_service_identity": SERVICE,
            "verifier_service_sid": SID,
        }
    )

    assert config.store_location == "LocalMachine"
    assert config.store_name == "My"
    assert config.key_provider == "WindowsCNG"
    assert config.require_non_exportable_key is True


def test_worker_supplied_contract_cannot_unlock_authentication(
    tmp_path: Path,
) -> None:
    absent = verify_case(tmp_path, nonce="a" * 32)
    present = verify_case(tmp_path, nonce="b" * 32, attestation="default")

    assert absent.authenticated is False
    assert absent.installation_attestation_verified is False
    assert absent.installation_contract_matches is False
    assert present.installation_contract_matches is True
    assert present.installation_attestation_verified is False
    assert present.authenticated is False
    assert present.authenticated_review_gate == "NOT_VERIFIED"


@pytest.mark.parametrize(
    "field,value",
    [
        ("verifier_machine_identity", "OTHER-MACHINE"),
        ("verifier_service_identity", r"NT SERVICE\Other"),
        ("verifier_service_sid", "S-1-5-80-999"),
        ("key_non_exportable", False),
        ("signer_thumbprint", "f" * 64),
    ],
)
def test_installation_attestation_tampering_fails(
    tmp_path: Path, field: str, value: object
) -> None:
    _, _, _, _, policy, attestation, _ = make_case(tmp_path)
    attestation[field] = value

    with pytest.raises(InstallationContractError):
        validate_installation_contract(attestation, policy)


def test_receipt_cannot_self_assert_production_enforcement(tmp_path: Path) -> None:
    signer, expected, document, trust, install_policy, _, now = make_case(tmp_path)
    claims = dict(document["receipt"])
    claims["production_enforced"] = True
    document = sign_receipt(claims, signer)

    with pytest.raises(ReceiptVerificationError, match="production enforcement"):
        verify_signed_receipt(
            document,
            expected=expected,
            signer_policy=trust,
            nonce_ledger=NonceLedger(tmp_path / "nonce.sqlite3"),
            now_unix=now,
            installation_policy=install_policy,
        )


def test_unsigned_and_malformed_receipts_fail_closed(tmp_path: Path) -> None:
    _, expected, document, trust, install_policy, _, now = make_case(tmp_path)
    for malformed in ({"receipt": document["receipt"]}, [], {"signature": "%%%"}):
        with pytest.raises(ReceiptVerificationError):
            verify_signed_receipt(
                malformed,
                expected=expected,
                signer_policy=trust,
                nonce_ledger=NonceLedger(tmp_path / "nonce.sqlite3"),
                now_unix=now,
                installation_policy=install_policy,
            )
