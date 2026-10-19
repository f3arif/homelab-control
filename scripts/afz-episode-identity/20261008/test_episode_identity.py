"""Exercise exact backend functions without importing runtime services."""
import ast
import copy
import json
from pathlib import Path
import re
import sys
import threading
import time
import types
import unittest
from urllib.parse import quote

ROOT=Path(__file__).parent
NAMES={'parse_series_video_id','_episode_title_matches_release','_series_release_identity',
       '_series_release_matches','_filter_series_release_rows','series_external_source_rows',
       '_series_quality_label','_series_mobile_rank','series_external_choice_streams','_external_resolved_url'}
class HttpError(Exception):
    def __init__(self,status_code,detail):self.status_code=status_code;self.detail=detail

def load(path):
    tree=ast.parse(Path(path).read_text(encoding='utf-8'))
    nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in NAMES]
    for n in nodes:n.decorator_list=[]
    ns={'re':re,'time':time,'threading':threading,'requests':types.SimpleNamespace(utils=types.SimpleNamespace(quote=quote)),
        'HTTPException':HttpError,'FAILOVER_MODE':True,'EXTERNAL_SOURCE_TTL':300,'EXTERNAL_SOURCE_EMPTY_TTL':30,
        'RESOLVED_STREAM_TTL':300,'external_source_lock':threading.RLock(),'resolved_stream_lock':threading.RLock(),
        '_failover_series_meta_lock':threading.RLock(),'_failover_series_meta_cache':{},
        'external_source_cache':{'ts':{},'rows':{}},'external_resolved_cache':{},
        '_persist_external_source_cache':lambda:None,'_external_source_is_nonfeature':lambda x:False,
        '_external_source_is_prerelease':lambda x:False,'_series_episode_title':lambda *args:'The Little Red Riding Girl',
        '_failover_series_meta':lambda imdb:{'name':'Hey Arnold!' if imdb=='tt0115200' else 'Friends','releaseInfo':'1996' if imdb=='tt0115200' else '1994'},
        'human_size':lambda size:f'{size/1024**3:.1f} GB'}
    exec(compile(ast.Module(body=nodes,type_ignores=[]),str(path),'exec'),ns)
    return ns

def row(name,token='a'*40,res=1080,size=1.7):
    return {'filename':name,'token':token,'resolution':res,'size':int(size*1024**3),'sizeExact':True,'cached':True,'provider':'TorBox','source':'Comet'}

GOOD=row('Friends S01E01 1080p AMZN WEB-DL DDP2.0 H.264-TURG.mkv')
BAD=row('Your.Friends.and.Neighbors.S01E01.2160p.DV.HDR.mkv','b'*40,2160,10.6)
VID='tt0108778:1:1'

class IdentityTests(unittest.TestCase):
    def setUp(self):self.n=load(ROOT/'stremio_catalog.py')
    def cache(self,rows,age=0,vid=VID):
        self.n['external_source_cache']={'ts':{vid:time.time()-age},'rows':{vid:copy.deepcopy(rows)}}
    def fresh(self,rows):self.n['h3_order_call']=lambda *args,**kwargs:{'ok':True,'streams':copy.deepcopy(rows)}
    def test_fresh_provider_rows_filtered_before_ranking(self):
        self.fresh([BAD,GOOD])
        self.assertEqual([r['token'] for r in self.n['series_external_source_rows'](VID,True)],[GOOD['token']])
    def test_existing_cache_filters_unrelated_files(self):
        self.cache([BAD,GOOD]);self.n['h3_order_call']=lambda *a: self.fail('Fresh cache must not call provider')
        self.assertEqual([r['token'] for r in self.n['series_external_source_rows'](VID)],[GOOD['token']])
    def test_busy_bridge_fallback_filters_cache(self):
        self.cache([BAD,GOOD],age=3600);self.n['h3_order_call']=lambda *a:{'ok':False,'statusCode':409}
        self.assertEqual([r['token'] for r in self.n['series_external_source_rows'](VID)],[GOOD['token']])
    def test_exception_fallback_filters_cache(self):
        self.cache([BAD,GOOD],age=3600)
        def fail(*a):raise RuntimeError('offline')
        self.n['h3_order_call']=fail
        self.assertEqual([r['token'] for r in self.n['series_external_source_rows'](VID)],[GOOD['token']])
    def test_auto_and_fixed_choices_use_only_matching_show(self):
        self.cache([BAD,GOOD])
        choices=self.n['series_external_choice_streams'](VID,'https://test.invalid')
        self.assertEqual([x['name'] for x in choices],['AFZ TV Mobile 1080p · Comet','AFZ TV Auto'])
        self.assertTrue(all(x['behaviorHints']['filename']==GOOD['filename'] for x in choices))
    def test_metadata_outage_uses_known_identity(self):
        self.n['_failover_series_meta']=lambda x:{}
        self.n['_failover_series_meta_cache']={'tt0108778':{'name':'Friends','releaseInfo':'1994','_ts':0}}
        self.assertEqual(self.n['_series_release_identity']('tt0108778'),('Friends','1994'))
    def test_unknown_identity_returns_no_provider_files(self):
        self.n['_failover_series_meta']=lambda x:{};self.cache([BAD,GOOD])
        self.assertEqual(self.n['series_external_source_rows'](VID),[])
    def test_old_bad_resolved_url_rejected_before_cache(self):
        self.cache([BAD,GOOD]);self.n['external_resolved_cache']={VID+'|'+BAD['token']:{'ts':time.time(),'url':'https://wrong.invalid/file'}}
        self.n['h3_order_call']=lambda *a:self.fail('Rejected token must not call resolver')
        with self.assertRaises(HttpError) as caught:self.n['_external_resolved_url'](VID,BAD['token'])
        self.assertEqual(caught.exception.status_code,404)
    def test_matching_resolved_url_cache_preserved(self):
        self.cache([BAD,GOOD]);self.n['external_resolved_cache']={VID+'|'+GOOD['token']:{'ts':time.time(),'url':'https://correct.invalid/file'}}
        self.assertEqual(self.n['_external_resolved_url'](VID,GOOD['token']),'https://correct.invalid/file')
    def test_movie_resolver_has_no_series_gate(self):
        self.n['series_external_source_rows']=lambda *a:self.fail('Movie must not enter series gate')
        self.n['h3_order_call']=lambda *a:{'ok':True,'url':'https://movie.invalid/file'}
        self.assertEqual(self.n['_external_resolved_url']('tt1234567','a'*40),'https://movie.invalid/file')
    def test_remapped_episode_listing_preserves_requested_identity(self):
        vid='tt0115200:1:38'
        valid=row('Hey.Arnold.S01E20.The.Little.Red.Riding.Girl.1080p.mkv')
        wrong=row('Hey.Arnold.S01E20.Other.Episode.1080p.mkv','b'*40)
        self.fresh([wrong,valid])
        sources=self.n['series_external_source_rows'](vid,True)
        self.assertEqual(len(sources),1);self.assertEqual(sources[0]['resolverVideoId'],'tt0115200:1:20')
        choices=self.n['series_external_choice_streams'](vid,'https://test.invalid')
        self.assertTrue(all('tt0115200%3A1%3A38' in x['url'] for x in choices))
    def test_remapped_episode_resolver_sends_provider_identity(self):
        vid='tt0115200:1:38';valid=row('Hey.Arnold.S01E20.The.Little.Red.Riding.Girl.1080p.mkv');valid['resolverVideoId']='tt0115200:1:20'
        self.cache([valid],vid=vid)
        def bridge(method,path,*args):
            self.assertIn('imdb=tt0115200%3A1%3A20',path)
            return {'ok':True,'url':'https://correct.invalid/remapped'}
        self.n['h3_order_call']=bridge
        self.assertEqual(self.n['_external_resolved_url'](vid,valid['token']),'https://correct.invalid/remapped')
    def test_baseline_comparison_reproduces_wrong_auto(self):
        baseline=load(ROOT/'baseline-stremio_catalog.py')
        baseline['external_source_cache']={'ts':{VID:time.time()},'rows':{VID:copy.deepcopy([BAD,GOOD])}}
        choices=baseline['series_external_choice_streams'](VID,'https://test.invalid')
        self.assertEqual(next(x for x in choices if x['name']=='AFZ TV Auto')['behaviorHints']['filename'],BAD['filename'])

CASES=[
    (True,'Friends','1994',1,1,'Friends.S01E01.1080p.mkv'),
    (True,'Friends','1994',1,1,'Friends 1994 S01E01 1080p.mkv'),
    (True,'Friends','1994',1,1,'[GROUP] Friends.S01E01.1080p.mkv'),
    (True,'Friends','1994',1,1,'Friends.1x01.Pilot.mkv'),
    (True,'Arthur','1996',1,2,"Arthur - S01E01-E02 - Arthur's Eyes + Francine's Bad Hair Day.mkv"),
    (True,'Hey Arnold!','1996',1,2,'Hey.Arnold.S01E01E02.1080p.mkv'),
    (True,'Show','2000',1,3,'Show.S01E01-E04.mkv'),
    (True,"Marvel's Daredevil",'2015',1,1,'Marvels.Daredevil.S01E01.1080p.mkv'),
    (True,'Élite','2018',1,1,'Elite.S01E01.mkv'),
    (True,'Arthur','1996',1,1,"Arthur - Season 1 - Episode 1 - Full Episode - Arthur's Eyes.mp4"),
    (True,'1923','2022',1,1,'1923.S01E01.1080p.mkv'),
    (True,'1983','2018',1,1,'1983.S01E01.1080p.mkv'),
    (False,'Friends','1994',1,1,'Conversations.With.Friends.S01E01.1080p.mkv'),
    (False,'Friends','1994',1,1,'Your.Friends.and.Neighbors.S01E01.2160p.mkv'),
    (False,'Friends','1994',1,1,'Song.of.the.Samurai.S01E01.Burning.with.Friends.mkv'),
    (False,'Friends','1994',1,1,'Hyakkano.S01E01.1080p.mkv'),
    (False,'Friends','1994',1,1,'Seinfeld.S01E01.1080p.mkv'),
    (False,'Friends','1994',1,1,'Friends.S01E02.1080p.mkv'),
    (False,'Friends','1994',1,1,'Friends.S02E01.1080p.mkv'),
    (False,'Friends','1994',1,1,'Friends 2025 S01E01.1080p.mkv'),
    (False,'Friends','1994',1,1,'Friends.S01.Complete.1080p.mkv'),
    (False,'Friends','1994',1,1,'S01E01.1080p.mkv'),
    (False,'Arthur','1996',1,1,'Arthur.S01E03-E04.mkv'),
    (False,'Show','2000',1,2,'Show.S01E01E03.mkv'),
]
for index,(expected,title,year,season,episode,filename) in enumerate(CASES):
    def case(self,expected=expected,title=title,year=year,season=season,episode=episode,filename=filename):
        self.assertEqual(self.n['_series_release_matches']((title,year),season,episode,row(filename)),expected)
    setattr(IdentityTests,f'test_release_identity_{index:02}',case)

if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(IdentityTests)
    result=unittest.TextTestRunner(verbosity=1).run(suite)
    report={'passed':result.wasSuccessful(),'testsRun':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'releaseIdentityCases':len(CASES)}
    (ROOT/'test-result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report));sys.exit(0 if result.wasSuccessful() else 1)
