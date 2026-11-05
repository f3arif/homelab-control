"""R55 integration through real loopback gateway, relay and backend.

Only fictional IDs, tiny temporary files and fresh databases are used.
There is no access to Tailscale, production paths, providers or real media.
"""
from contextlib import contextmanager
from dataclasses import asdict
import hashlib
import http.client
import io
import json
from pathlib import Path
import secrets
import socket
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

BASE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BASE / 'src'), str(BASE / 'gateway')]
import uvicorn
from auto_downloads import AutoDownloads
from movie_night import Choice, ROOT
from private_relay import RelayAuth, RelayHandler, RelayServer
from review_service import build_app
from server_file_delete import ServerFileDeletion
from standalone_server import MovieNightServer

PUBLIC = 'https://movie.example.test:8453'
BACKEND = 'https://movie.example.test:8447'
OWNER = 'owner@example.test'
PRINCIPAL = 'billing-owner'
IDS = ('tt90001', 'tt90002', 'tt90003')
PREFIX = '/movie-night'


class NoProvider:
    def __init__(self):
        self.calls = 0

    def _api(self, *args, **kwargs):
        self.calls += 1
        raise AssertionError('Provider requests are forbidden in this fixture')


class ServerDeleteE2ETests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='afz-r55-e2e-')
        self.root = Path(self.tmp.name)
        self.root.chmod(0o700)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.media = self.root / 'fixture-media'
        self.now = int(time.time())
        self.payload = {'generatedEpoch': self.now, 'movies': [
            {'id': imdb, 'name': 'Disposable sample ' + str(i + 1), 'year': 2024,
             'genres': ['Action'], 'scareLevel': 'low', 'intensityReviewed': True,
             'intenseSupernatural': False, 'fitTags': ['twists']}
            for i, imdb in enumerate(IDS)]}
        (self.state / 'reviewed-shortlist.json').write_text(json.dumps(self.payload))
        self.provider = NoProvider()
        self.app, self.c = build_app(self.state, BACKEND, downloads=True,
                                     provider=self.provider, media_root=self.media,
                                     server_delete=True)
        self.c.free = lambda: 200_000_000_000
        self.c.clock = lambda: self.now
        self.c.delete_service = ServerFileDeletion(self.c.index, self.c.db, clock=lambda: self.now)
        self.c.finalize(PRINCIPAL, list(IDS))
        self.c.rate(PRINCIPAL, IDS[1], 'like')
        self.c.auto_downloads = AutoDownloads(self.c)
        self.body = b'R55 fixture bytes: not a movie and not production'
        self.paths, self.jobs, self.choices = {}, {}, {}
        for i, imdb in enumerate(IDS):
            filename = imdb + '.2024.mkv'
            path = self.media / 'Movies' / filename
            path.write_bytes(self.body)
            self.paths[imdb] = path
            choice = Choice(imdb, self.payload['movies'][i]['name'], 2024, 'Theatrical',
                            'torbox', 12 + i, 3, 'Disposable.Sample.2024.1080p.x264.mkv',
                            '1080p', 'AVC', len(self.body), ROOT + '/' + filename)
            self.choices[imdb] = choice
            raw = json.dumps({'choice': asdict(choice)})
            evidence = json.dumps({'file': {'sha256': hashlib.sha256(self.body).hexdigest()},
                                   'index': {'catalogId': imdb}})
            pid = str(uuid4())
            self.jobs[imdb] = pid
            with sqlite3.connect(self.c.db) as db:
                db.execute('INSERT INTO plans VALUES(?,?,?,?)', (pid, PRINCIPAL, raw, self.now + 900))
                db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?)',
                           (pid, imdb, choice.destination, raw, 'indexed', len(self.body), evidence))
                db.execute('INSERT INTO movie_download_queue VALUES(?,?,?,?,?,?,?,?)',
                           (str(uuid4()), PRINCIPAL, imdb, choice.title, 'linked', pid, '', self.now))
            with sqlite3.connect(self.c.index.db) as db:
                db.execute('INSERT INTO media VALUES(?,?,?,?,?,1)',
                           (imdb, filename, json.dumps(asdict(choice)), len(self.body),
                            hashlib.sha256(self.body).hexdigest()))
        self.phone_copy = self.root / 'phone-copy.mkv'
        self.phone_copy.write_bytes(b'preserve separate device copy')
        self.history = self.root / 'watch-history.json'
        self.history.write_text('{"fixture": "preserve"}')
        self.before_feedback = self.c.feedback.ratings(PRINCIPAL)
        self.before_picks = self.c.feedback.saved(PRINCIPAL)
        self.secret = secrets.token_hex(32)
        self.backend_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.backend_socket.bind(('127.0.0.1', 0))
        self.backend_socket.listen(32)
        self.backend_port = self.backend_socket.getsockname()[1]
        self.backend = uvicorn.Server(uvicorn.Config(
            RelayAuth(self.app, self.secret, peer='127.0.0.1'),
            log_level='critical', access_log=False, proxy_headers=False, lifespan='off'))
        self.backend_thread = threading.Thread(
            target=self.backend.run, kwargs={'sockets': [self.backend_socket]}, daemon=True)
        self.backend_thread.start()
        deadline = time.monotonic() + 5
        while not self.backend.started and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(self.backend.started, 'fixture backend not started')
        relay_path = self.root / 'relay.sock'
        self.relay = RelayServer(str(relay_path), RelayHandler)
        relay_path.chmod(0o600)
        self.relay.host, self.relay.port, self.relay.secret = '127.0.0.1', self.backend_port, self.secret
        self.relay_thread = threading.Thread(target=self.relay.serve_forever,
                                             kwargs={'poll_interval': .01}, daemon=True)
        self.relay_thread.start()
        self.front = MovieNightServer(PUBLIC, BACKEND, OWNER, port=0, movie_socket=str(relay_path))
        self.front_thread = threading.Thread(target=self.front.serve_forever,
                                             kwargs={'poll_interval': .01}, daemon=True)
        self.front_thread.start()
        original_connect = socket.create_connection

        def loopback_only(address, *args, **kwargs):
            if address[0] not in ('127.0.0.1', 'localhost'):
                raise AssertionError('Non-loopback fixture network refused')
            return original_connect(address, *args, **kwargs)

        self.network_guard = patch('socket.create_connection', side_effect=loopback_only)
        self.network_guard.start()

    def tearDown(self):
        self.network_guard.stop()
        self.front.shutdown(); self.front.server_close(); self.front_thread.join(3)
        self.relay.shutdown(); self.relay.server_close(); self.relay_thread.join(3)
        self.backend.should_exit = True
        self.backend_thread.join(5)
        self.backend_socket.close()
        self.c.close()
        self.tmp.cleanup()

    def call(self, path, method='GET', data=None, extra=None, identity=OWNER):
        headers = {'Host': self.front.host}
        if identity is not None:
            headers['Tailscale-User-Login'] = identity
        if method == 'POST':
            headers.update({'Content-Type': 'application/json', 'Origin': PUBLIC})
        headers.update(extra or {})
        raw = json.dumps(data).encode() if data is not None else None
        con = http.client.HTTPConnection('127.0.0.1', self.front.server_port, timeout=6)
        con.request(method, PREFIX + path, body=raw, headers=headers)
        r = con.getresponse()
        status, response_headers, body = r.status, dict(r.getheaders()), r.read(300_000)
        con.close()
        parsed = None
        if response_headers.get('Content-Type', '').startswith('application/json'):
            parsed = json.loads(body)
        return status, parsed, response_headers, body

    def preview(self):
        status, body, headers, _ = self.call('/api/delete-server/' + IDS[0])
        self.assertEqual(status, 200, body)
        self.assertIn('no-store', headers['Cache-Control'])
        self.assertEqual(body['title'], 'Disposable sample 1')
        self.assertEqual(body['sizeBytes'], len(self.body))
        self.assertTrue(body['requiresExplicitConfirmation'])
        return body

    def confirm(self, preview, **kwargs):
        data = {'imdb': IDS[0], 'confirmationToken': preview['confirmationToken'],
                'confirmedTitle': preview['title']}
        return self.call('/api/delete-server', 'POST', data,
                         extra={'X-Movie-Night-CSRF': preview['csrfToken'], **kwargs})

    def deleted(self):
        p = self.preview()
        status, value, _, _ = self.confirm(p)
        self.assertEqual(status, 200, value)
        self.assertTrue(value['deleted'])
        self.assertFalse(self.paths[IDS[0]].exists())
        return p

    def test_full_gateway_relay_delete_and_ready_catalog_refresh(self):
        self.assertEqual(len(self.call('/catalog/movie/afz_movie_night_ready.json')[1]['metas']), 3)
        self.deleted()
        metas = self.call('/catalog/movie/afz_movie_night_ready.json')[1]['metas']
        self.assertEqual({m['id'] for m in metas}, set(IDS[1:]))
        self.assertEqual(self.call('/stream/movie/' + IDS[0] + '.json')[1]['streams'], [])
        self.assertEqual(self.call('/media/' + IDS[0], 'HEAD')[0], 404)
        for imdb in IDS[1:]:
            self.assertEqual(self.paths[imdb].read_bytes(), self.body)
        self.assertEqual(self.c.feedback.ratings(PRINCIPAL), self.before_feedback)
        self.assertEqual(self.c.feedback.saved(PRINCIPAL), self.before_picks)
        self.assertEqual(self.phone_copy.read_bytes(), b'preserve separate device copy')
        self.assertEqual(self.history.read_text(), '{"fixture": "preserve"}')
        self.assertEqual(self.provider.calls, 0)

    def test_cancel_has_no_mutation(self):
        self.preview()
        self.assertEqual(self.paths[IDS[0]].read_bytes(), self.body)
        self.assertEqual(len(self.call('/catalog/movie/afz_movie_night_ready.json')[1]['metas']), 3)
        self.assertFalse(self.c.delete_service.removed_ids())

    def test_invalid_owner_origin_csrf_and_replay_are_refused(self):
        self.assertEqual(self.call('/api/delete-server/' + IDS[0], identity=None)[0], 403)
        self.assertEqual(self.call('/api/delete-server/' + IDS[0], identity='stranger@example.test')[0], 403)
        p = self.preview()
        self.assertEqual(self.confirm(p, Origin='https://evil.test')[0], 403)
        self.assertEqual(self.confirm(p, **{'X-Movie-Night-CSRF': 'wrong'})[0], 403)
        self.assertTrue(self.paths[IDS[0]].exists())
        self.assertEqual(self.confirm(p)[0], 200)
        self.assertEqual(self.confirm(p)[0], 409)
        self.assertEqual(self.paths[IDS[1]].read_bytes(), self.body)

    def test_backend_rejects_direct_request_without_private_relay_secret(self):
        con = http.client.HTTPConnection('127.0.0.1', self.backend_port, timeout=5)
        con.request('GET', PREFIX + '/api/delete-server/' + IDS[0],
                    headers={'X-AFZ-Review-Principal': PRINCIPAL})
        r = con.getresponse(); r.read(); con.close()
        self.assertEqual(r.status, 403)
        self.assertTrue(self.paths[IDS[0]].exists())

    def test_changed_file_and_expired_challenge_refused(self):
        p = self.preview()
        self.now += 121
        self.assertEqual(self.confirm(p)[0], 409)
        p = self.preview()
        replacement = self.paths[IDS[0]].with_suffix('.replacement')
        replacement.write_bytes(b'X' * len(self.body))
        replacement.replace(self.paths[IDS[0]])
        self.assertEqual(self.confirm(p)[0], 409)
        self.assertEqual(self.paths[IDS[0]].read_bytes(), b'X' * len(self.body))

    def test_downloads_and_single_job_status_agree_after_delete(self):
        self.deleted()
        download = self.call('/api/downloads')[1]
        job = next(j for j in download['jobs'] if j['imdb'] == IDS[0])
        request = next(j for j in download['requests'] if j['imdb'] == IDS[0])
        self.assertEqual(job['state'], 'removed')
        self.assertFalse(job['indexed'])
        self.assertEqual(request['state'], 'removed')
        self.assertFalse(request['canRetry'])
        status, single, _, _ = self.call('/api/status/' + self.jobs[IDS[0]])
        self.assertEqual(status, 200)
        self.assertEqual(single['state'], 'removed')
        self.assertFalse(single['indexed'])

    def test_removed_title_source_lookup_stops_before_provider(self):
        self.deleted()
        status, result, _, _ = self.call('/api/propose', 'POST', {'imdb': IDS[0]},
                                       extra={'X-Movie-Night-CSRF': self.c.token(PRINCIPAL)})
        self.assertEqual(status, 409, result)
        self.assertEqual(self.provider.calls, 0)

    def test_tombstone_survives_service_recreation(self):
        self.deleted()
        self.c.delete_service = ServerFileDeletion(self.c.index, self.c.db)
        self.assertEqual(self.c.delete_service.removed_ids(), {IDS[0]})
        self.assertEqual(self.call('/api/delete-server/' + IDS[0])[0], 409)
        self.assertNotIn(IDS[0], {x['id'] for x in self.call('/catalog/movie/downloaded.json')[1]['metas']})
        self.assertEqual(self.c.feedback.saved(PRINCIPAL), self.before_picks)

    def test_stale_worker_cannot_download_deleted_title_again(self):
        self.deleted()
        with sqlite3.connect(self.c.db) as db:
            db.execute("UPDATE jobs SET state='approved',bytes=0,evidence='{}' WHERE id=?", (self.jobs[IDS[0]],))
        calls = []

        class FakeProvider:
            def verify(inner, choice):
                calls.append('verify'); return choice
            def resolve(inner, row):
                calls.append('resolve'); return 'https://fixture.invalid/not-network'

        @contextmanager
        def open_fake(*args, **kwargs):
            calls.append('fetch')
            data = io.BytesIO(self.body)
            data.headers = {'Content-Length': str(len(self.body))}
            try:
                yield data
            finally:
                data.close()

        self.c.worker.provider = FakeProvider()
        self.c.worker.open_media = open_fake
        self.c.worker.probe = lambda _: {'format': {'duration': '7200'}, 'streams': [
            {'codec_type': 'video', 'codec_name': 'h264', 'width': 1920, 'height': 1080}]}
        with patch('movie_night.MIN_BYTES', 1), patch('worker_candidate.MIN_BYTES', 1):
            self.c.worker.run(self.jobs[IDS[0]])
        self.assertEqual(calls, [], 'Removed title must stop before any provider/network activity')
        self.assertFalse(self.paths[IDS[0]].exists())

    def test_simultaneous_confirmations_delete_once(self):
        from concurrent.futures import ThreadPoolExecutor
        p = self.preview()
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: self.confirm(p)[0], range(2)))
        self.assertEqual(sorted(responses), [200, 409])
        self.assertFalse(self.paths[IDS[0]].exists())
        self.assertEqual(len(self.call('/catalog/movie/downloaded.json')[1]['metas']), 2)

    def test_malformed_confirmation_fields_are_bad_requests(self):
        p = self.preview()
        base = {'imdb': IDS[0], 'confirmationToken': p['confirmationToken'], 'confirmedTitle': p['title']}
        for field, value in (('imdb', {}), ('imdb', []), ('confirmationToken', 123),
                             ('confirmedTitle', None), ('confirmationToken', 'X' * 129)):
            data = dict(base, **{field: value})
            self.assertEqual(self.call('/api/delete-server', 'POST', data,
                extra={'X-Movie-Night-CSRF': p['csrfToken']})[0], 400)
            self.assertTrue(self.paths[IDS[0]].exists())
        self.assertEqual(self.confirm(p)[0], 200)

    def test_tombstones_remain_effective_when_delete_mode_is_disabled(self):
        self.deleted()
        self.c.delete_service = None
        self.assertEqual(self.call('/api/status/' + self.jobs[IDS[0]])[1]['state'], 'removed')
        self.assertEqual(next(x for x in self.call('/api/downloads')[1]['jobs']
                              if x['imdb'] == IDS[0])['state'], 'removed')
        self.assertEqual(self.call('/api/propose', 'POST', {'imdb': IDS[0]},
                         extra={'X-Movie-Night-CSRF': self.c.token(PRINCIPAL)})[0], 409)
        self.assertEqual(self.provider.calls, 0)

    def test_stale_queue_recovery_never_resolves_removed_title(self):
        self.deleted()
        with sqlite3.connect(self.c.db) as db:
            db.execute("UPDATE movie_download_queue SET state='checking',job_id=NULL WHERE imdb=?", (IDS[0],))
        self.c.auto_downloads.recover()
        future = self.c.auto_downloads.future
        if future is not None:
            future.result(timeout=3)
        self.assertEqual(self.provider.calls, 0)
        with sqlite3.connect(self.c.db) as db:
            state = db.execute('SELECT state FROM movie_download_queue WHERE imdb=?', (IDS[0],)).fetchone()
        self.assertEqual(state, ('removed',))
        self.assertFalse(self.paths[IDS[0]].exists())

    def test_refinalize_preserves_picks_without_requeuing_removed_title(self):
        self.deleted()
        self.c.finalize(PRINCIPAL, list(IDS), start_downloads=True,
                        request_id='fixture-new-finalization-0001')
        future = self.c.auto_downloads.future
        if future is not None:
            future.result(timeout=3)
        self.assertEqual(self.c.feedback.saved(PRINCIPAL)['ids'], list(IDS))
        self.assertEqual(self.provider.calls, 0)
        with sqlite3.connect(self.c.db) as db:
            state = db.execute('SELECT state FROM movie_download_queue WHERE imdb=?', (IDS[0],)).fetchone()
        self.assertEqual(state, ('removed',))
        self.assertFalse(self.paths[IDS[0]].exists())


class DeletionActivationTests(unittest.TestCase):
    def test_download_mode_does_not_enable_deletion_by_default(self):
        from fastapi.testclient import TestClient
        with tempfile.TemporaryDirectory(prefix='afz-r55-default-off-') as td:
            root = Path(td)
            state = root/'state'; state.mkdir(mode=0o700)
            app, c = build_app(state, BACKEND, downloads=True, provider=NoProvider(), media_root=root/'media')
            try:
                self.assertIsNone(c.delete_service)
                with sqlite3.connect(c.index.db) as db:
                    self.assertIsNone(db.execute("SELECT name FROM sqlite_master WHERE name='removed_media'").fetchone())
                with TestClient(app) as client:
                    client.headers['X-AFZ-Review-Principal'] = PRINCIPAL
                    self.assertEqual(client.get(PREFIX + '/api/delete-server/' + IDS[0]).status_code, 404)
                    self.assertEqual(client.post(PREFIX + '/api/delete-server', json={}).status_code, 404)
                    self.assertEqual(client.get(PREFIX + '/api/downloads').status_code, 200)
            finally:
                c.close()

    def test_delete_mode_requires_explicit_download_boundary(self):
        with tempfile.TemporaryDirectory(prefix='afz-r55-no-download-') as td:
            with self.assertRaisesRegex(ValueError, 'requires --downloads'):
                build_app(td, BACKEND, server_delete=True)


if __name__ == '__main__':
    unittest.main()
