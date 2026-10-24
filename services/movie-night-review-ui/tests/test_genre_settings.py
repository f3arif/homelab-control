"""Editable preferences must affect discovery and eligibility, never acquire media."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch
from genre_settings import (GENRES, GenreSettingsStore, SettingsConflict, defaults,
                            excluded_genres, genre_match, validate_settings)
from discovery_policy import normalize, screened
from metadata_discovery import CinemetaDiscovery, DiscoveryUnavailable
from movie_night import shortlist
from publish_reviewed import publish, validate_rows
from reviewed_refill import ReviewedRefill
from discovery_refill import DiscoveryRefill
from feedback import FeedbackStore, rank_reviewed
from test_genre_exclusions import row, meta
from test_downloads import Harness


def settings(included=None, excluded=None, revision=0):
    return {'included': included or [], 'excluded': excluded or [], 'revision': revision}


class EditableGenreTests(unittest.TestCase):
    def test_defaults_and_read_do_not_create_state(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(defaults(), GenreSettingsStore(td).read())
            self.assertEqual([], list(Path(td).iterdir()))

    def test_persistence_permissions_and_idempotent_save(self):
        with tempfile.TemporaryDirectory() as td:
            store = GenreSettingsStore(td)
            saved = store.save(settings(['Drama'], ['Horror']))
            self.assertEqual(1, saved['revision'])
            self.assertEqual(saved, GenreSettingsStore(td).read())
            self.assertEqual(0o600, store.path.stat().st_mode & 0o777)
            self.assertEqual(saved, store.save(saved))

    def test_concurrent_saves_have_one_winner(self):
        with tempfile.TemporaryDirectory() as td:
            def attempt(genre):
                try: return GenreSettingsStore(td).save(settings([genre]))
                except SettingsConflict: return None
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(attempt, ['Drama', 'Animation']))
            self.assertEqual(1, sum(x is not None for x in results))
            self.assertEqual(1, GenreSettingsStore(td).read()['revision'])

    def test_invalid_preferences_rejected_before_write(self):
        invalid = [None, {}, settings(['NoSuchGenre']), settings(['Drama', 'Drama']),
                   settings(['Drama'], ['Drama']), settings([], list(GENRES)),
                   settings(revision=True), settings(revision=-1), settings(revision=2**53),
                   dict(settings(), extra='ignored'), settings('<script>')]
        with tempfile.TemporaryDirectory() as td:
            for value in invalid:
                with self.subTest(value=value), self.assertRaises(ValueError):
                    GenreSettingsStore(td).save(value)
            self.assertEqual([], list(Path(td).iterdir()))

    def test_corrupt_or_symlink_settings_do_not_reset_to_defaults(self):
        with tempfile.TemporaryDirectory() as td:
            store = GenreSettingsStore(td); store.path.write_text('{broken')
            with self.assertRaises(ValueError): store.read()
            with self.assertRaises(ValueError): store.save(settings(['Drama']))
            store.path.unlink(); target = Path(td)/'target'; target.write_text(json.dumps(defaults()))
            store.path.symlink_to(target)
            with self.assertRaises(ValueError): store.read()

    def test_adding_removing_and_empty_filters(self):
        candidate = row(genres=['Crime', 'Drama'])
        self.assertFalse(genre_match(candidate))
        self.assertTrue(genre_match(candidate, settings(['Drama'])))
        self.assertFalse(genre_match(candidate, settings(['Drama'], ['Crime'])))
        self.assertTrue(genre_match(candidate, settings()))
        self.assertFalse(genre_match(row(genres=['Romance']), settings(['Action'])))

    def test_mixed_aliases_follow_selected_exclusion(self):
        for label, genre in [('Animated', 'Animation'), ('Dramatic Thriller', 'Drama'),
                             ('Science Fiction', 'Sci-Fi'), ('Mystery & Thriller', 'Mystery'),
                             ('Crime / Drama', 'Crime'), ('Dramedy', 'Comedy')]:
            value = {'genres': ['Action'], 'links': [{'category': 'Genres', 'name': label}]}
            self.assertTrue(excluded_genres(value, settings([], [genre])))
            self.assertFalse(excluded_genres(value, settings()))
        self.assertFalse(excluded_genres(dict(row(), synopsis='A dramatic animation studio.'), settings([], ['Drama'])))

    def test_every_genre_can_be_included_or_excluded(self):
        for genre in GENRES:
            with self.subTest(genre=genre):
                self.assertTrue(genre_match(row(genres=[genre]), settings([genre])))
                self.assertFalse(genre_match(row(genres=[genre]), settings([], [genre])))

    def test_discovery_and_evidence_allow_user_enabled_genres(self):
        for genre in ['Drama', 'Animation', 'Comedy', 'Romance', 'Documentary']:
            prefs = settings([genre]); candidate = dict(meta(), genres=[genre])
            found = normalize(candidate, genre_settings=prefs)
            self.assertIsNotNone(found)
            self.assertTrue(screened(found, genre_settings=prefs))
            self.assertIsNone(normalize(candidate, genre_settings=settings([], [genre])))
            self.assertEqual(1, len(validate_rows({'generatedEpoch': int(time.time()), 'movies': [found]}, int(time.time()), minimum=1, genre_settings=prefs)[0]))

    def test_legacy_fixed_title_veto_is_not_an_uneditable_filter(self):
        candidate = dict(meta(), id='tt14060094', genres=['Drama'])
        self.assertIsNotNone(normalize(candidate, genre_settings=settings(['Drama'])))

    def test_retained_title_returns_when_genre_reenabled(self):
        payload = {'generatedEpoch':100, 'movies':[], 'retainedIneligibleSelections':[row(genres=['Drama'])]}
        self.assertEqual([], shortlist(payload,100))
        self.assertEqual(1,len(shortlist(payload,100,genre_settings=settings(['Drama']))))

    def test_likes_use_selected_genres_without_theme_similarity(self):
        ratings = {'tt99999':{'value':'like','metadata':{'genres':['Romance']}}}
        candidates = [row(1,['Action']), row(2,['Romance'])]
        ranked = rank_reviewed(candidates,ratings,genre_settings=settings())
        self.assertEqual(candidates[1]['id'],ranked[0]['id'])
        self.assertTrue(all(r['similarToLiked'] is False for r in ranked))

    def test_discovery_catalogs_follow_settings_and_keep_path_allowlist(self):
        paths = []
        def transport(path):
            paths.append(path)
            return {'metas':[dict(meta(), genres=['Animation'])]} if '/catalog/' in path else {'meta':dict(meta(), genres=['Animation'])}
        discovery = CinemetaDiscovery(transport)
        result = discovery.discover(set(),{},genre_settings=settings(['Animation']))
        self.assertEqual(1,len(result['movies']))
        self.assertTrue(all('genre=Animation' in p for p in paths if '/catalog/' in p))
        for bad in ['https://bad.test/meta/movie/tt12345.json','/catalog/movie/top/genre=../Drama.json','/catalog/movie/top/genre=Drama&bad=1.json']:
            with self.assertRaises(DiscoveryUnavailable):discovery.get(bad,time.monotonic()+1)

    def test_publisher_preserves_filtered_titles_for_later_reenable(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td);state.chmod(0o700);FeedbackStore(state/'preferences.sqlite3')
            now=int(time.time());target=state/'reviewed-shortlist.json'
            target.write_text(json.dumps({'generatedEpoch':now,'movies':[row(1,['Drama']),row(2)]}))
            incoming=state/'incoming.json';incoming.write_text(json.dumps({'generatedEpoch':now,'movies':[row(3)]}))
            publish(state,incoming,hashlib.sha256(target.read_bytes()).hexdigest(),refill=True)
            payload=json.loads(target.read_text())
            self.assertEqual([row(1,['Drama'])],payload['genreFilteredMovies'])
            self.assertIn(row(1)['id'],[r['id'] for r in shortlist(payload,now,genre_settings=settings(['Drama']))])

    def test_reviewed_refill_uses_current_saved_genres(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td);state.chmod(0o700);FeedbackStore(state/'preferences.sqlite3');now=int(time.time())
            (state/'reviewed-shortlist.json').write_text(json.dumps({'generatedEpoch':now,'movies':[]}))
            (state/'reviewed-refill-bank.json').write_text(json.dumps({'generatedEpoch':now,'movies':[row(1,['Drama']),row(2,['Action'])]}))
            store=GenreSettingsStore(state);store.save(settings(['Drama']))
            refill=ReviewedRefill(state);self.assertEqual([row(1,['Drama'])],refill.candidates()[3])
            self.assertTrue(refill.fulfill()['fulfilled'])
            self.assertEqual(['Drama'],json.loads((state/'reviewed-shortlist.json').read_text())['movies'][0]['genres'])

    def test_inflight_discovery_cannot_publish_old_settings(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td);state.chmod(0o700);FeedbackStore(state/'preferences.sqlite3');now=int(time.time())
            path=state/'reviewed-shortlist.json';path.write_text(json.dumps({'generatedEpoch':now,'movies':[]}));before=path.read_bytes()
            class Discovery:
                def discover(self,*args,**kwargs):
                    GenreSettingsStore(state).save(settings(['Drama']))
                    return {'movies':[row()], 'cursor':1, 'scanned':1}
            refill=DiscoveryRefill(state,Discovery())
            try:
                refill._run();self.assertEqual(before,path.read_bytes())
                self.assertEqual('settings-changed',refill.saved_status()['outcome'])
                self.assertFalse((state/'reviewed-refill-bank.json').exists())
            finally:refill.close()


class SettingsAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name)
        self.h.controller.enable_auto_downloads()
    def tearDown(self):self.h.close();self.tmp.cleanup()
    def save(self,prefs):return self.h.post('feedback',{'action':'set-genre-settings','settings':prefs})
    def test_save_reload_never_changes_picks_feedback_jobs_or_downloads(self):
        with sqlite3.connect(self.h.db) as db:before='\n'.join(db.iterdump())
        response=self.save(settings(['Drama']))
        self.assertEqual(200,response.status_code,response.text)
        self.assertEqual([],response.json()['movies'])
        self.assertEqual(3,len(response.json()['finalized']['excludedIds']))
        self.assertEqual(['Drama'],self.h.client.get('/movie-night/api/shortlist').json()['genreSettings']['included'])
        with sqlite3.connect(self.h.db) as db:self.assertEqual(before,'\n'.join(db.iterdump()))
        self.assertEqual(0,self.h.provider.resolves)
        self.assertEqual(0,self.h.provider.verifies)
    def test_new_settings_block_finalize_and_manual_source_lookup(self):
        self.assertEqual(200,self.save(settings([],['Action'])).status_code)
        ids=['tt12345','tt12346','tt12347']
        self.assertEqual(409,self.h.post('finalize',{'ids':ids,'startDownloads':True,'requestId':'settings-fixture-request'}).status_code)
        self.assertEqual(409,self.h.post('propose',{'imdb':ids[0]}).status_code)
        self.assertEqual([],self.h.controller.auto_downloads.requests('fixture'))
    def test_reenable_restores_eligibility_without_finalizing_or_enqueueing(self):
        self.save(settings([],['Action']))
        response=self.save(settings(['Action'],revision=1))
        self.assertEqual(200,response.status_code)
        self.assertTrue(response.json()['finalized']['valid'])
        self.assertEqual([],response.json()['downloadRequestedIds'])
    def test_stale_tab_gets_conflict_instead_of_losing_new_settings(self):
        self.save(settings(['Drama']))
        response=self.save(settings(['Animation']))
        self.assertEqual(409,response.status_code)
        self.assertIn('another device',response.json()['detail'])
        self.assertEqual(['Drama'],self.h.controller.genre_settings.read()['included'])
    def test_origin_csrf_and_identity_still_required(self):
        data={'action':'set-genre-settings','settings':settings(['Drama'])}
        self.assertEqual(403,self.h.client.post('/movie-night/api/feedback',json=data).status_code)
        self.assertEqual(403,self.h.client.post('/movie-night/api/feedback',json=data,headers=dict(self.h.headers,origin='https://bad.test')).status_code)
        self.h.client.headers.clear()
        self.assertEqual(403,self.h.client.post('/movie-night/api/feedback',json=data,headers=self.h.headers).status_code)
        self.assertEqual(defaults(),self.h.controller.genre_settings.read())
    def test_invalid_save_is_clear_and_preserves_preferences(self):
        response=self.save(settings(['Drama'],['Drama']))
        self.assertEqual(400,response.status_code)
        self.assertIn('both included and excluded',response.json()['detail'])
        self.assertEqual(defaults(),self.h.controller.genre_settings.read())
    def test_completed_file_survives_filter_change(self):
        plan=self.h.plan();self.h.approve(plan);self.h.wait(plan)
        self.save(settings([],['Action']))
        self.assertEqual(self.h.body,self.h.client.get('/movie-night/media/tt12345').content)


if __name__=='__main__':unittest.main()
