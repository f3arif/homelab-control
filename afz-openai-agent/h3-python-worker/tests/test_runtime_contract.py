import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from afz_h3_worker import runtime_contract as rc


class RuntimeContractR4Tests(unittest.TestCase):
    def test_live_file_identities_are_pinned(self):
        self.assertEqual(
            rc.GENERIC_WORKER.sha256,
            "B61D8EB4E625549836C504D102BC0139D1C97786447E2EA071AC9DBC8F02795E",
        )
        self.assertEqual(
            rc.OLLAMA_TELEMETRY.sha256,
            "BFEFD838E7E3AD3E9723FB47FADDC844AB534B382076C65082F739D5C9C4B30A",
        )
        self.assertEqual(
            rc.DIRECT_WORKER.sha256,
            "BA417A98FB84972317ED0668FDCFFEF144B0944071841A73A18EB2BDC3109F61",
        )

    def test_current_generic_unknowns_fail_closed(self):
        self.assertFalse(rc.current_contract_complete())
        self.assertIsNone(rc.CURRENT_GENERIC_WORKER_VERSION)
        self.assertIsNone(rc.CURRENT_GENERIC_POLL_SECONDS)
        self.assertIsNone(rc.CURRENT_HEAVY_RAM_CEILING_PERCENT)
        self.assertIsNone(rc.CURRENT_ALLOWED_ACTIONS)
        self.assertIsNone(rc.CURRENT_HEAVY_ACTIONS)
        self.assertIsNone(rc.CURRENT_MUTEX_NAME)
        self.assertIsNone(rc.CURRENT_TASK_CONTRACT)

    def test_observed_queue_semantics_are_pinned(self):
        self.assertEqual(rc.GENERIC_QUEUE_ORDER, ("LastWriteTimeUtc", "Name"))
        self.assertEqual(rc.GENERIC_READ_RETRY_COUNT, 10)
        self.assertEqual(rc.GENERIC_READ_RETRY_SLEEP_SECONDS, 2)
        self.assertEqual(rc.DIRECT_WORKER_POLL_SECONDS, 2)
        self.assertEqual(rc.OLLAMA_TELEMETRY_POLL_SECONDS, 15)

    def test_direct_worker_remains_health_only_and_non_authoritative(self):
        self.assertEqual(rc.DIRECT_WORKER_EXECUTION_SCOPE, "h3-health-only")
        self.assertFalse(rc.DIRECT_WORKER_ROUTING_AUTHORITY)
        self.assertFalse(rc.DIRECT_WORKER_PROJECT_EXECUTION)
        self.assertFalse(rc.DIRECT_WORKER_RADIOHILAL35B_AUTHORITY)

    def test_current_heartbeat_observation_includes_telemetry(self):
        for field in (
            "state",
            "queueCount",
            "computeState",
            "ollamaReachable",
            "ollamaPrimaryModel",
            "ollamaContextLength",
            "gpuPercent",
            "vramPercent",
        ):
            self.assertIn(field, rc.CURRENTLY_OBSERVED_HEARTBEAT_FIELDS)


if __name__ == "__main__":
    unittest.main()
