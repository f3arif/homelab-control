import importlib.util
import json
import os
import pathlib
import unittest
from unittest import mock

MODULE_PATH = pathlib.Path(__file__).with_name("afz_hermes_mcp.py")
spec = importlib.util.spec_from_file_location("afz_hermes_mcp", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(mod)


class AfzHermesMcpTests(unittest.TestCase):
    def test_self_test_is_fixed_and_read_only(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            result = mod.self_test()
        self.assertTrue(result["ok"])
        self.assertEqual(result["baseUrl"], "http://100.70.25.8:8797")
        self.assertFalse(result["arbitraryShell"])
        self.assertFalse(result["arbitraryUrl"])
        self.assertEqual(
            result["tools"],
            [
                "afz_control_health",
                "afz_windows_wsl_memory_audit",
                "afz_h3_benchmark_status",
                "afz_stremio_organize_audit",
                "afz_stremio_organize_apply",
                "afz_queue_orphan_audit",
                "afz_queue_orphan_apply",
                "afz_jellyfin_visibility_audit",
                "afz_movierecommender_catalog_audit",
                "afz_radiohilal_cron_audit",
            ],
        )

    def test_rejects_non_asus_endpoint(self):
        with mock.patch.dict(os.environ, {"AFZ_CONTROL_BASE_URL": "http://100.71.26.69:8797"}, clear=True):
            with self.assertRaises(ValueError):
                mod._validated_base_url()

    def test_rejects_non_allowlisted_path(self):
        with self.assertRaises(ValueError):
            mod._http_json("GET", "/api/control")

    def test_memory_audit_uses_health_commit_and_fixed_payload(self):
        calls = []

        def fake_http(method, path, payload=None, timeout=20):
            calls.append((method, path, payload, timeout))
            if path == "/health":
                return {"ok": True, "status": 200, "data": {"commit": "a" * 40}}
            return {"ok": True, "status": 200, "data": {"readOnly": True}}

        with mock.patch.object(mod, "_http_json", side_effect=fake_http):
            result = json.loads(mod.afz_windows_wsl_memory_audit())

        self.assertTrue(result["ok"])
        self.assertEqual(calls[0][0:2], ("GET", "/health"))
        self.assertEqual(calls[1][0:2], ("POST", "/api/windows-wsl-memory-audit"))
        payload = calls[1][2]
        self.assertEqual(payload["action"], "audit")
        self.assertEqual(payload["repository"], "f3arif/homelab-control")
        self.assertEqual(payload["ref"], "refs/heads/main")
        self.assertEqual(payload["sha"], "a" * 40)

    def test_typed_stremio_audit_uses_health_commit(self):
        calls = []

        def fake_http(method, path, payload=None, timeout=20):
            calls.append((method, path, payload, timeout))
            if path == "/health":
                return {"ok": True, "status": 200, "data": {"commit": "b" * 40}}
            return {"ok": True, "status": 200, "data": {"changed": False}}

        with mock.patch.object(mod, "_http_json", side_effect=fake_http):
            result = json.loads(mod.afz_stremio_organize_audit())

        self.assertTrue(result["ok"])
        self.assertEqual(calls[1][0:2], ("POST", "/api/stremio-organize"))
        self.assertEqual(calls[1][2]["action"], "audit")
        self.assertEqual(calls[1][2]["sha"], "b" * 40)

    def test_queue_task_id_is_strict(self):
        result = json.loads(mod.afz_queue_orphan_audit("../bad task"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_task_id")

    def test_benchmark_status_uses_fixed_route(self):
        calls = []

        def fake_http(method, path, payload=None, timeout=20):
            calls.append((method, path, payload, timeout))
            return {"ok": True, "status": 200, "data": {"status": "completed"}}

        with mock.patch.object(mod, "_http_json", side_effect=fake_http):
            result = json.loads(mod.afz_h3_benchmark_status())

        self.assertTrue(result["ok"])
        self.assertEqual(calls, [("POST", "/api/h3-qwen27b-benchmark", {"action": "status"}, 30)])


if __name__ == "__main__":
    unittest.main()
