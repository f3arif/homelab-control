import pathlib
import sys
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from radiohilal_writer_lease import (
    AcquireResult,
    LeaseError,
    LeaseRecord,
    LeaseRequest,
    LeaseState,
    RESOURCE,
    TTL_DEFAULT,
    acquire,
    release,
    renew,
    validate_for_deploy,
)

SHA = "1e167c37e7ee0d8ae9871b71b0bc9179560b7c7b"
NOW = datetime(2026, 9, 18, 22, 40, tzinfo=timezone.utc)


def req(owner="DESKTOP-H3R6CQN", nonce="rh-test-0001", ttl=TTL_DEFAULT,
        safe=True, fence=True, sha=SHA):
    return LeaseRequest(owner, sha, nonce, ttl, safe, fence)
def acquire_new(request=None, now=NOW, state=None) -> AcquireResult:
    return acquire(state or LeaseState(), request or req(), now)


class WriterLeaseTests(unittest.TestCase):
    def test_acquire_valid(self):
        r = acquire_new()
        self.assertTrue(r.acquired)
        self.assertEqual(r.lease.resource, RESOURCE)
        self.assertEqual(r.lease.owner_host, "DESKTOP-H3R6CQN")
        self.assertEqual(r.lease.expected_main, SHA)
        self.assertEqual(r.state.terminal_nonces, frozenset())

    def test_second_owner_conflicts(self):
        first = acquire_new()
        second = acquire(
            first.state,
            req(owner="DESKTOP-10SKF0M", nonce="rh-test-0002"),
            NOW,
        )
        self.assertFalse(second.acquired)
        self.assertEqual(second.reason, "active lease held")
        self.assertEqual(second.state, first.state)

    def test_same_active_request_is_idempotent(self):
        first = acquire_new()
        again = acquire(first.state, req(), NOW + timedelta(seconds=1))
        self.assertTrue(again.acquired)
        self.assertTrue(again.idempotent)
        self.assertEqual(again.lease.lease_id, first.lease.lease_id)
    def test_expired_request_nonce_cannot_reacquire(self):
        first = acquire_new(req(ttl=30))
        replay = acquire(first.state, req(ttl=30), NOW + timedelta(seconds=31))
        self.assertFalse(replay.acquired)
        self.assertEqual(replay.reason, "expired request replay rejected")
        self.assertIsNone(replay.state.current)
        self.assertIn("rh-test-0001", replay.state.terminal_nonces)

    def test_release_archives_nonce_and_replay_is_rejected(self):
        first = acquire_new()
        released = release(
            first.state,
            lease_id=first.lease.lease_id,
            owner_host=first.lease.owner_host,
            now=NOW + timedelta(seconds=2),
        )
        self.assertIsNone(released.current)
        self.assertIn(first.lease.request_nonce, released.terminal_nonces)
        replay = acquire(released, req(), NOW + timedelta(seconds=3))
        self.assertFalse(replay.acquired)
        self.assertEqual(replay.reason, "request nonce already terminal")

    def test_different_nonce_can_acquire_after_expiry(self):
        first = acquire_new(req(ttl=30))
        other = acquire(
            first.state,
            req(owner="DESKTOP-10SKF0M", nonce="rh-test-0003"),
            NOW + timedelta(seconds=31),
        )
        self.assertTrue(other.acquired)
        self.assertEqual(other.lease.owner_host, "DESKTOP-10SKF0M")
        self.assertIn(first.lease.request_nonce, other.state.terminal_nonces)
    def test_resource_safety_requires_literal_true(self):
        for value in (False, "false", "unknown", 1, object()):
            with self.subTest(value=value), self.assertRaisesRegex(
                LeaseError, "resource admission failed"
            ):
                acquire_new(req(safe=value))

    def test_split_brain_fence_requires_literal_true(self):
        for value in (False, "false", "clear", 1, object()):
            with self.subTest(value=value), self.assertRaisesRegex(
                LeaseError, "split-brain fence not clear"
            ):
                acquire_new(req(fence=value))

    def test_owner_allowlist(self):
        with self.assertRaisesRegex(LeaseError, "owner host not allowlisted"):
            acquire_new(req(owner="UNTRUSTED-HOST"))

    def test_exact_lowercase_sha_required(self):
        for value in (SHA.upper(), "0" * 39, None, 123):
            with self.subTest(value=value), self.assertRaisesRegex(
                LeaseError, "lowercase exact SHA40"
            ):
                acquire_new(req(sha=value))

    def test_ttl_type_and_bounds(self):
        for ttl in (True, "120", 1.5):
            with self.subTest(ttl=ttl), self.assertRaisesRegex(
                LeaseError, "ttl must be integer"
            ):
                acquire_new(req(ttl=ttl))
        for ttl in (0, 29, 301, 9999):
            with self.subTest(ttl=ttl), self.assertRaisesRegex(
                LeaseError, "ttl outside bounded range"
            ):
                acquire_new(req(ttl=ttl))
    def test_release_requires_holder_identity_even_after_expiry(self):
        first = acquire_new(req(ttl=30))
        expired = NOW + timedelta(seconds=31)
        with self.assertRaisesRegex(LeaseError, "lease owner mismatch"):
            release(
                first.state,
                lease_id=first.lease.lease_id,
                owner_host="DESKTOP-10SKF0M",
                now=expired,
            )
        with self.assertRaisesRegex(LeaseError, "lease id mismatch"):
            release(
                first.state,
                lease_id="forged",
                owner_host=first.lease.owner_host,
                now=expired,
            )
        cleared = release(
            first.state,
            lease_id=first.lease.lease_id,
            owner_host=first.lease.owner_host,
            now=expired,
        )
        self.assertIsNone(cleared.current)
        self.assertIn(first.lease.request_nonce, cleared.terminal_nonces)

    def test_deploy_requires_active_exact_binding_and_fresh_gates(self):
        state = acquire_new(req(ttl=30)).state
        good = dict(
            state=state,
            owner_host="DESKTOP-H3R6CQN",
            expected_main=SHA,
            now=NOW,
            resource_safe=True,
            split_brain_fence_clear=True,
        )
        self.assertTrue(validate_for_deploy(**good))
        self.assertFalse(validate_for_deploy(**{**good, "owner_host": "DESKTOP-10SKF0M"}))
        self.assertFalse(validate_for_deploy(**{**good, "expected_main": "0" * 40}))
        self.assertFalse(validate_for_deploy(**{**good, "now": NOW + timedelta(seconds=31)}))
        for value in (False, "false", "unknown", 1):
            self.assertFalse(validate_for_deploy(**{**good, "resource_safe": value}))
            self.assertFalse(
                validate_for_deploy(**{**good, "split_brain_fence_clear": value})
            )

    def test_future_dated_lease_never_authorizes(self):
        base = acquire_new(req(ttl=30)).lease
        future = replace(
            base,
            acquired_at=NOW + timedelta(seconds=20),
            expires_at=NOW + timedelta(seconds=50),
        )
        state = LeaseState(current=future)
        self.assertFalse(
            validate_for_deploy(
                state,
                owner_host="DESKTOP-H3R6CQN",
                expected_main=SHA,
                now=NOW,
                resource_safe=True,
                split_brain_fence_clear=True,
            )
        )
        self.assertFalse(future.active_at(NOW))

    def test_timezone_offsets_are_normalized_to_utc(self):
        plus_five = timezone(timedelta(hours=5))
        local_now = NOW.astimezone(plus_five)
        result = acquire_new(now=local_now)
        self.assertEqual(result.lease.acquired_at.tzinfo, timezone.utc)
        self.assertTrue(result.lease.active_at(NOW + timedelta(seconds=1)))
    def test_corrupted_persisted_record_fails_closed(self):
        current = acquire_new().lease
        corruptions = (
            replace(current, resource=None),
            replace(current, owner_host=123),
            replace(current, expected_main=None),
            replace(current, request_nonce=None),
            replace(current, lease_id=None),
            replace(current, lease_id="not-a-uuid"),
            replace(current, expires_at="not-a-date"),
            replace(current, acquired_at=None),
            replace(current, expires_at=current.acquired_at + timedelta(seconds=301)),
            replace(current, acquired_at=current.acquired_at.replace(tzinfo=None)),
        )
        for corrupted in corruptions:
            with self.subTest(corrupted=corrupted):
                state = LeaseState(current=corrupted)
                self.assertFalse(
                    validate_for_deploy(
                        state,
                        owner_host="DESKTOP-H3R6CQN",
                        expected_main=SHA,
                        now=NOW,
                        resource_safe=True,
                        split_brain_fence_clear=True,
                    )
                )
                with self.assertRaises(LeaseError):
                    acquire(state, req(nonce="rh-test-0042"), NOW)

    def test_terminal_nonce_ledger_validates_types(self):
        with self.assertRaisesRegex(LeaseError, "must be frozenset"):
            LeaseState(terminal_nonces={"rh-test-0001"}).validate()
        with self.assertRaisesRegex(LeaseError, "invalid nonce"):
            LeaseState(terminal_nonces=frozenset({"bad nonce"})).validate()
    def test_current_nonce_cannot_already_be_terminal(self):
        first = acquire_new()
        bad = LeaseState(
            current=first.lease,
            terminal_nonces=frozenset({first.lease.request_nonce}),
        )
        with self.assertRaisesRegex(LeaseError, "already terminal"):
            bad.validate()
        self.assertFalse(
            validate_for_deploy(
                bad,
                owner_host="DESKTOP-H3R6CQN",
                expected_main=SHA,
                now=NOW,
                resource_safe=True,
                split_brain_fence_clear=True,
            )
        )

    def test_naive_deploy_time_fails_closed(self):
        state = acquire_new().state
        self.assertFalse(
            validate_for_deploy(
                state,
                owner_host="DESKTOP-H3R6CQN",
                expected_main=SHA,
                now=NOW.replace(tzinfo=None),
                resource_safe=True,
                split_brain_fence_clear=True,
            )
        )

    def test_no_renewal_endpoint(self):
        with self.assertRaisesRegex(
            LeaseError, "renewal endpoint intentionally unavailable"
        ):
            renew()


if __name__ == "__main__":
    unittest.main()
