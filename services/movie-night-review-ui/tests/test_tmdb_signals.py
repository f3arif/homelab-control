import json, os, time, unittest
from unittest import mock
from metadata_discovery import CinemetaDiscovery
from test_similar_movies import movie
from urllib.parse import urlparse, parse_qs
from tmdb_signals import TmdbSignals
from similar_movies import CinemetaSimilar, related_score
import test_similar_relevance as rel

KW = lambda *names: {'keywords': [{'id': i, 'name': n} for i, n in enumerate(names, 100)]}
TMDB = {
    '/find/tt29516222': {'movie_results': [{'id': 1}]},
    '/movie/1': {'imdb_id': 'tt29516222', 'keywords': KW('shark', 'deep sea', 'woman director')},
    '/discover/movie': {'results': [{'id': 2}, {'id': 3}]},
    '/movie/1/recommendations': {'results': [{'id': 4}]},
    '/movie/1/similar': {'results': []},
    '/movie/2': {'imdb_id': 'tt4779682', 'keywords': KW('shark', 'deep sea')},      # The Meg
    '/movie/3': {'imdb_id': 'tt4052882', 'keywords': KW('shark')},                  # The Shallows
    '/movie/4': {'imdb_id': 'tt2527338', 'keywords': KW('woman director', 'space')},
}


class Opener:
    def __init__(self, fail=False): self.fail, self.calls = fail, []
    def __call__(self, url):
        u = urlparse(url); self.calls.append(u.path[2:] if u.path.startswith('/3') else u.path)
        if self.fail: raise OSError('down')
        assert parse_qs(u.query)['api_key'] == ['k' * 32]
        return json.dumps(TMDB.get(u.path[2:], {})).encode()


class TmdbSignalsTests(unittest.TestCase):
    def test_related_returns_themes_and_theme_sharing_candidates(self):
        themes, rows = TmdbSignals('k' * 32, Opener()).related('tt29516222', time.monotonic() + 30)
        self.assertEqual({'shark', 'deep sea'}, themes)  # production facts are not themes
        self.assertEqual({'shark', 'deep sea'}, rows['tt4779682'])
        self.assertEqual({'space'}, rows['tt2527338'])

    def test_outage_or_missing_key_yields_nothing(self):
        self.assertEqual((set(), {}), TmdbSignals('k' * 32, Opener(fail=True)).related('tt29516222', time.monotonic() + 30))
        with mock.patch.dict(os.environ, {'TMDB_API_KEY': ''}):
            self.assertIsNone(TmdbSignals.from_env())
            self.assertIsNone(CinemetaSimilar().tmdb)
        with mock.patch.dict(os.environ, {'TMDB_API_KEY': 'not a key'}):
            self.assertIsNone(TmdbSignals.from_env())

    def test_shared_theme_with_a_genre_is_a_match_but_theme_alone_is_not(self):
        seed = dict(rel.SEED, themes={'shark'})
        meg = {'id': 'tt4779682', 'type': 'movie', 'name': 'The Meg', 'genres': ['Action', 'Horror'],
               'description': 'A deep sea submersible is attacked.', 'themes': {'shark'}}
        score, reasons = related_score(seed, meg, {}, 60)
        self.assertGreater(score, 3); self.assertIn('Shared themes: shark', reasons)
        self.assertEqual((0, []), related_score(seed, dict(meg, genres=['Comedy']), {}, 60))

    def test_find_surfaces_tmdb_suggestions_cinemeta_misses(self):
        meg = movie(500, name='The Meg', genres=['Action', 'Horror'], country='China, United States',
                    director=['Jon Turteltaub'], cast=['Jason Statham'], description='A submersible lies at the bottom of the trench.')
        meg['id'] = meg['imdb_id'] = 'tt4779682'
        seed = dict(rel.SEED, id='tt29516222', imdb_id='tt29516222')
        pool = [rel.SHARK] + rel.NOISE + rel.FILLER
        def transport(path):
            if path.startswith('/meta/movie/'):
                return {'meta': next((m for m in [seed, meg] + pool if m['id'] in path), None)}
            return {'metas': [] if '/search=' in path else pool}
        found = CinemetaSimilar(CinemetaDiscovery(transport), TmdbSignals('k' * 32, Opener())).find('tt29516222')
        names = [r['name'] for r in found['rows']]
        self.assertIn('The Meg', names)
        self.assertIn('Shared themes: deep sea, shark', found['reasons']['tt4779682'])
        for noise in rel.NOISE[:3]:
            self.assertNotIn(noise['name'], names)

if __name__ == '__main__':
    unittest.main()
