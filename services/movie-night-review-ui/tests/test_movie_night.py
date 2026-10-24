from dataclasses import replace
import tempfile
import unittest
from pathlib import Path
import sqlite3
from movie_night import *


def choice(**kw):
    return replace(Choice('tt12345', 'Fixture Movie', 2024, 'Theatrical', 'torbox', 12, 3,
                          'Fixture.Movie.1080p.mkv', '1080p', 'HEVC', 5_000_000_000,
                          ROOT + '/Fixture.Movie.2024.mkv'), **kw)


class ApprovalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'prototype.sqlite'
        self.s = ApprovalStore(self.path)
        self.c = choice()
        self.p = self.s.propose(self.c, 'profile:1/chat:1', 1000, 200_000_000_000)

    def tearDown(self):
        self.s.db.close()
        self.tmp.cleanup()

    def approve(self, **kw):
        args = dict(pid=self.p['confirmationId'], binding=self.p['binding'], principal='profile:1/chat:1', reply='yes',
                    current_choice=self.c, provider_checked_at=1000, now=1100, free=200_000_000_000, completed_present=True)
        args.update(kw)
        return self.s.approve(**args)

    def test_requires_yes(self):
        for text in ('next', 'download', 'yes please', '', 'watchlist'):
            with self.subTest(text=text), self.assertRaises(ValueError): self.approve(reply=text)

    def test_bound_to_principal(self):
        with self.assertRaises(ValueError): self.approve(principal='profile:2/chat:2')

    def test_bound_to_confirmation(self):
        with self.assertRaises(ValueError): self.approve(pid='other')

    def test_bound_to_displayed_payload(self):
        with self.assertRaises(ValueError): self.approve(binding='0' * 64)

    def test_size_change(self):
        with self.assertRaises(ValueError): self.approve(current_choice=replace(self.c, size=self.c.size+1))

    def test_file_change(self):
        with self.assertRaises(ValueError): self.approve(current_choice=replace(self.c, file_id=4))

    def test_edition_change(self):
        with self.assertRaises(ValueError): self.approve(current_choice=replace(self.c, edition='Extended'))

    def test_codec_change(self):
        with self.assertRaises(ValueError): self.approve(current_choice=replace(self.c, codec='AVC'))

    def test_destination_change(self):
        with self.assertRaises(ValueError): self.approve(current_choice=replace(self.c, destination=ROOT+'/other.mkv'))

    def test_stale_confirmation(self):
        with self.assertRaises(ValueError): self.approve(now=1900, provider_checked_at=1900)

    def test_stale_provider(self):
        with self.assertRaises(ValueError): self.approve(provider_checked_at=799)

    def test_future_provider(self):
        with self.assertRaises(ValueError): self.approve(provider_checked_at=1101)

    def test_unknown_provider_completion(self):
        with self.assertRaises(ValueError): self.approve(completed_present=None)

    def test_existing_file_preserved(self):
        with self.assertRaises(ValueError): self.approve(existing=True)

    def test_insufficient_space(self):
        with self.assertRaises(ValueError): self.approve(free=RESERVE+self.c.size-1)

    def test_exact_reserve(self):
        self.assertTrue(self.approve(free=RESERVE+self.c.size)['newJob'])

    def test_insufficient_quota(self):
        with self.assertRaises(ValueError): self.approve(quota=self.c.size-1)

    def test_duplicate_yes_is_idempotent(self):
        self.assertTrue(self.approve()['newJob'])
        self.assertFalse(self.approve()['newJob'])
        self.assertEqual(1, self.s.db.execute('SELECT count(*) FROM jobs').fetchone()[0])

    def test_second_confirmation_same_movie(self):
        self.approve()
        p = self.s.propose(self.c, 'profile:1/chat:1', 1000, 200_000_000_000)
        with self.assertRaises(sqlite3.IntegrityError): self.approve(pid=p['confirmationId'], binding=p['binding'])

    def test_durable_restart(self):
        self.approve(); self.s.db.close(); self.s = ApprovalStore(self.path)
        self.assertFalse(self.approve()['newJob'])

    def test_no_execution_on_approval(self):
        result = self.approve()
        self.assertEqual('approved', result['state'])
        self.assertEqual(0, self.s.status(result['id'])['bytesReceived'])

    def test_progress_and_partial_failure(self):
        pid = self.approve()['id']; self.s.transition(pid, 'downloading', bytes_received=123)
        status = self.s.transition(pid, 'failed')
        self.assertEqual(123, status['bytesReceived']); self.assertFalse(status['downloaded'])
        with self.assertRaises(ValueError): self.s.transition(pid, 'downloading')

    def test_cancel_preserves_partial_accounting(self):
        pid = self.approve()['id']; self.s.transition(pid, 'downloading', bytes_received=456)
        self.assertEqual(456, self.s.transition(pid, 'cancelled')['bytesReceived'])

    def test_overrun_blocked(self):
        pid = self.approve()['id']
        with self.assertRaises(ValueError): self.s.transition(pid, 'downloading', bytes_received=self.c.size+1)

    def test_regressive_progress_blocked(self):
        pid = self.approve()['id']; self.s.transition(pid, 'downloading', bytes_received=456)
        with self.assertRaises(ValueError): self.s.transition(pid, 'downloading', bytes_received=455)

    def test_incomplete_validation_blocks_visibility(self):
        pid = self.approve()['id']; self.s.transition(pid, 'downloading')
        with self.assertRaises(ValueError): self.s.transition(pid, 'downloaded', bytes_received=self.c.size)
        with self.assertRaises(ValueError): self.s.transition(pid, 'indexed')

    def test_download_index_playback_are_distinct(self):
        pid = self.approve()['id']; self.s.transition(pid, 'downloading')
        status = self.s.transition(pid, 'downloaded', bytes_received=self.c.size, evidence={'actualSize':self.c.size, 'mediaProbePassed':True,'sha256':'a'*64,'destination':self.c.destination})
        self.assertTrue(status['downloaded']); self.assertFalse(status['indexed']); self.assertFalse(status['playbackTested'])
        with self.assertRaises(ValueError): self.s.transition(pid, 'indexed', evidence={'catalogId':'tt999'})
        status = self.s.transition(pid, 'indexed', evidence={'catalogId':self.c.imdb,'existingRouteVerified':True})
        self.assertTrue(status['indexed']); self.assertFalse(status['playbackTested'])
        with self.assertRaises(ValueError): self.s.transition(pid, 'playback-tested', evidence={})
        self.assertTrue(self.s.transition(pid, 'playback-tested', evidence={'userObservedPlayback':True})['playbackTested'])

    def test_reservations_prevent_concurrent_oversubscription(self):
        self.approve()
        c = choice(imdb='tt777', destination=ROOT+'/other.mkv')
        p = self.s.propose(c, 'profile:1/chat:1', 1000, 200_000_000_000)
        with self.assertRaises(ValueError): self.approve(pid=p['confirmationId'], binding=p['binding'], current_choice=c, free=RESERVE+2*c.size-1)


class RowPolicyTests(unittest.TestCase):
    def test_at_fifteen_gb(self): self.assertEqual(CAP, select_compact([choice(size=CAP)]).size)
    def test_above_fifteen_gb(self): self.assertIsNone(select_compact([choice(size=CAP+1)]))
    def test_unknown_size(self): self.assertIsNone(select_compact([choice(size=None)]))
    def test_zero_size(self): self.assertIsNone(select_compact([choice(size=0)]))
    def test_bool_size(self): self.assertIsNone(select_compact([choice(size=True)]))
    def test_compact_over_larger(self): self.assertEqual(5_000_000_000, select_compact([choice(size=5_000_000_001),choice(size=5_000_000_000)]).size)
    def test_at_least_five_required(self): self.assertEqual(5_000_000_000, select_compact([choice(size=2_000_000_000), choice()]).size)
    def test_small_file_never_used_as_fallback(self): self.assertEqual(8_000_000_000, select_compact([choice(size=2_000_000_000),choice(size=8_000_000_000)]).size)
    def test_wrong_resolution(self): self.assertIsNone(select_compact([choice(quality='2160p')]))
    def test_path_traversal(self): self.assertIsNone(select_compact([choice(destination=ROOT+'/../escape.mkv')]))

    def row(self, **kw):
        r={'id':'tt12345','name':'Fixture Movie','year':2024,'scareLevel':'low','intensityReviewed':True,'intenseSupernatural':False,'fitTags':['twists']};r.update(kw)
        return shortlist({'generatedEpoch':1000,'movies':[r]}, 1100)
    def test_stated_taste_reason(self): self.assertIn('stated preference',self.row()[0]['description'])
    def test_seen_heretic(self): self.assertEqual([], self.row(name='Heretic'))
    def test_seen_companion(self): self.assertEqual([], self.row(name='Companion'))
    def test_no_inferred_talk_to_me_watch(self): self.assertEqual(1,len(self.row(name='Talk to Me')))
    def test_unreviewed_intensity(self): self.assertEqual([],self.row(intensityReviewed=False))
    def test_high_scares(self): self.assertEqual([],self.row(scareLevel='high'))
    def test_supernatural_scares(self): self.assertEqual([],self.row(intenseSupernatural=True))
    def test_unknown_supernatural(self): self.assertEqual([],self.row(intenseSupernatural=None))
    def test_stale_artifact(self): self.assertEqual([],shortlist({'generatedEpoch':1,'movies':[]}, 8*86400))
    def test_no_unearned_reliability(self): self.assertIn('not yet verified',self.row()[0]['description'])
    def test_no_signed_links_exported(self): self.assertNotIn('secret',canonical(self.row(url='https://example/secret',token='secret')))


if __name__ == '__main__': unittest.main(verbosity=2)
