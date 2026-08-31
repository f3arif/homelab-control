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
        self.assertEqual(result["tools"], ["afz_control_health", "afz_windows_wsl_memory_audit"])

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


if __name__ == "__main__":
    unittest.main()
