import importlib.util
import json
import pathlib
import unittest
from unittest import mock

MODULE_PATH = pathlib.Path(__file__).with_name("afz_commander_recovery_mcp.py")
spec = importlib.util.spec_from_file_location("afz_commander_recovery_mcp", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(mod)


class AfzCommanderRecoveryMcpTests(unittest.TestCase):
    def test_self_test_is_one_purpose_and_no_shell(self):
        result = mod.self_test()
        self.assertTrue(result["ok"])
        self.assertTrue(result["stateChanging"])
        self.assertFalse(result["arbitraryShell"])
        self.assertFalse(result["arbitraryUrl"])
        self.assertFalse(result["credentialAccess"])
        self.assertFalse(result["deviceCodeReturned"])
        self.assertEqual(result["tools"], ["afz_commander_pair_active_request"])
        self.assertEqual(result["baseUrl"], "http://100.70.25.8:8797")

    def test_rejects_non_allowlisted_path(self):
        with self.assertRaises(ValueError):
            mod._http_json("POST", "/api/control", {"action": "anything"})

    def test_pairing_uses_health_commit_and_fixed_payload(self):
        calls = []

        def fake_http(method, path, payload=None, timeout=20):
            calls.append((method, path, payload, timeout))
            if path == "/health":
                return {"ok": True, "status": 200, "data": {"commit": "c" * 40}}
            return {
                "ok": True,
                "status": 202,
                "data": {
                    "classification": "COMMANDER_ALTERNATE_ACCOUNT_PAIR_LAUNCH_ACCEPTED",
                    "deviceCodeReturned": False,
                },
            }

        with mock.patch.object(mod, "_http_json", side_effect=fake_http):
            result = json.loads(mod.afz_commander_pair_active_request())

        self.assertTrue(result["ok"])
        self.assertEqual(calls[0][0:2], ("GET", "/health"))
        self.assertEqual(calls[1][0:2], ("POST", "/api/commander-alternate-account-pair"))
        self.assertEqual(calls[1][3], 45)
        payload = calls[1][2]
        self.assertEqual(
            payload,
            {
                "action": "launch-active-request",
                "repository": "f3arif/homelab-control",
                "ref": "refs/heads/main",
                "sha": "c" * 40,
            },
        )

    def test_bad_health_commit_fails_closed_without_post(self):
        with mock.patch.object(
            mod,
            "_http_json",
            return_value={"ok": True, "status": 200, "data": {"commit": "not-a-sha"}},
        ) as mocked:
            result = json.loads(mod.afz_commander_pair_active_request())
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "afz_control_commit_unavailable")
        self.assertEqual(mocked.call_count, 1)


if __name__ == "__main__":
    unittest.main()
