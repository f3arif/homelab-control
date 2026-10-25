from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json,sqlite3,tempfile,threading,time,unittest
from unittest.mock import patch
from urllib.parse import quote
from discovery_policy import normalize
from genre_settings import defaults
from metadata_discovery import CinemetaDiscovery,DiscoveryUnavailable
from similar_movies import CinemetaSimilar,SuggestionStore,query_text,reference,related_score,words
from test_downloads import Harness

def movie(i=1,**kw):
 return dict({'id':'tt9000000'+str(i),'name':'Dream Mission '+str(i),'type':'movie','releaseInfo':'2024','released':'2024-02-01T00:00:00Z','genres':['Sci-Fi','Thriller'],'description':'Engineers enter a shared dream to prevent a dangerous mission.','director':['Fixture Director'],'cast':['Fixture Actor'],'runtime':'118 min'},**kw)
class MetadataFixture:
 def __init__(self):
  self.seed=movie(0,name='Original',releaseInfo='2008',released='2008-02-01T00:00:00Z')
  self.movies=[movie(1),movie(2,description='Detectives pursue a criminal across the city.',director=['Another Director'],cast=[]),movie(3,genres=['Thriller','Drama']),movie(4,releaseInfo='2010'),movie(5,type='series')]
  self.calls=[];self.fail=False;self.delay=0
 def __call__(self,path):
  self.calls.append(path)
  if self.delay:time.sleep(self.delay)
  if self.fail:raise DiscoveryUnavailable('private upstream detail must not leak')
  if '/search=' in path:
   if 'Nothing' in path:return {'metas':[]}
   return {'metas':[self.seed,dict(self.seed,id='tt90000009',releaseInfo='2020'),dict(self.seed,type='series')]}
  if '/catalog/' in path:return {'metas':self.movies}
  return {'meta':next((r for r in [self.seed]+self.movies if r['id'] in path),None)}
class SimilarMetadataTests(unittest.TestCase):
 def setUp(self):self.transport=MetadataFixture();self.source=CinemetaSimilar(CinemetaDiscovery(self.transport))
 def test_query_validation_and_encoding(self):
  for value in ['', 'a', None, 'a'*121, 'abc\n', '\u202eTitle']:
   with self.subTest(value=value),self.assertRaises(ValueError):query_text(value)
  q='Amélie & The / Return? #1';self.source.search(q)
  self.assertEqual('/catalog/movie/top/search='+quote(q,safe='')+'.json',self.transport.calls[0])
 def test_disambiguation_and_reference_identity(self):
  self.assertEqual(['2008','2020'],[r['releaseInfo'] for r in self.source.search('Original')])
  self.assertEqual('',reference(movie(releaseInfo='unknown'))['releaseInfo'])
  self.assertIsNone(reference(movie(imdb_id='tt12345')))
 def title_search(self,query,rows):
  return CinemetaSimilar(CinemetaDiscovery(lambda _: {'metas':rows})).search(query)
 def test_partial_title_beyond_old_cutoff_is_prominent(self):
  rows=[movie(i,name='Holiday Touchdown '+str(i)) for i in range(18)]
  rows += [movie(91,id='tt2556308',name='Holiday',releaseInfo='2014'),movie(92,name='Holiday',releaseInfo='1938')]
  found=self.title_search('Holid',rows)
  self.assertEqual(['tt2556308',rows[-1]['id']],[r['id'] for r in found[:2]])
  self.assertEqual(20,len(found))
 def test_exact_title_and_optional_year_disambiguation(self):
  rows=[movie(1,name='Holiday',releaseInfo='1938'),movie(2,name='The Holiday',releaseInfo='2006'),movie(3,name='Holiday',releaseInfo='2014')]
  for query in ['Holiday 2014','Holiday (2014)','Holiday [2014]']:
   with self.subTest(query=query):self.assertEqual(rows[2]['id'],self.title_search(query,rows)[0]['id'])
  self.assertEqual([rows[0]['id'],rows[2]['id'],rows[1]['id']],[r['id'] for r in self.title_search('Holiday',rows)])
  self.assertEqual('1917',self.title_search('1917',[movie(name='1917')])[0]['name'])
 def test_ranking_precedes_limit_and_keeps_nonliteral_alias_matches(self):
  rows=[movie(i,name='Dreamland Adventure '+str(i)) for i in range(99)]
  rows += [movie(100,name='Dreamland')]
  found=self.title_search('Dreamland',rows)
  self.assertEqual(40,len(found));self.assertEqual('Dreamland',found[0]['name'])
  alias=movie(name='Another Display Title');self.assertEqual(alias['id'],self.title_search('Original Language Title',[alias])[0]['id'])
 def test_title_normalization_without_rewriting_display(self):
  rows=[movie(1,name='Amelie Returns'),movie(2,name='Amélie')]
  self.assertEqual('Amélie',self.title_search('AMELIE',rows)[0]['name'])
  rows=[movie(1,name='Spider Man Returns'),movie(2,name='Spider-Man')]
  self.assertEqual('Spider-Man',self.title_search('Spider Man',rows)[0]['name'])
 def test_lookup_bounds_deduplication_and_invalid_rows(self):
  good=movie(1,name='Unique')
  invalid=[None,{},dict(good,type='series'),dict(good,imdb_id='tt99999')]
  rows=invalid+[good,good]+[movie(i) for i in range(2,110)]
  found=self.title_search('Dream Mission',rows)
  self.assertEqual(40,len(found));self.assertEqual(40,len({r['id'] for r in found}))
  self.assertEqual([reference(good)],self.title_search('Unique',invalid+[good,good]))
  rows=[None]*100+[good];self.assertEqual([],self.title_search('Unique',rows))
 def test_results_screened_old_reference_allowed(self):
  r=self.source.find('tt90000000',defaults());self.assertEqual('2008',r['reference']['releaseInfo'])
  self.assertEqual({'tt90000001','tt90000002'},{x['id'] for x in r['rows']})
  self.assertTrue(all(x.get('presentation') for x in r['rows']))
 def test_saved_filters_enable_drama(self):
  r=self.source.find('tt90000000',dict(defaults(),excluded=['Comedy','Animation']))
  self.assertIn('tt90000003',[x['id'] for x in r['rows']])
 def test_conflicting_catalog_and_detail_filters(self):
  def transport(path):
   if '/catalog/' in path:return {'metas':[dict(movie(1),genre=['Drama'])]}
   return self.transport(path)
  self.assertEqual([],CinemetaSimilar(CinemetaDiscovery(transport)).find('tt90000000',defaults())['rows'])
 def test_story_connections_and_honest_genre_only_label(self):
  a,ar=related_score(movie(0),movie(1));b,br=related_score(movie(0),self.transport.movies[1])
  self.assertGreater(a,b);self.assertIn('Genre match only',br[-1]);self.assertTrue(any('Same director' in r for r in ar))
  self.assertEqual((0,[]),related_score(movie(0),movie(genres=['Romance'])))
 def test_generic_words_do_not_beat_shared_director(self):
  seed=movie(0,description='A team steals corporate technology on a secret mission.')
  weak=movie(1,genres=['Thriller'],description='A team steals corporate technology.',director=[],cast=[])
  strong=movie(2,description='Dream espionage with inverted chronology.',cast=[])
  self.assertGreater(related_score(seed,strong,{},100)[0],related_score(seed,weak,{},100)[0])
  self.assertNotIn('team',words(seed));self.assertIn('business',words({'description':'Business engineers encounter a dangerous virus.'}))
 def test_network_path_allowlist(self):
  for p in ['https://evil.test/x','/meta/movie/../x.json','/catalog/movie/top/search=a&url=https://evil.test.json','/catalog/movie/top/search=abc%XX.json']:
   with self.subTest(path=p),self.assertRaises(DiscoveryUnavailable):self.source.metadata.get(p,time.monotonic()+10)
 def test_search_uses_correct_host_no_redirects(self):
  class Response:
   status_code=200;headers={'Content-Type':'application/json'}
   def __enter__(self):return self
   def __exit__(self,*a):pass
   def iter_content(self,*a):yield b'{"metas":[]}'
  with patch('requests.get',return_value=Response()) as get:
   CinemetaSimilar().search('Original');self.assertEqual('https://v3-cinemeta.strem.io/catalog/movie/top/search=Original.json',get.call_args.args[0]);self.assertFalse(get.call_args.kwargs['allow_redirects'])
 def test_reference_preview_descriptive_fields_allow_old_excluded_movie(self):
  self.transport.seed.update(genres=['Drama','Comedy'],imdbRating='7.2',runtime='170 min')
  r=self.source.preview('tt90000000')
  self.assertEqual('2008',r['releaseInfo']);self.assertEqual(['Comedy','Drama'],r['genres'])
  self.assertEqual(['Fixture Actor'],r['movieInfo']['cast']);self.assertEqual(['Fixture Director'],r['movieInfo']['director'])
  self.assertEqual(170,r['movieInfo']['runtimeMinutes']);self.assertEqual(7.2,r['movieInfo']['imdbRating'])
  self.assertEqual(self.transport.seed['description'],r['movieInfo']['summary'])
 def test_preview_rejects_wrong_identity_and_bounds_optional_fields(self):
  with self.assertRaises(ValueError):self.source.preview('../invalid')
  with self.assertRaises(DiscoveryUnavailable):self.source.preview('tt99999')
  self.transport.seed.update(cast=['A'*101,'Valid']*5,director=['D'*101],runtime=0,imdbRating='NaN',description='x'*3001)
  info=self.source.preview('tt90000000')['movieInfo'];self.assertEqual(['Valid'],info['cast']);self.assertEqual([],info['director'])
  self.assertFalse({'runtimeMinutes','imdbRating','summary'}&info.keys())
class SimilarWorkflowTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name);self.h.clock=int(time.time());self.h.payload['generatedEpoch']=self.h.clock
  self.c=self.h.controller;self.c.clock=time.time;self.transport=MetadataFixture();self.c.similar.source=CinemetaSimilar(CinemetaDiscovery(self.transport))
 def tearDown(self):self.h.close();self.tmp.cleanup()
 def act(self,action,**kw):return self.c.similar.action('fixture',dict(action=action,**kw))
 def wait(self,r):self.c.similar.jobs[r['jobId']]['future'].result(5);return self.act('similar-status',jobId=r['jobId'])
 def find(self):
  r=self.wait(self.act('search-titles',query='Original'));return self.wait(self.act('find-similar',jobId=r['jobId'],imdb='tt90000000'))
 def dump(self):
  with sqlite3.connect(self.h.db) as db:return '\n'.join(db.iterdump())
 def test_search_add_persistence_idempotency_no_download_or_choice_mutation(self):
  before=self.dump();r=self.find();self.assertEqual(before,self.dump());self.assertFalse(self.c.similar.store.path.exists())
  data=self.act('add-similar',jobId=r['jobId'],imdb='tt90000001',movie=movie(9))
  self.assertEqual('tt90000001',data['movies'][0]['id']);self.assertEqual(before,self.dump())
  self.assertEqual(0,self.h.provider.resolves);self.assertEqual(0,self.h.provider.verifies);self.assertFalse(list(self.h.media.rglob('*.mkv')))
  self.assertEqual(['tt90000001'],[x['id'] for x in SuggestionStore(self.tmp.name).read()]);self.assertEqual(0o600,self.c.similar.store.path.stat().st_mode&0o777)
  self.act('add-similar',jobId=r['jobId'],imdb='tt90000001');self.assertEqual(1,len(self.c.similar.store.read()))
 def test_title_preview_has_no_choice_or_media_side_effects(self):
  before=self.dump();r=self.wait(self.act('search-titles',query='Original'));self.assertTrue(r['previewsEnabled'])
  details=self.wait(self.act('title-preview',jobId=r['jobId'],imdb='tt90000000'))
  self.assertEqual('tt90000000',details['title']['id']);self.assertEqual(['Fixture Actor'],details['title']['movieInfo']['cast'])
  self.assertEqual(before,self.dump());self.assertFalse(self.c.similar.store.path.exists());self.assertEqual(0,self.h.provider.resolves)
 def test_preview_parent_identity_principal_expiry_and_csrf(self):
  r=self.wait(self.act('search-titles',query='Original'));b=dict(action='title-preview',jobId=r['jobId'],imdb='tt90000000')
  with self.assertRaisesRegex(ValueError,'expired'):self.c.similar.action('another',b)
  with self.assertRaisesRegex(ValueError,'Choose a movie'):self.act('title-preview',jobId=r['jobId'],imdb='tt99999')
  self.assertEqual(403,self.h.client.post('/movie-night/api/feedback',json=b).status_code)
  self.assertEqual(403,self.h.client.post('/movie-night/api/feedback',json=b,headers=dict(self.h.headers,origin='https://evil.test')).status_code)
  self.assertEqual(200,self.h.post('feedback',b).status_code)
  self.c.similar.jobs[r['jobId']]['created']-=901
  with self.assertRaisesRegex(ValueError,'expired'):self.c.similar.action('fixture',b)
 def test_scroll_many_previews_retains_parent_title_job(self):
  rows=[movie(i) for i in range(40)]
  def provider(path):
   if '/search=' in path:return {'metas':rows}
   return {'meta':next((r for r in rows if path=='/meta/movie/'+r['id']+'.json'),None)}
  self.c.similar.source=CinemetaSimilar(CinemetaDiscovery(provider))
  titles=self.wait(self.act('search-titles',query='Dream'))
  for row in titles['titles']:
   r=self.wait(self.act('title-preview',jobId=titles['jobId'],imdb=row['id']));self.assertEqual(row['id'],r['title']['id'])
   self.assertIn(titles['jobId'],self.c.similar.jobs);self.assertLessEqual(len(self.c.similar.jobs),24)
 def test_one_preview_leaves_capacity_for_title_typing(self):
  event=threading.Event()
  try:
   self.c.similar.start('fixture','preview','one',lambda:event.wait(5))
   with self.assertRaisesRegex(ValueError,'details are loading'):self.c.similar.start('fixture','preview','two',lambda:None)
   self.wait(self.act('search-titles',query='Original'))
  finally:event.set()
 def test_preview_failure_can_retry_and_cannot_be_used_for_admission(self):
  r=self.wait(self.act('search-titles',query='Original'));self.transport.fail=True
  a=self.act('title-preview',jobId=r['jobId'],imdb='tt90000000')
  with self.assertRaises(DiscoveryUnavailable):self.c.similar.jobs[a['jobId']]['future'].result(5)
  with self.assertRaisesRegex(ValueError,'temporarily unavailable'):self.act('similar-status',jobId=a['jobId'])
  self.transport.fail=False;b=self.wait(self.act('title-preview',jobId=r['jobId'],imdb='tt90000000'))
  with self.assertRaisesRegex(ValueError,'no longer eligible'):self.act('add-similar',jobId=b['jobId'],imdb='tt90000000')
  self.assertNotEqual(a['jobId'],b['jobId'])
 def test_add_then_existing_finalize(self):
  r=self.find();self.act('add-similar',jobId=r['jobId'],imdb='tt90000001')
  self.assertTrue(self.c.finalize('fixture',['tt12345','tt12346','tt90000001'])['finalized']['valid']);self.assertEqual(0,self.h.provider.resolves)
 def test_seen_and_payload_exclusions_rechecked(self):
  r=self.find();self.c.feedback.rate('fixture',r['movies'][0],'seen')
  with self.assertRaisesRegex(ValueError,'no longer eligible'):self.act('add-similar',jobId=r['jobId'],imdb=r['movies'][0]['id'])
  self.h.payload['knownSeenIds']=['tt90000002'];self.assertEqual([],self.act('similar-status',jobId=r['jobId'])['movies'])
 def test_changed_settings_invalidate_cached_results(self):
  r=self.find();s=defaults();s['included']=['Thriller'];s['excluded']=['Sci-Fi'];self.c.genre_settings.save(s)
  with self.assertRaisesRegex(ValueError,'genres changed'):self.act('add-similar',jobId=r['jobId'],imdb='tt90000001')
  self.assertFalse(self.c.similar.store.path.exists())
 def test_foreign_job_and_unoffered_ids(self):
  r=self.wait(self.act('search-titles',query='Original'))
  with self.assertRaisesRegex(ValueError,'expired'):self.c.similar.action('another',dict(action='similar-status',jobId=r['jobId']))
  with self.assertRaisesRegex(ValueError,'Choose a movie'):self.act('find-similar',jobId=r['jobId'],imdb='tt99999')
  with self.assertRaises(ValueError):self.act('add-similar',jobId=r['jobId'],imdb='tt90000000')
 def test_http_csrf_origin_and_validation(self):
  p='/movie-night/api/feedback';b={'action':'search-titles','query':'Original'}
  self.assertEqual(403,self.h.client.post(p,json=b).status_code)
  self.assertEqual(403,self.h.client.post(p,json=b,headers=dict(self.h.headers,origin='https://evil.test')).status_code)
  self.assertEqual(200,self.h.post('feedback',b).status_code);self.assertEqual(400,self.h.post('feedback',dict(b,query='x')).status_code)
 def test_duplicate_search_and_failure_retry(self):
  a=self.act('search-titles',query='Original');b=self.act('search-titles',query='ORIGINAL');self.assertEqual(a['jobId'],b['jobId']);self.wait(a)
  self.transport.fail=True;r=self.act('search-titles',query='broken')
  with self.assertRaises(DiscoveryUnavailable):self.c.similar.jobs[r['jobId']]['future'].result(5)
  with self.assertRaisesRegex(ValueError,'temporarily unavailable'):self.act('similar-status',jobId=r['jobId'])
  self.transport.fail=False;self.assertNotEqual(r['jobId'],self.act('search-titles',query='broken')['jobId'])
 def test_bounded_concurrency(self):
  event=threading.Event()
  try:
   for k in ['one','two']:self.c.similar.start('fixture','titles',k,lambda:event.wait(5))
   with self.assertRaisesRegex(ValueError,'already running'):self.act('search-titles',query='another')
  finally:event.set()
 def test_expiry_prevents_admission(self):
  r=self.find();self.c.similar.jobs[r['jobId']]['created']-=901
  with self.assertRaisesRegex(ValueError,'expired'):self.act('add-similar',jobId=r['jobId'],imdb='tt90000001')
 def test_fresh_added_title_does_not_revive_stale_weekly_rows(self):
  r=self.find();self.act('add-similar',jobId=r['jobId'],imdb='tt90000001');self.h.payload['generatedEpoch']-=31*86400
  self.assertEqual(['tt90000001'],[x['id'] for x in self.c.review_pool()])
 def test_expired_saved_metadata_can_be_refreshed(self):
  stale=normalize(movie(),int(time.time())-31*86400);self.c.similar.store.add(stale)
  fresh=normalize(movie());self.c.similar.store.add(fresh)
  self.assertEqual([fresh],self.c.similar.store.read())
 def test_concurrent_store_writers(self):
  with ThreadPoolExecutor(2) as pool:list(pool.map(self.c.similar.store.add,[normalize(movie(i)) for i in (1,2)]))
  self.assertEqual({'tt90000001','tt90000002'},{x['id'] for x in self.c.similar.store.read()})
 def test_corrupt_or_symlink_store_fails_closed(self):
  s=self.c.similar.store;s.path.write_text('{}')
  with self.assertRaises(ValueError):s.read()
  s.path.unlink();t=Path(self.tmp.name)/'target';t.write_text('{"movies":[]}');s.path.symlink_to(t)
  with self.assertRaises(ValueError):s.add(normalize(movie()))
  self.assertEqual('{"movies":[]}',t.read_text())
 def test_exact_source_provider_reads_added_metadata(self):
  from review_service import build_app
  root=Path(self.tmp.name)/'separate';root.mkdir();(root/'reviewed-shortlist.json').write_text(json.dumps(self.h.payload))
  _,c=build_app(root,'http://testserver',downloads=True,provider=self.h.provider,media_root=root/'media')
  try:
   c.similar.store.add(normalize(movie()));self.assertIn('tt90000001',[r['id'] for r in c.choices.payload()['movies']])
  finally:c.close()
if __name__=='__main__':unittest.main()
