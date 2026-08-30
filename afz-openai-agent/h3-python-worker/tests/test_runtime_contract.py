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

    def test_current_generic_constants_are_live_v2_evidence(self):
        self.assertEqual(rc.CURRENT_GENERIC_WORKER_VERSION, "1.0.0")
        self.assertEqual(rc.CURRENT_GENERIC_POLL_SECONDS, 12)
        self.assertEqual(rc.CURRENT_HEAVY_RAM_CEILING_PERCENT, 88.0)
        self.assertEqual(rc.CURRENT_MAX_OUTPUT_CHARS, 120000)
        self.assertEqual(rc.CURRENT_MUTEX_NAME, r"Local\AFZH3GenericWorker")
        self.assertEqual(
            rc.CURRENT_HEAVY_ACTIONS,
            ("h3-dotnet-build", "h3-npm-build", "h3-npm-test", "h3-tsc"),
        )
        self.assertEqual(len(rc.CURRENT_ALLOWED_ACTIONS), 9)
        self.assertIn("h3-status", rc.CURRENT_ALLOWED_ACTIONS)
        self.assertIn("h3-python-compile", rc.CURRENT_ALLOWED_ACTIONS)
        self.assertIn("h3-tsc", rc.CURRENT_ALLOWED_ACTIONS)

    def test_launcher_evidence_has_live_pid_continuity(self):
        self.assertTrue(rc.current_contract_complete())
        self.assertTrue(rc.DIRECT_TASK_LAUNCHER.live_pid_continuity)
        self.assertTrue(rc.GENERIC_TASK_LAUNCHER.live_pid_continuity)
        self.assertEqual(rc.DIRECT_TASK_LAUNCHER.pid_at_r4_snapshot, rc.CURRENT_DIRECT_PID)
        self.assertEqual(rc.GENERIC_TASK_LAUNCHER.pid_at_r4_snapshot, rc.CURRENT_GENERIC_PID)
        for launcher in (rc.DIRECT_TASK_LAUNCHER, rc.GENERIC_TASK_LAUNCHER):
            self.assertEqual(launcher.user, "Faiz")
            self.assertEqual(launcher.logon_type, "Interactive")
            self.assertEqual(launcher.run_level, "Limited")
            self.assertTrue(launcher.execute.lower().endswith("wscript.exe"))
            self.assertIn("//B //Nologo", launcher.arguments)

    def test_generic_and_telemetry_launch_via_hidden_wscript_runkeys(self):
        self.assertEqual(rc.GENERIC_RUNKEY_NAME, "AFZ H3 Generic Worker")
        self.assertIn("wscript.exe", rc.GENERIC_RUNKEY_COMMAND.lower())
        self.assertIn("Run-AFZ-H3-Worker-Run-Hidden.vbs", rc.GENERIC_RUNKEY_COMMAND)
        self.assertEqual(rc.TELEMETRY_RUNKEY_NAME, "AFZ H3 Ollama Telemetry")
        self.assertIn("wscript.exe", rc.TELEMETRY_RUNKEY_COMMAND.lower())
        self.assertIn("Run-AFZ-H3-OllamaTelemetry-Run-Hidden.vbs", rc.TELEMETRY_RUNKEY_COMMAND)

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

    def test_current_heartbeat_schema_is_exact_v2_observation(self):
        expected = {
            "timestamp", "computer", "pid", "version", "state", "detail", "queueCount",
            "ramPercent", "radioHilal35BState", "computeState", "ollamaReachable",
            "ollamaVersion", "ollamaState", "ollamaModelCount", "ollamaPrimaryModel",
            "ollamaVramBytes", "ollamaContextLength", "ollamaActiveTask", "gpuPercent",
            "vramPercent", "ollamaTelemetryAgeSeconds", "allowedActions", "forcedSleep",
            "ollamaExposureChanged",
        }
        self.assertEqual(rc.CURRENTLY_OBSERVED_HEARTBEAT_FIELDS, frozenset(expected))


if __name__ == "__main__":
    unittest.main()
