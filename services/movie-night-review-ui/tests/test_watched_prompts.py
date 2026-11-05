"""Watched in AFZ Nuvio -> confirm-deletion prompt. Disposable files only.

Proves: nothing is ever deleted by a watch report; prompts appear only for
ready server files at >=90% or marked watched; Keep dismisses for good;
Confirm uses the separate R55 two-step delete; owner/Origin/CSRF enforced.
"""
from dataclasses import asdict
import hashlib, json, sqlite3, sys, tempfile, time, unittest
from pathlib import Path
from uuid import uuid4

BASE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BASE / 'src'), str(BASE / 'gateway')]
from fastapi.testclient import TestClient
from movie_night import Choice, ROOT
from review_service import build_app
from watched_prompts import WatchedPrompts

ORIGIN = 'https://movie.example.test:8447'
OWNER = {'x-afz-review-principal': 'billing-owner'}
IDS = ('tt90011', 'tt90012')


class NoProvider:
    def _api(self, *a, **k): raise AssertionError('provider forbidden')


class WatchedPromptTests(unittest.TestCase):
    def build(self, server_delete=True):
        self.tmp = tempfile.TemporaryDirectory(prefix='afz-watched-')
        root = Path(self.tmp.name); root.chmod(0o700)
        state = root / 'state'; state.mkdir(mode=0o700)
        media = root / 'media'; now = int(time.time())
        payload = {'generatedEpoch': now, 'movies': [
            {'id': i, 'name': 'Sample ' + i, 'year': 2024, 'genres': ['Action'], 'scareLevel': 'low',
             'intensityReviewed': True, 'intenseSupernatural': False, 'fitTags': ['twists']} for i in IDS]}
        (state / 'reviewed-shortlist.json').write_text(json.dumps(payload))
        self.app, self.c = build_app(state, ORIGIN, downloads=True, provider=NoProvider(),
                                     media_root=media, server_delete=server_delete)
        self.c.clock = lambda: now
        if server_delete: self.c.delete_service.clock = lambda: now
        self.body = b'disposable fixture, not a movie'
        self.paths = {}
        for imdb in IDS:
            name = imdb + '.2024.mkv'; path = media / 'Movies' / name; path.write_bytes(self.body)
            self.paths[imdb] = path
            choice = Choice(imdb, 'Sample ' + imdb, 2024, 'Theatrical', 'torbox', 12, 3, 'S.2024.1080p.mkv',
                            '1080p', 'AVC', len(self.body), ROOT + '/' + name)
            with sqlite3.connect(self.c.index.db) as db:
                db.execute('INSERT INTO media VALUES(?,?,?,?,?,1)', (imdb, name, json.dumps(asdict(choice)),
                           len(self.body), hashlib.sha256(self.body).hexdigest()))
        self.client = TestClient(self.app, base_url=ORIGIN)
        self.csrf = self.client.get('/movie-night/api/add-session', headers=OWNER).json()['csrfToken']
        self.addCleanup(self.tmp.cleanup)

    def post(self, path, data, **extra):
        headers = {**OWNER, 'origin': ORIGIN, 'x-movie-night-csrf': self.csrf, **extra}
        return self.client.post('/movie-night/api/' + path, json=data, headers=headers)

    def prompts(self):
        r = self.client.get('/movie-night/api/downloads', headers=OWNER)
        self.assertEqual(r.status_code, 200)
        return r.json()['watchedPrompts']

    def test_partial_progress_is_not_watched(self):
        self.build()
        r = self.post('feedback', {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 89})
        self.assertEqual(r.json()['watched'], False)
        self.assertEqual(self.prompts()['prompts'], [])

    def test_90_percent_prompts_but_deletes_nothing(self):
        self.build()
        r = self.post('feedback', {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 92})
        self.assertEqual(r.json(), {'imdb': IDS[0], 'watched': True, 'kept': False, 'onServer': True, 'deleteAvailable': True})
        info = self.prompts()
        self.assertEqual([p['imdb'] for p in info['prompts']], [IDS[0]])
        self.assertTrue(info['deleteAvailable'])
        self.assertTrue(all(p.read_bytes() == self.body for p in self.paths.values()))
        meta = self.client.get('/movie-night/catalog/movie/downloaded.json', headers=OWNER).json()['metas']
        self.assertEqual(sorted(m['id'] for m in meta), sorted(IDS))

    def test_marked_watched_prompts(self):
        self.build()
        self.post('feedback', {'action': 'report-watched', 'imdb': IDS[1], 'progressPercent': 0, 'watched': True})
        self.assertEqual(self.prompts()['prompts'][0]['source'], 'marked')

    def test_keep_dismisses_for_good(self):
        self.build()
        self.post('feedback', {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 100})
        self.assertEqual(self.post('feedback', {'action': 'keep-watched', 'imdb': IDS[0]}).status_code, 200)
        self.assertEqual(self.prompts()['prompts'], [])
        again = self.post('feedback', {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 100}).json()
        self.assertTrue(again['kept'])
        self.assertEqual(self.prompts()['prompts'], [])
        self.assertTrue(self.paths[IDS[0]].is_file())

    def test_confirm_uses_two_step_delete_and_clears_prompt(self):
        self.build()
        self.post('feedback', {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 95})
        preview = self.client.get('/movie-night/api/delete-server/' + IDS[0], headers=OWNER).json()
        self.assertTrue(self.paths[IDS[0]].is_file())
        wrong = self.post('delete-server', {'imdb': IDS[0], 'confirmationToken': preview['confirmationToken'], 'confirmedTitle': 'nope'})
        self.assertNotEqual(wrong.status_code, 200)
        self.assertTrue(self.paths[IDS[0]].is_file())
        preview = self.client.get('/movie-night/api/delete-server/' + IDS[0], headers=OWNER).json()
        ok = self.post('delete-server', {'imdb': IDS[0], 'confirmationToken': preview['confirmationToken'], 'confirmedTitle': preview['title']})
        self.assertEqual(ok.status_code, 200, ok.text)
        self.assertFalse(self.paths[IDS[0]].exists())
        self.assertTrue(self.paths[IDS[1]].is_file())
        self.assertEqual(self.prompts()['prompts'], [])

    def test_titles_not_on_server_are_ignored(self):
        self.build()
        r = self.post('feedback', {'action': 'report-watched', 'imdb': 'tt99999', 'progressPercent': 100}).json()
        self.assertEqual(r, {'imdb': 'tt99999', 'watched': False, 'onServer': False})
        with sqlite3.connect(self.c.db) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM movie_watched_prompts').fetchone()[0], 0)

    def test_requires_owner_origin_and_csrf(self):
        self.build()
        data = {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 100}
        self.assertEqual(self.post('feedback', data, origin='https://evil.test').status_code, 403)
        self.assertEqual(self.post('feedback', data, **{'x-movie-night-csrf': 'bad'}).status_code, 403)
        r = self.client.post('/movie-night/api/feedback', json=data, headers={'origin': ORIGIN, 'x-movie-night-csrf': self.csrf})
        self.assertEqual(r.status_code, 403)
        self.assertEqual(self.prompts()['prompts'], [])

    def test_invalid_input_rejected(self):
        self.build()
        for bad in ({'imdb': '../x', 'progressPercent': 100}, {'imdb': IDS[0], 'progressPercent': 101},
                    {'imdb': IDS[0], 'progressPercent': True}, {'imdb': IDS[0], 'progressPercent': 'x'},
                    {'imdb': IDS[0], 'progressPercent': 95, 'watched': 'yes'}):
            self.assertEqual(self.post('feedback', {'action': 'report-watched', **bad}).status_code, 400, bad)

    def test_delete_off_still_prompts_without_confirm(self):
        self.build(server_delete=False)
        self.post('feedback', {'action': 'report-watched', 'imdb': IDS[0], 'progressPercent': 100})
        info = self.prompts()
        self.assertFalse(info['deleteAvailable'])
        self.assertEqual(len(info['prompts']), 1)
        self.assertEqual(self.client.get('/movie-night/api/delete-server/' + IDS[0], headers=OWNER).status_code, 404)

    def test_store_keeps_highest_progress(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        w = WatchedPrompts(Path(tmp.name) / 'p.sqlite3', lambda: 1)
        w.report('o', IDS[0], 99); w.report('o', IDS[0], 91)
        self.assertEqual(w.pending('o', {IDS[0]: 'T'})[0]['progressPercent'], 99)
        self.assertEqual(w.pending('other', {IDS[0]: 'T'}), [])


if __name__ == '__main__':
    unittest.main()
