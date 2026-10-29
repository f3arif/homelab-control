"""Portable R55 qualification; disposable files and loopback sockets only.

Dependencies are installed separately from the service's pinned requirements.
This runner deliberately has no production paths or credentials.
"""
import datetime
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SERVICE = REPO / 'services/movie-night-review-ui'
OUTPUT = SERVICE / 'qa/r55-e2e'
OUTPUT.mkdir(parents=True, exist_ok=True)
sys.path[:0] = [str(SERVICE/'src'), str(SERVICE/'tests'), str(SERVICE/'gateway')]
pattern = sys.argv[1] if len(sys.argv) > 1 else 'test_*.py'
label = 'e2e' if pattern == 'test_server_delete_e2e.py' else 'full'
source_files = [SERVICE/'src'/name for name in
                ('adapters.py', 'webapp.py', 'auto_downloads.py', 'review_service.py',
                 'server_file_delete.py')]
original_connect = socket.socket.connect


def fixture_network_only(sock, address):
    if isinstance(address, tuple):
        if address[0] not in ('127.0.0.1', 'localhost', '::1'):
            raise AssertionError('Non-loopback connections forbidden in R55 tests')
    elif isinstance(address, (str, bytes)):
        path = Path(os.fsdecode(address))
        allowed = Path(tempfile.gettempdir()).resolve()
        if not path.is_absolute() or not path.resolve().is_relative_to(allowed):
            raise AssertionError('Only disposable temporary Unix sockets allowed')
    else:
        raise AssertionError('Unknown socket address type')
    return original_connect(sock, address)


start = time.monotonic()
with patch.object(socket.socket, 'connect', fixture_network_only):
    suite = unittest.defaultTestLoader.discover(str(SERVICE/'tests'), pattern=pattern)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
record = {
    'atUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'inputCommit': subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),
    'originalSourceBase': 'c6fe9a6e71ce8d510136da1289fd938c4e6bacd6',
    'python': sys.version.split()[0], 'scope': label,
    'tests': result.testsRun, 'failures': len(result.failures),
    'errors': len(result.errors), 'skipped': len(result.skipped),
    'passed': result.wasSuccessful(),
    'elapsedSeconds': round(time.monotonic()-start, 3),
    'sourceSHA256': {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in source_files},
    'dependencies': {p: importlib.metadata.version(p) for p in
                     ('fastapi','uvicorn','starlette','httpx','httpx2','requests')},
    'failureNames': [str(t) for t,_ in result.failures + result.errors],
    'nonLoopbackNetworkAllowed': False,
    'productionFilesAccessed': False,
    'serverActivated': False,
    'phoneOrTVAcceptanceClaimed': False,
}
(OUTPUT / (label + '.json')).write_text(json.dumps(record, indent=2))
print('QUALIFICATION_RECEIPT ' + json.dumps(record), flush=True)
summary = os.environ.get('GITHUB_STEP_SUMMARY')
if summary:
    with open(summary, 'a', encoding='utf-8') as stream:
        stream.write(f'## R55 {label}\nTests: {result.testsRun}; failures: {len(result.failures)}; '
                     f'errors: {len(result.errors)}; skipped: {len(result.skipped)}.\n'
                     'Only disposable fixture files and loopback sockets; no production activation.\n')
sys.exit(0 if result.wasSuccessful() else 1)
