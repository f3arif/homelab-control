"""Ephemeral signer fixture; never an OS authentication boundary."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

TEST_ONLY_LABEL = "TEST_ONLY_NOT_OS_BOUNDARY"


class TestOnlySigner:
    """In-memory test key that can never qualify as a production signer."""

    __test__ = False
    algorithm = "ECDSA_P256_SHA256"
    provider_kind = TEST_ONLY_LABEL
    test_only = True

    def __init__(
        self,
        *,
        key_id: str = "test-fixture-key-v1",
        not_before_unix: int = 1_000,
        not_after_unix: int = 3_000,
    ) -> None:
        self.key_id = key_id
        self._key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, TEST_ONLY_LABEL)])
        not_before = datetime.fromtimestamp(not_before_unix, UTC)
        not_after = datetime.fromtimestamp(not_after_unix, UTC)
        self._certificate = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(self._key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(not_before)
            .not_valid_after(not_after)
            .sign(self._key, hashes.SHA256())
        )
        self.certificate_pem = self._certificate.public_bytes(
            serialization.Encoding.PEM
        ).decode("ascii")
        self.thumbprint = hashlib.sha256(
            self._certificate.public_bytes(serialization.Encoding.DER)
        ).hexdigest()

    def sign(self, payload: bytes) -> bytes:
        return self._key.sign(payload, ec.ECDSA(hashes.SHA256()))
