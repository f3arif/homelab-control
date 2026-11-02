"""Direct web/native title admission uses real controller and HTTP boundaries, fixture metadata only."""
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from discovery_policy import normalize
from metadata_discovery import CinemetaDiscovery
from similar_movies import CinemetaSimilar, SuggestionStore
from test_downloads import Harness
from test_similar_movies import MetadataFixture, movie


class DirectAddTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.h = Harness(self.tmp.name)
        self.c = self.h.controller
        self.c.clock = time.time
        self.h.payload['generatedEpoch'] = int(time.time())
        self.metadata = MetadataFixture()
        self.c.similar.source = CinemetaSimilar(CinemetaDiscovery(self.metadata))
        self.network = patch('socket.create_connection', side_effect=AssertionError('real network forbidden'))
        self.network.start()

    def tearDown(self):
        self.h.close()
        self.network.stop()
        self.tmp.cleanup()

    def start(self, imdb='tt90000001', **extra):
        return self.h.post('feedback', dict(action='add-title', imdb=imdb, **extra))

    def finish(self, response):
        self.assertEqual(200, response.status_code, response.text)
        pending = response.json()
        try:
            self.c.similar.jobs[pending['jobId']]['future'].result(5)
        except Exception:
            pass  # HTTP status must sanitize the actual asynchronous error.
        return self.h.post('feedback', dict(action='similar-status', jobId=pending['jobId']))

    def test_direct_add_persists_verified_movie_without_finalizing_or_downloading(self):
        before = self.c.feedback.saved('fixture')
        response = self.finish(self.start(name='FORGED', type='series', genres=['Fake']))
        self.assertEqual(200, response.status_code, response.text)
        result = response.json()
        self.assertTrue(result['added'])
        self.assertFalse(result['alreadyAdded'])
        self.assertEqual('Dream Mission 1', result['movie']['name'])
        self.assertEqual('tt90000001', result['movie']['id'])
        self.assertEqual(['tt90000001'], [r['id'] for r in SuggestionStore(self.c.db.parent).read()])
        self.assertIn('tt90000001', [r['id'] for r in self.c.review('fixture')['movies']])
        self.assertEqual(before, self.c.feedback.saved('fixture'))
        self.assertEqual(0, self.h.provider.resolves)
        self.assertEqual([], self.h.client.get('/movie-night/api/downloads').json()['jobs'])
        self.assertFalse(list(self.h.media.glob('*')))

    def test_existing_manual_selection_policy_keeps_explicit_older_and_mixed_genre_choice(self):
        for identity in ['tt90000000', 'tt90000003']:
            response = self.finish(self.start(identity))
            self.assertEqual(200, response.status_code, response.text)
        self.assertEqual({'tt90000000', 'tt90000003'}, {r['id'] for r in self.c.similar.store.read()})

    def test_duplicate_request_is_one_job_and_does_not_rewrite_or_repeat_metadata(self):
        self.metadata.delay = 0.1  # Prove in-flight requests share one actual lookup.
        first = self.start()
        second = self.start()
        self.assertEqual(first.json()['jobId'], second.json()['jobId'])
        self.assertEqual(200, self.finish(first).status_code)
        file = self.c.similar.store.path
        stamp = file.stat().st_mtime_ns
        calls = list(self.metadata.calls)
        self.c.similar.jobs.clear()  # A later app/page session still deduplicates on disk.
        response = self.finish(self.start()).json()
        self.assertTrue(response['alreadyAdded'])
        self.assertEqual(stamp, file.stat().st_mtime_ns)
        self.assertEqual(calls, self.metadata.calls)
        self.assertEqual(1, len(self.c.similar.store.read()))

    def test_stale_manual_metadata_is_refreshed_without_losing_other_titles(self):
        old = normalize(movie(1), int(time.time()) - 31 * 86400, unrestricted=True)
        self.c.similar.store.add(old)
        self.c.similar.store.add(normalize(movie(2), unrestricted=True))
        response = self.finish(self.start())
        self.assertEqual(200, response.status_code, response.text)
        rows = self.c.similar.store.read()
        self.assertEqual({'tt90000001', 'tt90000002'}, {r['id'] for r in rows})
        self.assertGreater(next(r for r in rows if r['id'] == 'tt90000001')['discoveryEvidence']['fetchedEpoch'], old['discoveryEvidence']['fetchedEpoch'])

    def test_invalid_identifiers_are_rejected_before_metadata_or_file_write(self):
        for identity in [None, 42, '', 'tmdb:123', 'tt1234', 'tt12345/path', 'https://evil.test', 'tt12345\n']:
            with self.subTest(identity=identity):
                self.assertEqual(400, self.start(identity).status_code)
        self.assertFalse(self.metadata.calls)
        self.assertFalse(self.c.similar.store.path.exists())

    def test_series_and_mismatched_metadata_fail_closed(self):
        self.assertEqual(400, self.finish(self.start('tt90000005')).status_code)
        self.c.similar.jobs.clear()
        self.c.similar.source = CinemetaSimilar(CinemetaDiscovery(lambda _: {'meta': movie(2)}))
        self.assertEqual(400, self.finish(self.start()).status_code)
        self.assertFalse(self.c.similar.store.path.exists())

    def test_future_or_incomplete_release_metadata_is_not_admitted(self):
        self.c.similar.source = CinemetaSimilar(CinemetaDiscovery(lambda _: {'meta': movie(1, released='2099-01-01T00:00:00Z')}))
        self.assertEqual(400, self.finish(self.start()).status_code)
        self.assertFalse(self.c.similar.store.path.exists())

    def test_seen_and_not_for_me_feedback_remains_authoritative(self):
        for value in ['seen', 'dislike']:
            self.c.feedback.rate('fixture', {'id':'tt90000001', 'name':'Fixture'}, value)
            response = self.finish(self.start())
            self.assertEqual(400, response.status_code, response.text)
            self.assertIn('Undo that feedback first', response.json()['detail'])
            self.c.similar.jobs.clear()
        self.assertFalse(self.c.similar.store.path.exists())

    def test_csrf_origin_and_identity_are_required(self):
        data = {'action':'add-title','imdb':'tt90000001'}
        for headers in [{'origin':'http://evil.test'}, {'origin':'http://testserver','x-movie-night-csrf':'wrong'}]:
            self.assertEqual(403, self.h.client.post('/movie-night/api/feedback', json=data, headers=headers).status_code)
        self.h.client.headers.pop('x-fixture')
        self.assertEqual(403, self.start().status_code)
        self.assertEqual(403, self.h.client.get('/movie-night/api/add-session').status_code)
        self.assertFalse(self.metadata.calls)

    def test_native_session_is_owner_bound_private_and_uses_existing_csrf_token(self):
        response = self.h.client.get('/movie-night/api/add-session')
        self.assertEqual(200, response.status_code)
        self.assertIn('no-store', response.headers['cache-control'])
        self.assertEqual({'version':1,'addEnabled':True,'csrfToken':self.h.headers['x-movie-night-csrf']}, response.json())
        self.assertTrue(self.c.review('fixture')['directAddEnabled'])

    def test_disabled_review_does_not_admit_or_advertise_addition(self):
        self.c.review_enabled = False
        self.assertFalse(self.h.client.get('/movie-night/api/add-session').json()['addEnabled'])
        self.assertFalse(self.c.review('fixture')['directAddEnabled'])
        self.assertEqual(400, self.start().status_code)
        self.assertFalse(self.metadata.calls)

    def test_disk_failure_is_not_a_success_acknowledgment(self):
        with patch.object(self.c.similar.store, 'add', side_effect=OSError('private path must not leak')):
            response = self.finish(self.start())
        self.assertEqual(400, response.status_code)
        self.assertIn('could not be saved', response.json()['detail'])
        self.assertNotIn('private path', response.text)
        self.assertFalse(self.c.similar.store.path.exists())

    def test_upstream_failure_is_sanitized_and_can_be_retried(self):
        self.metadata.fail = True
        response = self.finish(self.start())
        self.assertEqual(400, response.status_code)
        self.assertNotIn('private upstream', response.text)
        self.metadata.fail = False
        self.assertEqual(200, self.finish(self.start()).status_code)

    def test_another_owner_cannot_read_the_job(self):
        response = self.start()
        with self.assertRaises(ValueError):
            self.c.similar.status('another-owner', response.json()['jobId'])
        self.assertEqual(200, self.finish(response).status_code)

    def test_new_add_after_success_rechecks_later_feedback(self):
        self.assertEqual(200, self.finish(self.start()).status_code)
        self.c.feedback.rate('fixture', {'id':'tt90000001','name':'Fixture'}, 'dislike')
        response = self.finish(self.start())
        self.assertEqual(400, response.status_code)
        self.assertIn('Undo that feedback first', response.text)

    def test_rejected_add_can_be_retried_immediately_after_feedback_is_restored(self):
        self.c.feedback.rate('fixture', {'id':'tt90000001','name':'Fixture'}, 'seen')
        self.assertEqual(400, self.finish(self.start()).status_code)
        self.c.feedback.rate('fixture', {'id':'tt90000001','name':'Fixture'}, 'clear')
        self.assertEqual(200, self.finish(self.start()).status_code)


class ProductionDirectAddRoutesTests(unittest.TestCase):
    def setUp(self):
        from fastapi.testclient import TestClient
        from review_service import build_app
        self.tmp = tempfile.TemporaryDirectory()
        app, self.controller = build_app(self.tmp.name, 'http://testserver')
        self.metadata = MetadataFixture()
        self.controller.similar.source = CinemetaSimilar(CinemetaDiscovery(self.metadata))
        self.client = TestClient(app)
        self.owner = {'x-afz-review-principal': 'billing-owner'}

    def tearDown(self):
        self.client.close()
        self.controller.close()
        self.tmp.cleanup()

    def test_production_route_filter_allows_native_session_and_persisted_add(self):
        response = self.client.get('/movie-night/api/add-session', headers=self.owner)
        self.assertEqual(200, response.status_code, response.text)
        headers = dict(self.owner, origin='http://testserver', **{'x-movie-night-csrf': response.json()['csrfToken']})
        before = self.controller.feedback.saved('billing-owner')
        response = self.client.post('/movie-night/api/feedback', json={'action':'add-title','imdb':'tt90000001'}, headers=headers)
        self.assertEqual(200, response.status_code, response.text)
        job = response.json()['jobId']
        self.controller.similar.jobs[job]['future'].result(5)
        result = self.client.post('/movie-night/api/feedback', json={'action':'similar-status','jobId':job}, headers=headers)
        self.assertEqual(200, result.status_code, result.text)
        self.assertIs(result.json()['added'], True)
        self.assertEqual(['tt90000001'], [r['id'] for r in SuggestionStore(Path(self.tmp.name)).read()])
        self.assertEqual(before, self.controller.feedback.saved('billing-owner'))
        self.assertIsNone(self.controller.auto_downloads)

    def test_production_native_session_still_requires_owner_and_write_guards(self):
        self.assertEqual(403, self.client.get('/movie-night/api/add-session').status_code)
        response = self.client.get('/movie-night/api/add-session', headers=self.owner)
        self.assertEqual(200, response.status_code)
        self.assertIn('private, no-store', response.headers['cache-control'])
        headers = dict(self.owner, origin='http://evil.test', **{'x-movie-night-csrf':response.json()['csrfToken']})
        self.assertEqual(403, self.client.post('/movie-night/api/feedback', json={'action':'add-title','imdb':'tt90000001'}, headers=headers).status_code)
        self.assertEqual(404, self.client.get('/unlisted-route', headers=self.owner).status_code)
        self.assertFalse(self.metadata.calls)


if __name__ == '__main__':
    unittest.main()
