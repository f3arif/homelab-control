"""Explicit searches may cross preferences; only an owner Add grants that scope."""
import copy,time,unittest
from urllib.parse import quote
from discovery_policy import normalize,screened
from genre_settings import defaults
from metadata_discovery import CinemetaDiscovery,DiscoveryUnavailable
from movie_night import shortlist
from similar_movies import CinemetaSimilar,related_score
from test_similar_movies import movie
import test_similar_movies as fixtures


class RelatedDiscoveryTests(unittest.TestCase):
 def test_cross_genre_and_country_evidence(self):
  seed=movie(0,country='India',genres=['Action'],description='An officer hunts terrorist sleeper cells.')
  match=movie(1,country='India',genres=['Drama'],description='A courtroom dispute.',director=[],cast=['Fixture Actor'])
  score,reasons=related_score(seed,match)
  self.assertGreater(score,0);self.assertIn('Same country: India',reasons)
  self.assertFalse(any('Shared genres:' in r for r in reasons))
  foreign=dict(match,country='France');self.assertGreater(score,related_score(seed,foreign)[0])
  self.assertEqual((0,[]),related_score(seed,dict(match,cast=[])))
 def test_cast_and_director_searches_expand_pool_and_verify_identity(self):
  seed=movie(0,genres=['Action'],country='India')
  connected=movie(1,genres=['Drama','Comedy'],releaseInfo='2012',released='2012-03-01T00:00:00Z',country='India')
  literal=movie(2,name='Fixture Actor',genres=[],cast=[],director=[],description='Unrelated.')
  wrong=movie(3)
  calls=[]
  def transport(path):
   calls.append(path)
   if path=='/meta/movie/'+seed['id']+'.json':return {'meta':seed}
   if '/search=' in path:return {'metas':[literal,connected,wrong]}
   if '/catalog/' in path:return {'metas':[]}
   return {'meta':connected} # wrong candidate ID must not be accepted
  result=CinemetaSimilar(CinemetaDiscovery(transport)).find(seed['id'],defaults())
  self.assertEqual([connected['id']],[r['id'] for r in result['rows']])
  self.assertIn('/catalog/movie/top/search='+quote('Fixture Director',safe='')+'.json',calls)
  self.assertIn('/catalog/movie/top/search='+quote('Fixture Actor',safe='')+'.json',calls)
  self.assertNotIn('/meta/movie/'+literal['id']+'.json',calls)
  self.assertEqual('all-genres-and-years',result['searchScope'])
 def test_partial_person_failure_does_not_hide_verified_matches(self):
  seed=movie(0)
  def transport(path):
   if '/search=' in path:raise DiscoveryUnavailable('unavailable')
   if '/catalog/' in path:return {'metas':[movie(1)]}
   return {'meta':seed if path.endswith(seed['id']+'.json') else movie(1)}
  result=CinemetaSimilar(CinemetaDiscovery(transport)).find(seed['id'])
  self.assertTrue(result['partial']);self.assertEqual(1,len(result['rows']))
 def test_unrestricted_validation_keeps_identity_dates_and_metadata_bounds(self):
  old=movie(releaseInfo='1938',released='1938-04-01T00:00:00Z',genres=['Animation','Drama'],scareLevel='high',intenseSupernatural=True)
  self.assertIsNone(normalize(old))
  row=normalize(old,unrestricted=True);self.assertTrue(screened(row,unrestricted=True))
  self.assertFalse(screened(row));self.assertEqual('high',row['scareLevel'])
  for change in [dict(imdb_id='tt99999'),dict(releaseInfo='1800'),dict(released='2099-01-01T00:00:00Z'),dict(type='series'),dict(description='x'*3001)]:
   with self.subTest(change=change):self.assertIsNone(normalize(dict(old,**change),unrestricted=True))
 def test_only_explicit_added_rows_get_preference_override(self):
  now=int(time.time());row=normalize(movie(releaseInfo='2012',released='2012-01-01T00:00:00Z',genres=['Animation','Drama']),unrestricted=True)
  payload={'generatedEpoch':now,'movies':[row]}
  self.assertEqual([],shortlist(payload,now))
  payload['requestedSuggestionIds']=[row['id']]
  found=shortlist(payload,now);self.assertEqual(1,len(found));self.assertTrue(found[0]['manualSuggestion'])
  payload['knownSeenIds']=[row['id']];self.assertEqual([],shortlist(payload,now))
 def test_stale_or_tampered_override_fails_closed(self):
  now=int(time.time());row=normalize(movie(genres=['Animation']),unrestricted=True)
  payload={'generatedEpoch':now,'movies':[row],'requestedSuggestionIds':[row['id']]}
  self.assertEqual([],shortlist(payload,now+31*86400))
  altered=copy.deepcopy(payload);altered['movies'][0]['name']='Forged name'
  self.assertEqual([],shortlist(altered,now))
  altered=copy.deepcopy(payload);altered['movies'][0]['discoveryEvidence']['searchMode']='anything'
  self.assertEqual([],shortlist(altered,now))


class ExplicitSearchWorkflowTests(unittest.TestCase):
 setUp=fixtures.SimilarWorkflowTests.setUp
 tearDown=fixtures.SimilarWorkflowTests.tearDown
 act=fixtures.SimilarWorkflowTests.act
 wait=fixtures.SimilarWorkflowTests.wait
 find=fixtures.SimilarWorkflowTests.find
 dump=fixtures.SimilarWorkflowTests.dump
 def test_added_old_excluded_result_survives_preferences_and_can_finalize(self):
  self.transport.movies[3]=movie(4,releaseInfo='2010',released='2010-01-01T00:00:00Z',genres=['Animation','Drama'])
  original=self.c.genre_settings.read();before=self.dump()
  result=self.find();self.assertIn('tt90000004',[r['id'] for r in result['movies']])
  added=self.act('add-similar',jobId=result['jobId'],imdb='tt90000004')
  self.assertEqual(original,self.c.genre_settings.read())
  self.assertEqual(before,self.dump());self.assertIn('tt90000004',added['eligibleIds'])
  saved=self.c.finalize('fixture',['tt12345','tt12346','tt90000004'])
  self.assertTrue(saved['finalized']['valid']);self.assertNotIn('tt90000004',saved['finalized']['excludedIds'])
  self.assertEqual(0,self.h.provider.resolves)
 def test_watched_and_disliked_stay_visible_but_cannot_be_added(self):
  result=self.find();ids=[r['id'] for r in result['movies']]
  self.c.feedback.rate('fixture',result['movies'][0],'seen')
  self.c.feedback.rate('fixture',result['movies'][1],'dislike')
  self.h.payload['knownSeenIds']=[ids[2]]
  current=self.act('similar-status',jobId=result['jobId'])
  self.assertEqual(ids,[r['id'] for r in current['movies']])
  self.assertEqual(['seen','dislike','known-seen'],[r['selectionBlock'] for r in current['movies'][:3]])
  for imdb in ids[:3]:
   with self.assertRaisesRegex(ValueError,'no longer eligible'):self.act('add-similar',jobId=result['jobId'],imdb=imdb)
  self.assertFalse(self.c.similar.store.path.exists());self.assertEqual(0,self.h.provider.resolves)


if __name__=='__main__':unittest.main()
