"""Owner genre exclusions across editorial, discovery, refill and download paths."""
import json, sqlite3, tempfile, time, unittest
from pathlib import Path
from discovery_policy import EXCLUDED_GENRES, excluded_genres, normalize, screened
from movie_night import shortlist
from publish_reviewed import validate_rows
from reviewed_refill import ReviewedRefill
from feedback import FeedbackStore
from test_downloads import Harness


def row(i=0,genres=None):
    return {'id':'tt'+str(22345+i),'name':'Fixture '+str(i),'year':2024,
            'genres':['Thriller'] if genres is None else genres,'fitTags':[],
            'scareLevel':'low','intensityReviewed':True,'intenseSupernatural':False,
            'synopsis':'A reviewed fixture story.','intensityGuide':'Reviewed fixture intensity.',
            'sources':['https://example.test/fixture']}


def meta():
    return {'id':'tt22345','name':'Fixture','type':'movie','releaseInfo':'2024',
            'released':'2024-01-01T00:00:00Z','genres':['Thriller'],
            'description':'A team investigates an unexplained event.'}


class ExclusionPolicyTests(unittest.TestCase):
    def test_primary_mixed_and_alias_genres_blocked(self):
        for label in ['Animation','Animated','Anime','Cartoon','Drama','drama','DRAMA','Crime / Drama','Dramatic Thriller','Comedy','Dramedy']:
            for payload in [{'genres':['Thriller',label]},{'genres':['Thriller'],'genre':[label]},
                            {'genres':['Thriller'],'links':[{'category':'Genres','name':label}]},
                            {'genres':['Thriller'],'discoveryEvidence':{'genres':[label]}}]:
                with self.subTest(label=label,payload=payload): self.assertTrue(excluded_genres(payload))

    def test_plot_words_do_not_change_genres(self):
        self.assertFalse(excluded_genres(dict(row(),synopsis='A dramatic incident at an animation studio.')))

    def test_editorial_tags_do_not_bypass_filter(self):
        for genre in EXCLUDED_GENRES:
            candidate=dict(row(genres=['Thriller',genre]),fitTags=['suspense','twists'])
            self.assertEqual([],shortlist({'generatedEpoch':100,'movies':[candidate]},100))

    def test_editorial_aliases_cannot_bypass_filter(self):
        for extra in [{'genre':'Drama'},{'links':[{'category':'genres','name':'Animation'}]}, {'discoveryEvidence':{'genres':['Drama']}}]:
            self.assertEqual([],shortlist({'generatedEpoch':100,'movies':[dict(row(),**extra)]},100))

    def test_clean_discovery_still_qualifies(self):
        now=int(time.time());r=normalize(meta(),now)
        self.assertIsNotNone(r);self.assertTrue(screened(r,now))

    def test_discovery_blocks_all_genre_sources(self):
        for genre in EXCLUDED_GENRES:
            for extra in [{'genres':['Thriller',genre]},{'genre':[genre]}, {'links':[{'category':'genres','name':genre}]}]:
                with self.subTest(genre=genre,extra=extra): self.assertIsNone(normalize(dict(meta(),**extra)))

    def test_old_evidence_cannot_reintroduce_excluded_genre(self):
        now=int(time.time());r=normalize(meta(),now)
        r['genres'].append('Drama');r['discoveryEvidence']['genres'].append('Drama')
        self.assertFalse(screened(r,now))
        self.assertEqual([],shortlist({'generatedEpoch':now,'movies':[r]},now))

    def test_publisher_rejects_mixed_excluded_genres(self):
        for genre in EXCLUDED_GENRES:
            with self.subTest(genre=genre),self.assertRaisesRegex(ValueError,'Excluded genres: Animation, Drama, Comedy'):
                validate_rows({'generatedEpoch':100,'movies':[row(genres=['Thriller',genre])]},100,minimum=1)

    def test_publisher_accepts_genre_match_without_theme_tags(self):
        self.assertEqual(1,len(validate_rows({'generatedEpoch':100,'movies':[row()]},100,minimum=1)[0]))

    def test_mixed_old_bank_keeps_eligible_reserves_and_feedback(self):
        with tempfile.TemporaryDirectory() as td:
            state=Path(td);state.chmod(0o700);now=int(time.time())
            feedback=FeedbackStore(state/'preferences.sqlite3')
            feedback.rate('billing-owner',row(),'like')
            before=feedback.ratings('billing-owner')
            current={'generatedEpoch':now,'movies':[row(i) for i in range(3)]}
            bank={'generatedEpoch':now,'movies':[row(5,['Action','Drama']),row(6,['Sci-Fi','Animation']),row(7,['Thriller'])]}
            (state/'reviewed-shortlist.json').write_text(json.dumps(current))
            (state/'reviewed-refill-bank.json').write_text(json.dumps(bank))
            refill=ReviewedRefill(state)
            self.assertEqual(1,refill.status()['available'])
            result=refill.fulfill();self.assertTrue(result['fulfilled']);self.assertEqual(1,result['added'])
            published=json.loads((state/'reviewed-shortlist.json').read_text())
            self.assertTrue(all(not excluded_genres(r) for r in published['movies']))
            self.assertEqual(list(EXCLUDED_GENRES),published['excludedGenres'])
            self.assertEqual(before,feedback.ratings('billing-owner'))


class ExclusionDownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name)
    def tearDown(self):self.h.close();self.tmp.cleanup()
    def block_first(self,genre):self.h.payload['movies'][0]['genres'].append(genre)

    def test_saved_history_retained_but_not_eligible(self):
        before=self.h.controller.feedback.saved('fixture');self.block_first('Drama')
        data=self.h.controller.review('fixture')
        self.assertEqual(list(EXCLUDED_GENRES),data['excludedGenres'])
        self.assertNotIn('tt12345',[r['id'] for r in data['movies']])
        self.assertNotIn('tt12345',data['eligibleIds'])
        self.assertFalse(data['finalized']['valid']);self.assertEqual('genre-filter',data['finalized']['reason'])
        self.assertEqual(['tt12345'],data['finalized']['excludedIds'])
        self.assertEqual(before,self.h.controller.feedback.saved('fixture'))

    def test_finalization_rejects_excluded_before_enqueue(self):
        self.h.controller.enable_auto_downloads()
        for genre in EXCLUDED_GENRES:
            self.h.payload['movies'][0]['genres']=['Action',genre]
            result=self.h.post('finalize',{'ids':['tt12345','tt12346','tt12347'],'startDownloads':True,'requestId':'fixture-exclusion-'+genre})
            self.assertEqual(409,result.status_code)
        self.assertEqual([],self.h.controller.auto_downloads.requests('fixture'))
        self.assertEqual(0,self.h.provider.resolves)

    def test_manual_source_check_rejects_excluded(self):
        self.block_first('Animation')
        self.assertEqual(409,self.h.post('propose',{'imdb':'tt12345'}).status_code)
        self.assertEqual(0,self.h.provider.verifies)

    def test_existing_completed_file_remains_readable(self):
        plan=self.h.plan();self.assertEqual(200,self.h.approve(plan).status_code);self.h.wait(plan)
        self.block_first('Drama')
        self.assertFalse(self.h.controller.review('fixture')['finalized']['valid'])
        self.assertEqual(self.h.body,self.h.client.get('/movie-night/media/tt12345').content)
        jobs=self.h.controller.downloads('fixture')['jobs'];self.assertEqual(1,len(jobs));self.assertTrue(jobs[0]['indexed'])


if __name__=='__main__':unittest.main()
