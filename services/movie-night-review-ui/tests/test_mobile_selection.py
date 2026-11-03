"""Explicit mobile selection must durably authorize just that server download."""
from contextlib import closing
from dataclasses import replace
import json
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from uuid import uuid4

from discovery_policy import normalize
from metadata_discovery import CinemetaDiscovery
from movie_night import ApprovalStore, ROOT
from similar_movies import CinemetaSimilar
from test_downloads import Harness
from test_similar_movies import MetadataFixture


class MobileSelectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.h = Harness(self.tmp.name)
        self.c = self.h.controller
        self.c.clock = time.time
        self.h.payload['generatedEpoch'] = int(time.time())
        self.metadata = MetadataFixture()
        self.c.similar.source = CinemetaSimilar(CinemetaDiscovery(self.metadata))
        self.id = 'tt90000001'
        self.h.choice = replace(self.h.choice, imdb=self.id, title='Dream Mission 1',
                                destination=ROOT + '/' + self.id + '.2024.mkv')
        self.net = patch('socket.create_connection', side_effect=AssertionError('real network forbidden'))
        self.net.start()
        self.c.enable_auto_downloads()
        self.release = threading.Event()

    def tearDown(self):
        self.release.set()
        self.h.close()
        self.net.stop()
        self.tmp.cleanup()

    def start(self, imdb=None, **changes):
        data = dict(action='select-download', imdb=imdb or self.id,
                    requestId=str(uuid4()), retryDownload=False)
        data.update(changes)
        return self.h.post('feedback', data)

    def finish(self, response):
        self.assertEqual(200, response.status_code, response.text)
        job = response.json()['jobId']
        try:
            self.c.similar.jobs[job]['future'].result(5)
        except Exception:
            pass
        return self.h.post('feedback', {'action':'similar-status', 'jobId':job})

    def settle(self):
        end = time.monotonic() + 6
        while time.monotonic() < end:
            if not any(r['state'] in ('queued', 'checking') for r in self.c.auto_downloads.requests('fixture')):
                break
            time.sleep(.01)
        else:
            self.fail('queue did not settle')
        for future in list(self.c.futures.values()):
            future.result(5)
        return self.c.downloads('fixture')

    def count(self, table):
        with sqlite3.connect(self.h.db) as db:
            return db.execute('SELECT count(*) FROM ' + table).fetchone()[0]

    def test_one_selection_downloads_to_existing_worker_without_replacing_group(self):
        saved = self.c.feedback.saved('fixture')
        response = self.finish(self.start())
        self.assertEqual(200, response.status_code, response.text)
        result = response.json()
        self.assertTrue(result['selected'])
        self.assertTrue(result['downloadRequested'])
        self.assertEqual(self.id, result['movie']['id'])
        state = self.settle()
        self.assertEqual(1, len(state['requests']))
        self.assertEqual('nuvio-selection', state['requests'][0]['selectionSource'])
        self.assertEqual(self.id, state['requests'][0]['movie']['id'])
        self.assertEqual('Dream Mission 1', state['requests'][0]['movie']['name'])
        self.assertEqual(1, len(state['jobs']))
        self.assertTrue(state['jobs'][0]['indexed'])
        self.assertEqual(saved, self.c.feedback.saved('fixture'))
        self.assertEqual(1, self.h.provider.resolves)
        with sqlite3.connect(self.h.db) as db:
            proof = json.loads(db.execute('SELECT payload FROM jobs').fetchone()[0])
        self.assertEqual('movie-night-selection', proof['authorization'])
        self.assertEqual(self.h.body, self.h.client.get('/movie-night/media/' + self.id).content)

    def test_request_replay_and_later_taps_never_duplicate_a_transfer(self):
        key = str(uuid4())
        self.assertEqual(200, self.finish(self.start(requestId=key)).status_code)
        self.settle()
        for changes in [dict(requestId=key), {}, dict(retryDownload=True)]:
            self.assertEqual(200, self.finish(self.start(**changes)).status_code)
            self.settle()
        self.assertEqual(1, self.count('movie_download_queue'))
        self.assertEqual(1, self.count('jobs'))
        self.assertEqual(1, self.h.provider.resolves)

    def test_old_add_and_reads_never_select_or_start_a_download(self):
        r = self.h.post('feedback', {'action':'add-title', 'imdb':self.id})
        self.assertEqual(200, self.finish(r).status_code)
        for url in ['/movie-night/api/shortlist', '/movie-night/api/add-session', '/movie-night/api/downloads']:
            self.assertEqual(200, self.h.client.get(url).status_code)
        self.assertEqual(0, self.count('movie_mobile_selections'))
        self.assertEqual(0, self.count('movie_download_queue'))
        self.assertEqual(0, self.h.provider.resolves)

    def test_selection_and_queue_rollback_together(self):
        with patch.object(self.c.auto_downloads, 'enqueue', side_effect=sqlite3.OperationalError('PRIVATE')):
            response = self.finish(self.start())
        self.assertNotEqual(200, response.status_code)
        self.assertNotIn('PRIVATE', response.text)
        self.assertEqual(0, self.count('movie_mobile_selections'))
        self.assertEqual(0, self.count('movie_download_queue'))
        self.assertEqual(0, self.h.provider.resolves)

    def test_unavailable_requires_explicit_retry_and_never_claims_ready(self):
        self.c.choices = lambda _: []
        self.assertEqual(200, self.finish(self.start()).status_code)
        self.assertEqual('unavailable', self.settle()['requests'][0]['state'])
        self.c.choices = lambda _: [self.h.choice]
        response = self.finish(self.start()).json()
        self.assertEqual('unavailable', response['download']['state'])
        self.assertTrue(response['download']['canRetry'])
        self.settle()
        self.assertEqual(0, self.h.provider.resolves)
        self.assertEqual(200, self.finish(self.start(retryDownload=True)).status_code)
        self.assertTrue(self.settle()['jobs'][0]['indexed'])

    def test_seen_or_disliked_selection_is_rejected(self):
        for value in ['seen', 'dislike']:
            self.c.feedback.rate('fixture', {'id':self.id, 'name':'Fixture'}, value)
            response = self.finish(self.start())
            self.assertEqual(400, response.status_code)
        self.assertEqual(0, self.count('movie_download_queue'))

    def test_feedback_during_source_lookup_prevents_transfer(self):
        entered = threading.Event()
        def choices(_):
            entered.set()
            self.release.wait(5)
            return [self.h.choice]
        self.c.choices = choices
        self.assertEqual(200, self.finish(self.start()).status_code)
        self.assertTrue(entered.wait(2))
        self.c.rate('fixture', self.id, 'seen')
        self.release.set()
        self.settle()
        self.assertEqual(0, self.h.provider.resolves)
        self.assertEqual(0, self.count('jobs'))

    def test_cancel_and_stale_replay_do_not_restart_request(self):
        entered = threading.Event()
        def choices(_):
            entered.set()
            self.release.wait(5)
            return [self.h.choice]
        self.c.choices = choices
        key = str(uuid4())
        self.assertEqual(200, self.finish(self.start(requestId=key)).status_code)
        self.assertTrue(entered.wait(2))
        request = self.c.auto_downloads.requests('fixture')[0]
        self.assertEqual(200, self.h.post('cancel', {'requestId':request['id']}).status_code)
        self.release.set()
        self.settle()
        response = self.finish(self.start(requestId=key)).json()
        self.assertEqual('cancelled', response['download']['state'])
        self.assertEqual(0, self.h.provider.resolves)

    def test_queued_selection_survives_queue_reconstruction(self):
        queue = self.c.auto_downloads
        with patch.object(queue, 'start'):
            self.assertEqual(200, self.finish(self.start()).status_code)
        queue.close()
        self.c.enable_auto_downloads()
        self.assertTrue(self.settle()['jobs'][0]['indexed'])
        self.assertEqual(1, self.h.provider.resolves)

    def test_disabled_downloads_and_bad_intents_do_not_lookup_or_queue(self):
        self.c.enabled = False
        self.assertEqual(400, self.start().status_code)
        self.c.enabled = True
        for changes in [dict(requestId='bad'), dict(retryDownload='true'), dict(imdb='tmdb:42')]:
            self.assertEqual(400, self.start(**changes).status_code)
        self.assertFalse(self.metadata.calls)
        self.assertEqual(0, self.count('movie_download_queue'))

    def test_owner_origin_csrf_and_request_metadata_are_isolated(self):
        data = dict(action='select-download', imdb=self.id, requestId=str(uuid4()), retryDownload=False)
        for headers in [dict(self.h.headers, origin='https://evil.invalid'), dict(self.h.headers, **{'x-movie-night-csrf':'wrong'})]:
            self.assertEqual(403, self.h.client.post('/movie-night/api/feedback', json=data, headers=headers).status_code)
        self.assertEqual(200, self.finish(self.start()).status_code)
        self.settle()
        self.assertEqual([], self.c.downloads('other-owner')['requests'])
        self.assertEqual([], self.c.downloads('other-owner')['jobs'])

    def test_capability_only_advertised_with_active_download_queue(self):
        self.assertTrue(self.h.client.get('/movie-night/api/add-session').json()['selectionDownloadEnabled'])
        self.c.enabled = False
        self.assertFalse(self.h.client.get('/movie-night/api/add-session').json()['selectionDownloadEnabled'])

    def test_retained_old_requests_do_not_create_a_lifetime_selection_limit(self):
        with sqlite3.connect(self.h.db) as db:
            for i in range(100):
                identity = 'tt8' + str(i).zfill(6)
                db.execute('INSERT INTO movie_mobile_selections VALUES(?,?,?,?)',
                           ('fixture', identity, json.dumps({'id':identity,'name':'Historical fixture'}), 1))
                db.execute('INSERT INTO movie_download_queue VALUES(?,?,?,?,?,NULL,?,?)',
                           (str(uuid4()), 'fixture', identity, 'Historical fixture', 'cancelled', '', 1))
        self.assertEqual(200, self.finish(self.start()).status_code)
        self.assertTrue(self.settle()['jobs'][0]['indexed'])
        self.assertEqual(1, self.h.provider.resolves)


if __name__ == '__main__':
    unittest.main()
