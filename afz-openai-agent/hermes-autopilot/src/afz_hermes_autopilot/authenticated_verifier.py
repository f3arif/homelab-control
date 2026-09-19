"""Offline signed-receipt boundary for a future Windows verifier service.

This module verifies detached signatures and durable nonces.  It does not install
or attest a Windows service, access a certificate private key, or make network
calls.  A verified signature is deliberately insufficient for authentication:
the gate also requires a matching installation attestation and a trust policy
for a non-test Windows LocalMachine/CNG signer.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import sqlite3
from collections.abc import Mapping
from contextlib import closing
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ALGORITHM = "ECDSA_P256_SHA256"
WINDOWS_PROVIDER = "WINDOWS_LOCAL_MACHINE_CNG"
TEST_ONLY_PROVIDER = "TEST_ONLY_NOT_OS_BOUNDARY"
RECEIPT_SCHEMA = "afz-authenticated-verifier-receipt-v1"
INSTALLATION_SCHEMA = "afz-windows-verifier-installation-attestation-v1"
MAX_RECEIPT_TTL_SECONDS = 300
MAX_FUTURE_SKEW_SECONDS = 0
_SHA40 = re.compile(r"[0-9a-f]{40}")
_SHA64 = re.compile(r"[0-9a-f]{64}")
_NONCE = re.compile(r"[A-Za-z0-9_-]{32,128}")
_SID = re.compile(r"S-1-(?:[0-9]+-)+[0-9]+")


class ReceiptVerificationError(RuntimeError):
    """A signed receipt failed closed."""


class ReplayDetected(ReceiptVerificationError):
    """The receipt nonce was already consumed."""


class InstallationContractError(ReceiptVerificationError):
    """A supplied installation claim did not match the fixed contract."""


@runtime_checkable
class SigningProvider(Protocol):
    """Signer interface; production implementations keep private keys outside Python."""

    algorithm: str
    key_id: str
    thumbprint: str
    provider_kind: str
    test_only: bool

    def sign(self, payload: bytes) -> bytes:
        """Sign canonical receipt bytes without exposing private key material."""


@dataclass(frozen=True)
class WindowsMachineCertificateProviderConfig:
    """Private-key-free contract for a future machine-certificate provider."""

    pinned_thumbprint: str
    key_id: str
    verifier_service_identity: str
    verifier_service_sid: str
    store_location: str = field(default="LocalMachine", init=False)
    store_name: str = field(default="My", init=False)
    key_provider: str = field(default="WindowsCNG", init=False)
    provider_kind: str = field(default=WINDOWS_PROVIDER, init=False)
    require_non_exportable_key: bool = field(default=True, init=False)

    def __post_init__(self) -> None:
        if not _SHA64.fullmatch(self.pinned_thumbprint):
            raise ValueError("pinned thumbprint must be a lowercase SHA-256")
        if not self.key_id.strip():
            raise ValueError("key id is required")
        if not self.verifier_service_identity.startswith("NT SERVICE\\"):
            raise ValueError("dedicated NT SERVICE identity is required")
        if not _SID.fullmatch(self.verifier_service_sid):
            raise ValueError("service SID is malformed")

    @classmethod
    def from_mapping(
        cls, value: Mapping[str, Any]
    ) -> WindowsMachineCertificateProviderConfig:
        allowed = {
            "pinned_thumbprint",
            "key_id",
            "verifier_service_identity",
            "verifier_service_sid",
        }
        if not isinstance(value, Mapping):
            raise TypeError("provider config must be a mapping")
        unsupported = set(value) - allowed
        missing = allowed - set(value)
        if unsupported:
            raise ValueError(
                "unsupported provider config fields: " + ", ".join(sorted(unsupported))
            )
        if missing:
            raise ValueError(
                "missing provider config fields: " + ", ".join(sorted(missing))
            )
        return cls(**{name: value[name] for name in allowed})


class WindowsMachineCertificateSigningProvider(SigningProvider, Protocol):
    """Future provider contract for LocalMachine/CNG signing by thumbprint."""

    config: WindowsMachineCertificateProviderConfig


@dataclass(frozen=True)
class ReceiptExpectations:
    packet_sha256: str
    source_sha256: str
    target_identity: str
    recipe: str
    control_hub_source_sha: str
    fresh_read_sha256: str
    authorization_binding_sha256: str

    def __post_init__(self) -> None:
        for name in (
            "packet_sha256",
            "source_sha256",
            "fresh_read_sha256",
            "authorization_binding_sha256",
        ):
            if not _SHA64.fullmatch(getattr(self, name)):
                raise ValueError(f"{name} must be a lowercase SHA-256")
        if not _SHA40.fullmatch(self.control_hub_source_sha):
            raise ValueError("control_hub_source_sha must be a lowercase SHA-1")
        if not self.target_identity or not self.recipe:
            raise ValueError("target identity and recipe are required")


@dataclass(frozen=True)
class SignerTrustPolicy:
    signer_thumbprint: str
    signer_key_id: str
    signature_algorithm: str
    certificate_pem: str
    provider_kind: str
    test_only: bool
    verifier_machine_identity: str
    verifier_service_identity: str
    verifier_service_sid: str


@dataclass(frozen=True)
class InstallationPolicy:
    verifier_machine_identity: str
    verifier_service_identity: str
    verifier_service_sid: str
    service_name: str
    runtime_path: str
    ipc_contract: str
    signer_thumbprint: str
    signer_key_id: str
    installed_source_sha256: str


@dataclass(frozen=True)
class VerificationResult:
    integrity_verified: bool
    authenticated: bool
    authenticated_review_gate: str
    installation_contract_matches: bool
    installation_attestation_verified: bool
    signer_provider: str
    receipt_sha256: str
    nonce: str
    production_enforced: bool = False
    cross_host_enabled: bool = False


def canonical_json_bytes(value: Any) -> bytes:
    """Return the one signed JSON representation used by this boundary."""

    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def build_receipt_claims(
    *,
    expectations: ReceiptExpectations,
    verifier_machine_identity: str,
    verifier_service_identity: str,
    verifier_service_sid: str,
    signer_thumbprint: str,
    signer_key_id: str,
    signature_algorithm: str,
    signer_provider: str,
    issued_unix: int,
    expires_unix: int,
    nonce: str,
) -> dict[str, Any]:
    """Build versioned claims; the detached signature covers this entire object."""

    return {
        "schema": RECEIPT_SCHEMA,
        "packet_sha256": expectations.packet_sha256,
        "source_sha256": expectations.source_sha256,
        "target_identity": expectations.target_identity,
        "recipe": expectations.recipe,
        "control_hub_source_sha": expectations.control_hub_source_sha,
        "fresh_read_sha256": expectations.fresh_read_sha256,
        "fresh_read_attestation": "fixed-recipe-contract-revalidated",
        "authorization_binding_sha256": expectations.authorization_binding_sha256,
        "verifier_machine_identity": verifier_machine_identity,
        "verifier_service_identity": verifier_service_identity,
        "verifier_service_sid": verifier_service_sid,
        "signer_thumbprint": signer_thumbprint,
        "signer_key_id": signer_key_id,
        "signature_algorithm": signature_algorithm,
        "signer_provider": signer_provider,
        "issued_unix": issued_unix,
        "expires_unix": expires_unix,
        "nonce": nonce,
        "production_enforced": False,
        "cross_host_enabled": False,
    }


def sign_receipt(claims: Mapping[str, Any], signer: SigningProvider) -> dict[str, Any]:
    """Create a detached signature document using an injected provider."""

    receipt = dict(claims)
    provider_bindings = {
        "signer_thumbprint": signer.thumbprint,
        "signer_key_id": signer.key_id,
        "signature_algorithm": signer.algorithm,
        "signer_provider": signer.provider_kind,
    }
    if any(receipt.get(name) != value for name, value in provider_bindings.items()):
        raise ValueError("receipt signer fields do not match signing provider")
    signature = signer.sign(canonical_json_bytes(receipt))
    if not isinstance(signature, bytes) or not signature:
        raise ValueError("signing provider returned an invalid signature")
    return {
        "receipt": receipt,
        "signature_base64": base64.b64encode(signature).decode("ascii"),
    }


class NonceLedger:
    """SQLite replay ledger with one atomic insert per accepted nonce."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(self.path, timeout=30)) as db:
            db.execute(
                """CREATE TABLE IF NOT EXISTS verifier_nonces (
                    nonce TEXT PRIMARY KEY,
                    receipt_sha256 TEXT NOT NULL,
                    consumed_unix INTEGER NOT NULL,
                    expires_unix INTEGER NOT NULL
                )"""
            )
            db.commit()

    def consume(
        self, *, nonce: str, receipt_sha256: str, now_unix: int, expires_unix: int
    ) -> None:
        try:
            with closing(sqlite3.connect(self.path, timeout=30)) as db, db:
                db.execute("BEGIN IMMEDIATE")
                db.execute(
                    """INSERT INTO verifier_nonces(
                        nonce,receipt_sha256,consumed_unix,expires_unix
                    ) VALUES(?,?,?,?)""",
                    (nonce, receipt_sha256, now_unix, expires_unix),
                )
        except sqlite3.IntegrityError as error:
            raise ReplayDetected("receipt nonce replay detected") from error


def _load_pinned_certificate(
    policy: SignerTrustPolicy, *, now_unix: int
) -> x509.Certificate:
    if "PRIVATE KEY" in policy.certificate_pem:
        raise ReceiptVerificationError(
            "signer policy must contain only a public certificate"
        )
    try:
        certificate = x509.load_pem_x509_certificate(
            policy.certificate_pem.encode("ascii")
        )
    except (ValueError, UnicodeEncodeError) as error:
        raise ReceiptVerificationError("signer certificate is malformed") from error
    if not isinstance(now_unix, int) or isinstance(now_unix, bool):
        raise ReceiptVerificationError("verification time is malformed")
    if now_unix < certificate.not_valid_before_utc.timestamp():
        raise ReceiptVerificationError("signer certificate is not yet valid")
    if now_unix > certificate.not_valid_after_utc.timestamp():
        raise ReceiptVerificationError("signer certificate is expired")
    actual_thumbprint = hashlib.sha256(
        certificate.public_bytes(serialization.Encoding.DER)
    ).hexdigest()
    if actual_thumbprint != policy.signer_thumbprint:
        raise ReceiptVerificationError("pinned signer thumbprint mismatch")
    public_key = certificate.public_key()
    if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(
        public_key.curve, ec.SECP256R1
    ):
        raise ReceiptVerificationError("signer public key must be ECDSA P-256")
    return certificate


_RECEIPT_KEYS = {
    "schema",
    "packet_sha256",
    "source_sha256",
    "target_identity",
    "recipe",
    "control_hub_source_sha",
    "fresh_read_sha256",
    "fresh_read_attestation",
    "authorization_binding_sha256",
    "verifier_machine_identity",
    "verifier_service_identity",
    "verifier_service_sid",
    "signer_thumbprint",
    "signer_key_id",
    "signature_algorithm",
    "signer_provider",
    "issued_unix",
    "expires_unix",
    "nonce",
    "production_enforced",
    "cross_host_enabled",
}


def validate_installation_contract(
    attestation: Mapping[str, Any], policy: InstallationPolicy
) -> None:
    """Match claimed fields only; this is not an OS installation attestation."""

    expected = {
        "schema": INSTALLATION_SCHEMA,
        "verifier_machine_identity": policy.verifier_machine_identity,
        "verifier_service_identity": policy.verifier_service_identity,
        "verifier_service_sid": policy.verifier_service_sid,
        "service_name": policy.service_name,
        "runtime_path": policy.runtime_path,
        "ipc_contract": policy.ipc_contract,
        "certificate_store_location": "LocalMachine",
        "certificate_store_name": "My",
        "key_provider": "WindowsCNG",
        "key_non_exportable": True,
        "private_key_acl_sid": policy.verifier_service_sid,
        "protected_runtime": True,
        "signer_thumbprint": policy.signer_thumbprint,
        "signer_key_id": policy.signer_key_id,
        "installed_source_sha256": policy.installed_source_sha256,
        "production_enforced": False,
        "cross_host_enabled": False,
    }
    if not isinstance(attestation, Mapping) or dict(attestation) != expected:
        raise InstallationContractError(
            "installation contract does not match fixed policy"
        )


def verify_signed_receipt(
    document: Any,
    *,
    expected: ReceiptExpectations,
    signer_policy: SignerTrustPolicy,
    nonce_ledger: NonceLedger,
    now_unix: int,
    installation_policy: InstallationPolicy,
    installation_attestation: Mapping[str, Any] | None = None,
) -> VerificationResult:
    """Verify signature/integrity, consume nonce, and evaluate the honest gate."""

    if not isinstance(document, Mapping) or set(document) != {
        "receipt",
        "signature_base64",
    }:
        raise ReceiptVerificationError(
            "signed receipt document is malformed or unsigned"
        )
    receipt = document.get("receipt")
    signature_text = document.get("signature_base64")
    if not isinstance(receipt, Mapping) or set(receipt) != _RECEIPT_KEYS:
        raise ReceiptVerificationError("receipt fields are malformed")
    if not isinstance(signature_text, str):
        raise ReceiptVerificationError("detached signature is missing")
    receipt = dict(receipt)

    if receipt["signature_algorithm"] != ALGORITHM:
        raise ReceiptVerificationError("unknown signature algorithm")
    signer_bindings = {
        "signer_thumbprint": signer_policy.signer_thumbprint,
        "signer_key_id": signer_policy.signer_key_id,
        "signature_algorithm": signer_policy.signature_algorithm,
        "signer_provider": signer_policy.provider_kind,
        "verifier_machine_identity": signer_policy.verifier_machine_identity,
        "verifier_service_identity": signer_policy.verifier_service_identity,
        "verifier_service_sid": signer_policy.verifier_service_sid,
    }
    if any(receipt.get(name) != value for name, value in signer_bindings.items()):
        raise ReceiptVerificationError("receipt signer policy binding mismatch")
    certificate = _load_pinned_certificate(signer_policy, now_unix=now_unix)
    try:
        signature = base64.b64decode(signature_text, validate=True)
        certificate.public_key().verify(
            signature,
            canonical_json_bytes(receipt),
            ec.ECDSA(hashes.SHA256()),
        )
    except (binascii.Error, InvalidSignature, ValueError) as error:
        raise ReceiptVerificationError(
            "detached receipt signature is invalid"
        ) from error

    expected_bindings = {
        "schema": RECEIPT_SCHEMA,
        "packet_sha256": expected.packet_sha256,
        "source_sha256": expected.source_sha256,
        "target_identity": expected.target_identity,
        "recipe": expected.recipe,
        "control_hub_source_sha": expected.control_hub_source_sha,
        "fresh_read_sha256": expected.fresh_read_sha256,
        "fresh_read_attestation": "fixed-recipe-contract-revalidated",
        "authorization_binding_sha256": expected.authorization_binding_sha256,
    }
    if any(receipt.get(name) != value for name, value in expected_bindings.items()):
        raise ReceiptVerificationError(
            "receipt packet/readback/authorization binding mismatch"
        )
    if receipt["production_enforced"] is not False:
        raise ReceiptVerificationError(
            "receipt cannot self-assert production enforcement"
        )
    if receipt["cross_host_enabled"] is not False:
        raise ReceiptVerificationError(
            "receipt cannot self-assert cross-host enablement"
        )

    issued = receipt["issued_unix"]
    expires = receipt["expires_unix"]
    if (
        not isinstance(issued, int)
        or isinstance(issued, bool)
        or not isinstance(expires, int)
        or isinstance(expires, bool)
        or not isinstance(now_unix, int)
        or isinstance(now_unix, bool)
    ):
        raise ReceiptVerificationError("receipt timestamps are malformed")
    if issued > now_unix + MAX_FUTURE_SKEW_SECONDS:
        raise ReceiptVerificationError("receipt was issued in the future")
    if expires <= now_unix:
        raise ReceiptVerificationError("receipt is expired")
    if expires <= issued or expires - issued > MAX_RECEIPT_TTL_SECONDS:
        raise ReceiptVerificationError("receipt validity interval is invalid")
    nonce = receipt["nonce"]
    if not isinstance(nonce, str) or not _NONCE.fullmatch(nonce):
        raise ReceiptVerificationError("receipt nonce is malformed")

    installation_contract_matches = False
    if installation_attestation is not None:
        validate_installation_contract(installation_attestation, installation_policy)
        installation_contract_matches = True

    receipt_sha256 = hashlib.sha256(canonical_json_bytes(receipt)).hexdigest()
    nonce_ledger.consume(
        nonce=nonce,
        receipt_sha256=receipt_sha256,
        now_unix=now_unix,
        expires_unix=expires,
    )
    # Field equality cannot prove the OS token, key ACL/export policy, service
    # binary, or protected runtime.  This candidate has no separately anchored
    # provisioning/admin attestor, so it must never assert authentication.
    authenticated = False
    return VerificationResult(
        integrity_verified=True,
        authenticated=authenticated,
        authenticated_review_gate=("VERIFIED" if authenticated else "NOT_VERIFIED"),
        installation_contract_matches=installation_contract_matches,
        installation_attestation_verified=False,
        signer_provider=signer_policy.provider_kind,
        receipt_sha256=receipt_sha256,
        nonce=nonce,
    )
