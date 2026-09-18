import pathlib
import sys
import unittest
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from radiohilal_writer_lease import (
    LeaseError, LeaseRequest, acquire, release, renew, validate_for_deploy,
    RESOURCE, TTL_DEFAULT,
)

SHA = "1e167c37e7ee0d8ae9871b71b0bc9179560b7c7b"
NOW = datetime(2026, 9, 18, 22, 40, tzinfo=timezone.utc)

def req(owner="DESKTOP-H3R6CQN", nonce="rh-test-0001", ttl=TTL_DEFAULT,
        safe=True, fence=True, sha=SHA):
    return LeaseRequest(owner, sha, nonce, ttl, safe, fence)

class WriterLeaseTests(unittest.TestCase):
    def test_acquire_valid(self):
        r = acquire(None, req(), NOW)
        self.assertTrue(r.acquired)
        self.assertEqual(r.lease.resource, RESOURCE)
        self.assertEqual(r.lease.owner_host, "DESKTOP-H3R6CQN")
        self.assertEqual(r.lease.expected_main, SHA)

    def test_second_owner_conflicts(self):
        first = acquire(None, req(), NOW).lease
        second = acquire(first, req(owner="DESKTOP-10SKF0M", nonce="rh-test-0002"), NOW)
        self.assertFalse(second.acquired)
        self.assertEqual(second.reason, "active lease held")
    def test_same_request_is_idempotent(self):
        first = acquire(None, req(), NOW).lease
        again = acquire(first, req(), NOW + timedelta(seconds=1))
        self.assertTrue(again.acquired)
        self.assertTrue(again.idempotent)
        self.assertEqual(again.lease.lease_id, first.lease_id)

    def test_expiry_allows_other_owner(self):
        first = acquire(None, req(ttl=30), NOW).lease
        other = acquire(first, req(owner="DESKTOP-10SKF0M", nonce="rh-test-0003"), NOW + timedelta(seconds=31))
        self.assertTrue(other.acquired)
        self.assertEqual(other.lease.owner_host, "DESKTOP-10SKF0M")

    def test_resource_safety_required(self):
        with self.assertRaisesRegex(LeaseError, "resource admission failed"):
            acquire(None, req(safe=False), NOW)

    def test_split_brain_fence_required(self):
        with self.assertRaisesRegex(LeaseError, "split-brain fence not clear"):
            acquire(None, req(fence=False), NOW)

    def test_owner_allowlist(self):
        with self.assertRaisesRegex(LeaseError, "owner host not allowlisted"):
            acquire(None, req(owner="UNTRUSTED-HOST"), NOW)

    def test_exact_lowercase_sha_required(self):
        with self.assertRaisesRegex(LeaseError, "lowercase exact SHA40"):
            acquire(None, req(sha=SHA.upper()), NOW)

    def test_ttl_is_bounded(self):
        for ttl in (0, 29, 301, 9999):
            with self.subTest(ttl=ttl), self.assertRaisesRegex(LeaseError, "ttl outside bounded range"):
                acquire(None, req(ttl=ttl), NOW)
    def test_release_requires_holder_identity(self):
        current = acquire(None, req(), NOW).lease
        with self.assertRaisesRegex(LeaseError, "lease owner mismatch"):
            release(current, lease_id=current.lease_id, owner_host="DESKTOP-10SKF0M", now=NOW)
        with self.assertRaisesRegex(LeaseError, "lease id mismatch"):
            release(current, lease_id="forged", owner_host=current.owner_host, now=NOW)
        self.assertIsNone(release(current, lease_id=current.lease_id, owner_host=current.owner_host, now=NOW))

    def test_deploy_validation_requires_active_exact_binding(self):
        current = acquire(None, req(ttl=30), NOW).lease
        self.assertTrue(validate_for_deploy(current, owner_host="DESKTOP-H3R6CQN", expected_main=SHA, now=NOW))
        self.assertFalse(validate_for_deploy(current, owner_host="DESKTOP-10SKF0M", expected_main=SHA, now=NOW))
        self.assertFalse(validate_for_deploy(current, owner_host="DESKTOP-H3R6CQN", expected_main="0" * 40, now=NOW))
        self.assertFalse(validate_for_deploy(current, owner_host="DESKTOP-H3R6CQN", expected_main=SHA, now=NOW + timedelta(seconds=31)))

    def test_no_renewal_endpoint(self):
        with self.assertRaisesRegex(LeaseError, "renewal endpoint intentionally unavailable"):
            renew()

if __name__ == "__main__":
    unittest.main()