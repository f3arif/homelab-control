import pathlib
import subprocess
import tempfile
import threading
import time
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import Mock, patch

import patch_recovery

BASE = pathlib.Path(__file__).resolve().parent


def recovery_module():
    source = patch_recovery.server((BASE / 'fixtures/legacy_server.py.txt').read_text())
    module = types.ModuleType('recovery_under_test')
    exec(compile(source, 'patched_server.py', 'exec'), module.__dict__)
    return module


class RecoveryTests(unittest.TestCase):
    def test_slow_healthy_primary_and_no_retired_network_probe(self):
        requests = []

        class Health(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                time.sleep(2.2)  # Exceeds the previous 1.8-second budget.
                body = b'{"ok":true,"upstream_console":"ready"}'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        http = ThreadingHTTPServer(('127.0.0.1', 0), Health)
        thread = threading.Thread(target=http.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        module = recovery_module()
        module.HP_DIRECT = f'http://127.0.0.1:{http.server_port}'
        module.tcp = Mock(side_effect=AssertionError('Healthy HTTP needs no fallback'))
        result = module.status()
        self.assertEqual(requests, ['/api/hp-health'])
        self.assertEqual(result['hp']['http'], 200)
        self.assertTrue(result['hp']['online'])
        self.assertEqual(result['windows'], {'online': False, 'http': 0, 'retired': True})

    def test_healthy_host_does_not_emit_wake_packet_or_wait_for_http(self):
        module = recovery_module()
        module.tcp = Mock(return_value=True)
        module.fetch = Mock(side_effect=AssertionError('TCP already established availability'))
        with patch.object(module.socket, 'socket', side_effect=AssertionError('No wake packet')):
            self.assertEqual(module.wake_hp(), {'ok': True, 'state': 'already_online'})

    def test_service_failure_keeps_reachable_host_online(self):
        module = recovery_module()
        module.fetch = Mock(return_value=(False, 0, 'timeout'))
        module.tcp = Mock(return_value=True)
        self.assertTrue(module.status()['hp']['online'])

    def test_retired_card_and_links_removed(self):
        html = recovery_module().HTML
        self.assertNotIn('retired.example.invalid', html)
        self.assertNotIn("ss('win'", html)
        self.assertNotIn('Windows Ops Fallback', html)
        self.assertIn('Wake HP', html)
        self.assertIn('primary.example.invalid', html)

    def test_unknown_or_already_patched_source_is_rejected(self):
        source = (BASE / 'fixtures/legacy_server.py.txt').read_text()
        with self.assertRaises(ValueError):
            patch_recovery.server('unrecognized source')
        with self.assertRaises(ValueError):
            patch_recovery.server(patch_recovery.server(source))

    def test_nginx_retirement_preserves_current_origin(self):
        source = 'upstream site {\n    server current-site:80;\n    server 192.0.2.99:18095 backup;\n}\n'
        result = patch_recovery.nginx(source, '192.0.2.99:18095')
        self.assertIn('server current-site:80;', result)
        self.assertNotIn('192.0.2.99', result)
        with self.assertRaises(ValueError):
            patch_recovery.nginx(source, '192.0.2.98:18095')

    def test_watchdog_accepts_slow_health_without_requesting_wake(self):
        requests = []

        class Health(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                time.sleep(2.2)  # Exceeds the previous watchdog timeout.
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                requests.append('UNEXPECTED WAKE')
                self.send_error(500)

            def log_message(self, *_):
                pass

        http = ThreadingHTTPServer(('127.0.0.1', 0), Health)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        source = patch_recovery.watchdog((BASE / 'fixtures/legacy_watchdog.sh.txt').read_text())
        with tempfile.TemporaryDirectory() as td:
            source = source.replace('/state/', td + '/')
            lines = source.splitlines()
            lines = [f"HP='http://127.0.0.1:{http.server_port}/health'" if line.startswith("HP='") else line for line in lines]
            script = pathlib.Path(td) / 'watchdog.sh'
            script.write_text('\n'.join(lines) + '\n')
            subprocess.run(['sh', str(script), '--once'], check=True, timeout=10)
            state = (pathlib.Path(td) / 'status.json').read_text()
            self.assertIn('"state":"HEALTHY"', state)
            self.assertIn('"last_action":"none"', state)
        self.assertEqual(requests, ['/health'])


if __name__ == '__main__':
    unittest.main()
