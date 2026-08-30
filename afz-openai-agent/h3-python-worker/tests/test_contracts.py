import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from afz_h3_worker.contracts import (
    CLAIM_SCHEMA_KNOWN,
    LEASE_RENEWAL_SCHEMA_KNOWN,
    LEASE_SECONDS_DEFAULT,
    LEASE_SECONDS_MAX,
    LEASE_SECONDS_MIN,
    ClaimRequest,
    ClaimResponse,
    ClaimedJob,
    CompletionAck,
    CompletionEnvelope,
    ContractError,
    ControlHubCompletionRequest,
    ControlHubHealth,
    HeartbeatAck,
    HeartbeatRequest,
    JobCreate,
    PORTABLE_ACTION,
    PORTABLE_PATH,
    PORTABLE_PROJECT,
    PORTABLE_REPO,
    PORTABLE_WORKER,
    PortablePayload,
    WorkerExecutionResult,
)
from afz_h3_worker.transport import (
    LeaseRenewalContractUnavailable,
    LiveTransportUnavailable,
    UnboundControlHubTransport,
)


COMMIT = "1" * 40
HASH = "a" * 64


def portable_payload(**overrides):
    value = {
        "repo": PORTABLE_REPO,
        "commit": COMMIT,
        "path": PORTABLE_PATH,
        "sha256": HASH,
        "timeout_seconds": 30,
    }
    value.update(overrides)
    return value


def portable_job(**overrides):
    value = {
        "project": PORTABLE_PROJECT,
        "action": PORTABLE_ACTION,
        "payload": portable_payload(),
        "required_capabilities": ["windows", "lenovo", "github-portable-powershell"],
        "preferred_worker": PORTABLE_WORKER,
        "max_attempts": 1,
    }
    value.update(overrides)
    return value


def worker_result(**overrides):
    value = {
        "worker": PORTABLE_WORKER,
        "action": PORTABLE_ACTION,
        "repo": PORTABLE_REPO,
        "commit": COMMIT,
        "path": PORTABLE_PATH,
        "sha256": HASH,
        "timeout_seconds": 30,
        "exit_code": 0,
        "stdout": "ok\n",
        "stderr": "",
        "computer": "TEST-WINDOWS",
        "direct_transport": True,
    }
    value.update(overrides)
    return value


def claimed_job(**overrides):
    value = {
        "job_id": "job-123",
        "project": "AFZ-General",
        "action": "h3-health",
        "payload": {"probe": "bounded"},
        "required_capabilities": ["windows", "h3"],
        "attempt": 1,
        "lease_until": "2026-08-30T18:00:00+00:00",
    }
    value.update(overrides)
    return value


class PortablePayloadTests(unittest.TestCase):
    def test_round_trip_known_payload(self):
        payload = PortablePayload.from_mapping(portable_payload())
        self.assertEqual(payload.to_dict(), portable_payload())

    def test_extra_payload_key_is_rejected(self):
        raw = portable_payload(extra="no")
        with self.assertRaises(ContractError):
            PortablePayload.from_mapping(raw)

    def test_bool_timeout_is_rejected(self):
        with self.assertRaises(ContractError):
            PortablePayload.from_mapping(portable_payload(timeout_seconds=True))

    def test_wrong_repo_path_and_hash_are_rejected(self):
        for raw in (
            portable_payload(repo="other/repo"),
            portable_payload(path="afz-openai-agent/portable-jobs/other.ps1"),
            portable_payload(sha256="abc"),
            portable_payload(commit="deadbeef"),
        ):
            with self.subTest(raw=raw), self.assertRaises(ContractError):
                PortablePayload.from_mapping(raw)


class JobCreateTests(unittest.TestCase):
    def test_known_canary_job_round_trip(self):
        job = JobCreate.from_portable_canary_mapping(portable_job())
        self.assertEqual(job.to_dict(), portable_job())

    def test_capability_order_is_not_authority_but_duplicates_are_rejected(self):
        raw = portable_job(
            required_capabilities=["github-portable-powershell", "windows", "lenovo"]
        )
        self.assertEqual(
            frozenset(JobCreate.from_portable_canary_mapping(raw).required_capabilities),
            frozenset({"windows", "lenovo", "github-portable-powershell"}),
        )
        raw["required_capabilities"] = ["windows", "lenovo", "lenovo"]
        with self.assertRaises(ContractError):
            JobCreate.from_portable_canary_mapping(raw)

    def test_project_worker_and_attempts_are_pinned(self):
        for raw in (
            portable_job(project="other"),
            portable_job(preferred_worker="h3"),
            portable_job(max_attempts=2),
        ):
            with self.subTest(raw=raw), self.assertRaises(ContractError):
                JobCreate.from_portable_canary_mapping(raw)


class GatewayCompletionTests(unittest.TestCase):
    def test_nonzero_real_exit_is_preserved(self):
        result = WorkerExecutionResult.from_mapping(worker_result(exit_code=17))
        self.assertEqual(result.exit_code, 17)

    def test_legacy_gateway_completion_round_trip(self):
        raw = {
            "job_id": "job-123",
            "ok": False,
            "result": worker_result(exit_code=17, stderr="failed\n"),
            "error": "portable PowerShell returned nonzero exit",
        }
        completion = CompletionEnvelope.from_mapping(raw)
        self.assertEqual(completion.to_dict(), raw)

    def test_direct_transport_must_be_true(self):
        with self.assertRaises(ContractError):
            WorkerExecutionResult.from_mapping(worker_result(direct_transport=False))


class HeartbeatContractTests(unittest.TestCase):
    def test_heartbeat_round_trip(self):
        raw = {
            "state": "READY",
            "capabilities": ["windows", "h3"],
            "metadata": {"source": "shadow"},
            "current_job_id": None,
        }
        self.assertEqual(HeartbeatRequest.from_mapping(raw).to_dict(), raw)

    def test_heartbeat_duplicate_capability_is_rejected(self):
        raw = {
            "state": "READY",
            "capabilities": ["h3", "h3"],
            "metadata": {},
            "current_job_id": None,
        }
        with self.assertRaises(ContractError):
            HeartbeatRequest.from_mapping(raw)

    def test_heartbeat_ack_matches_captured_shape(self):
        ack = HeartbeatAck.from_mapping({"ok": True, "worker_id": "h3-shadow"})
        self.assertTrue(ack.ok)
        self.assertEqual(ack.worker_id, "h3-shadow")


class ClaimContractTests(unittest.TestCase):
    def test_claim_contract_is_known_but_renewal_is_not(self):
        self.assertTrue(CLAIM_SCHEMA_KNOWN)
        self.assertFalse(LEASE_RENEWAL_SCHEMA_KNOWN)

    def test_claim_defaults_match_captured_hub(self):
        request = ClaimRequest.create()
        self.assertEqual(request.lease_seconds, LEASE_SECONDS_DEFAULT)
        self.assertEqual(request.effective_lease_seconds, 60)
        self.assertFalse(request.strict_preferred)

    def test_claim_lease_server_clamp_is_modelled(self):
        low = ClaimRequest.create(lease_seconds=1)
        high = ClaimRequest.create(lease_seconds=999999)
        self.assertEqual(low.effective_lease_seconds, LEASE_SECONDS_MIN)
        self.assertEqual(high.effective_lease_seconds, LEASE_SECONDS_MAX)
        self.assertEqual(low.to_query()["lease_seconds"], 1)
        self.assertEqual(high.to_query()["lease_seconds"], 999999)

    def test_claim_query_supports_newer_strict_preferred_flag(self):
        query = ClaimRequest.create(lease_seconds=90, strict_preferred=True).to_query()
        self.assertEqual(query, {"lease_seconds": 90, "strict_preferred": True})

    def test_claim_rejects_bool_lease_and_nonbool_strict_preferred(self):
        with self.assertRaises(ContractError):
            ClaimRequest.create(lease_seconds=True)
        with self.assertRaises(ContractError):
            ClaimRequest.create(strict_preferred=1)

    def test_claimed_job_round_trip(self):
        job = ClaimedJob.from_mapping(claimed_job())
        self.assertEqual(job.to_dict(), claimed_job())

    def test_claimed_job_requires_post_claim_attempt_and_iso_lease(self):
        with self.assertRaises(ContractError):
            ClaimedJob.from_mapping(claimed_job(attempt=0))
        with self.assertRaises(ContractError):
            ClaimedJob.from_mapping(claimed_job(lease_until="not-a-time"))

    def test_idle_claim_response_round_trip(self):
        raw = {"ok": True, "job": None}
        self.assertEqual(ClaimResponse.from_mapping(raw).to_dict(), raw)

    def test_shadow_claim_response_round_trip(self):
        raw = {"ok": True, "job": None, "mode": "shadow"}
        self.assertEqual(ClaimResponse.from_mapping(raw).to_dict(), raw)

    def test_claim_response_with_job_round_trip(self):
        raw = {"ok": True, "job": claimed_job()}
        self.assertEqual(ClaimResponse.from_mapping(raw).to_dict(), raw)

    def test_shadow_mode_cannot_also_return_job(self):
        with self.assertRaises(ContractError):
            ClaimResponse.from_mapping({"ok": True, "job": claimed_job(), "mode": "shadow"})


class CanonicalCompletionTests(unittest.TestCase):
    def test_control_hub_completion_round_trip(self):
        raw = {
            "worker_id": "h3-shadow",
            "ok": False,
            "result": {"exit_code": 17, "stdout": "", "stderr": "failed"},
            "error": "real child exit 17",
        }
        self.assertEqual(ControlHubCompletionRequest.from_mapping(raw).to_dict(), raw)

    def test_completion_ack_is_bounded_to_hub_statuses(self):
        self.assertEqual(
            CompletionAck.from_mapping({"ok": True, "status": "COMPLETED"}).status,
            "COMPLETED",
        )
        self.assertEqual(
            CompletionAck.from_mapping({"ok": True, "status": "FAILED"}).status,
            "FAILED",
        )
        with self.assertRaises(ContractError):
            CompletionAck.from_mapping({"ok": True, "status": "RUNNING"})


class HealthAndTransportTests(unittest.TestCase):
    def test_health_accepts_proven_minimum_and_ignores_extra_observation_fields(self):
        health = ControlHubHealth.from_mapping(
            {
                "ok": True,
                "service": "afz-control-hub",
                "version": "0.3.3-safe-typed-canary",
                "mode": "safe-readonly",
                "extra_runtime_field": "observed-but-not-modelled",
            }
        )
        self.assertTrue(health.ok)
        self.assertEqual(health.mode, "safe-readonly")

    def test_contract_known_but_transport_remains_unbound(self):
        transport = UnboundControlHubTransport()
        self.assertFalse(transport.network_enabled)
        self.assertTrue(transport.claim_schema_known)
        self.assertFalse(transport.lease_renewal_schema_known)
        self.assertFalse(transport.routing_authority)
        self.assertFalse(transport.scheduling_authority)
        with self.assertRaises(LiveTransportUnavailable):
            transport.claim("h3-shadow", ClaimRequest.create())
        with self.assertRaises(LeaseRenewalContractUnavailable):
            transport.renew_lease("job-123")

    def test_unbound_transport_cannot_perform_any_live_io(self):
        transport = UnboundControlHubTransport()
        with self.assertRaises(LiveTransportUnavailable):
            transport.health()
        heartbeat = HeartbeatRequest.from_mapping(
            {"state": "READY", "capabilities": ["h3"], "metadata": {}, "current_job_id": None}
        )
        with self.assertRaises(LiveTransportUnavailable):
            transport.heartbeat("h3-shadow", heartbeat)
        completion = ControlHubCompletionRequest.from_mapping(
            {"worker_id": "h3-shadow", "ok": True, "result": worker_result(), "error": None}
        )
        with self.assertRaises(LiveTransportUnavailable):
            transport.complete("job-123", completion)


if __name__ == "__main__":
    unittest.main()
