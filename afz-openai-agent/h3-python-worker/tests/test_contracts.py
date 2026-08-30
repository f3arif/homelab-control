import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from afz_h3_worker.contracts import (
    CLAIM_SCHEMA_KNOWN,
    CompletionEnvelope,
    ContractError,
    ControlHubHealth,
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
    ClaimContractUnavailable,
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


class CompletionTests(unittest.TestCase):
    def test_nonzero_real_exit_is_preserved(self):
        result = WorkerExecutionResult.from_mapping(worker_result(exit_code=17))
        self.assertEqual(result.exit_code, 17)

    def test_completion_round_trip(self):
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

    def test_claim_schema_is_explicitly_unknown(self):
        self.assertFalse(CLAIM_SCHEMA_KNOWN)
        transport = UnboundControlHubTransport()
        self.assertFalse(transport.network_enabled)
        self.assertFalse(transport.routing_authority)
        self.assertFalse(transport.scheduling_authority)
        with self.assertRaises(ClaimContractUnavailable):
            transport.claim()

    def test_unbound_transport_cannot_perform_health_or_completion_io(self):
        transport = UnboundControlHubTransport()
        with self.assertRaises(LiveTransportUnavailable):
            transport.health()
        completion = CompletionEnvelope.from_mapping(
            {
                "job_id": "job-123",
                "ok": True,
                "result": worker_result(),
                "error": None,
            }
        )
        with self.assertRaises(LiveTransportUnavailable):
            transport.complete(completion)


if __name__ == "__main__":
    unittest.main()
