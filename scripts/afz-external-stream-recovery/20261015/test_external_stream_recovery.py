import ast
import concurrent.futures
import json
import re
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import quote,parse_qs,urlsplit
from external_stream_recovery import SourceHistory,same_file

HERE=Path(__file__).resolve().parent
VID='tt0098904:3:11'
OLD='a'*28
NEW='b'*28
BASE={'token':OLD,'provider':'TorBox','source':'Comet','resolution':1080,
      'size':123456789,'sizeExact':True,'filename':'Example S03E11.mkv',
      'resolverVideoId':VID}
FRESH=dict(BASE,token=NEW)
class HttpError(Exception):
    def __init__(self,status,detail):
        self.status_code,self.detail=status,detail
        super().__init__(detail)

def resolver_namespace(history,rows,bridge):
    tree=ast.parse((HERE/'stremio_catalog.candidate.py').read_text(encoding='utf-8'))
    fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='_external_resolved_url')
    ns={'re':re,'time':time,'HTTPException':HttpError,
        'requests':SimpleNamespace(utils=SimpleNamespace(quote=quote)),
        '_external_history':history,'_same_external_file':same_file,
        'parse_series_video_id':lambda v:':' in v,
        'series_external_source_rows':rows,'external_source_rows':rows,
        'h3_order_call':bridge,'FAILOVER_MODE':True,
        'resolved_stream_lock':threading.Lock(),'external_resolved_cache':{},
        'RESOLVED_STREAM_TTL':120}
    exec(compile(ast.Module(body=[fn],type_ignores=[]),'candidate-resolver','exec'),ns)
    return ns

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.path=Path(self.tmp.name)/'history.json'
        self.history=SourceHistory(self.path)
        self.history.remember(VID,[BASE])
        self.calls=[]
        self.refreshes=[]
    def tearDown(self):
        self.tmp.cleanup()
    def rows(self,v,force=False):
        self.refreshes.append((v,force))
        return [FRESH] if force else [BASE]
    def bridge(self,m,path,timeout):
        self.calls.append(path)
        token=parse_qs(urlsplit(path).query)['token'][0]
        return {'ok':True,'url':'https://media.invalid/file','statusCode':200} if token==NEW else {'ok':False,'statusCode':404}
    def ns(self,rows=None,bridge=None):
        return resolver_namespace(self.history,rows or self.rows,bridge or self.bridge)
    def test_expired_token_recovers_exact_file(self):
        ns=self.ns()
        self.assertEqual(ns['_external_resolved_url'](VID,OLD),'https://media.invalid/file')
        self.assertEqual(len(self.calls),2)
        self.assertEqual(sum(force for _,force in self.refreshes),1)
    def test_recovery_shared_across_player_engines(self):
        fn=self.ns()['_external_resolved_url']
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            got=list(pool.map(lambda _:fn(VID,OLD),range(8)))
        self.assertEqual(got,['https://media.invalid/file']*8)
        self.assertEqual(len(self.calls),2)
    def test_history_survives_catalog_replacement_and_restart(self):
        self.history.remember(VID,[FRESH])
        self.history=SourceHistory(self.path)
        fn=self.ns(rows=lambda *a,**k:[FRESH])['_external_resolved_url']
        self.assertEqual(fn(VID,OLD),'https://media.invalid/file')
    def test_different_episode_rejected(self):
        row=dict(FRESH,filename='Example S03E12.mkv')
        fn=self.ns(rows=lambda *a,**k:[row])['_external_resolved_url']
        with self.assertRaises(HttpError) as e:fn(VID,OLD)
        self.assertEqual(e.exception.status_code,404)
        self.assertEqual(len(self.calls),0)
    def test_unknown_token_does_not_refresh_or_resolve(self):
        fn=self.ns()['_external_resolved_url']
        with self.assertRaises(HttpError):fn(VID,'c'*28)
        self.assertFalse(self.calls)
        self.assertFalse(any(force for _,force in self.refreshes))
    def test_unavailable_bridge_is_503_and_not_expiry(self):
        fn=self.ns(bridge=lambda *a:{'ok':False,'statusCode':503})['_external_resolved_url']
        with self.assertRaises(HttpError) as e:fn(VID,OLD)
        self.assertEqual(e.exception.status_code,503)
        self.assertFalse(any(force for _,force in self.refreshes))
    def test_remapped_resolver_id_preserved(self):
        vid='tt0115200:1:38'
        old=dict(BASE,resolverVideoId='tt0115200:1:20')
        fresh=dict(old,token=NEW)
        self.history.remember(vid,[old])
        def rows(*a,**k):return [fresh] if k.get('force') else [old]
        fn=self.ns(rows=rows)['_external_resolved_url']
        fn(vid,OLD)
        self.assertTrue(all(parse_qs(urlsplit(x).query)['imdb']==['tt0115200:1:20'] for x in self.calls))
    def test_new_valid_token_does_not_refresh(self):
        fn=self.ns(rows=lambda *a,**k:[FRESH])['_external_resolved_url']
        self.assertEqual(fn(VID,NEW),'https://media.invalid/file')
        self.assertEqual(len(self.calls),1)
    def test_history_never_persists_urls_or_auth(self):
        self.history.remember(VID,[dict(BASE,url='https://private.invalid/secret',authKey='secret')])
        saved=self.path.read_text(encoding='utf-8')
        self.assertNotIn('secret',saved)
        self.assertNotIn('url',saved)
    def test_history_expiration_and_bound(self):
        clock=[100.]
        h=SourceHistory(self.path.with_name('bounded.json'),ttl=10,limit=2,clock=lambda:clock[0])
        for x in 'abc':
            h.remember(VID,[dict(BASE,token=x*28)])
            clock[0]+=1
        self.assertEqual(len(h.rows),2)
        clock[0]=200
        self.assertIsNone(h.get(VID,'c'*28))
    def test_metadata_is_scoped_to_episode(self):
        self.assertIsNone(self.history.get('tt0098904:3:12',OLD))
    def test_missing_filename_refuses_recovery(self):
        self.assertIsNone(same_file(dict(BASE,filename=''),[FRESH]))
    def test_different_provider_refuses_recovery(self):
        self.assertIsNone(same_file(BASE,[dict(FRESH,provider='RealDebrid')]))
    def test_different_source_refuses_recovery(self):
        self.assertIsNone(same_file(BASE,[dict(FRESH,source='Debridio')]))
    def test_different_resolution_refuses_recovery(self):
        self.assertIsNone(same_file(BASE,[dict(FRESH,resolution=2160)]))
    def test_different_exact_size_refuses_recovery(self):
        self.assertIsNone(same_file(BASE,[dict(FRESH,size=123)]))
    def test_ambiguous_releases_refuse_recovery(self):
        self.assertIsNone(same_file(BASE,[FRESH,dict(FRESH,token='d'*28)]))
    def test_different_resolver_episode_refuses_recovery(self):
        self.assertIsNone(same_file(BASE,[dict(FRESH,resolverVideoId='tt0098904:3:12')]))
    def test_invalid_token_rejected_before_discovery(self):
        fn=self.ns()['_external_resolved_url']
        with self.assertRaises(HttpError):fn(VID,'invalid')
        self.assertFalse(self.refreshes)
    def test_movie_recovery(self):
        vid='tt1234567'
        old={k:v for k,v in BASE.items() if k!='resolverVideoId'}
        fresh=dict(old,token=NEW)
        self.history.remember(vid,[old])
        fn=self.ns(rows=lambda *a,**k:[fresh] if k.get('force') else [old])['_external_resolved_url']
        self.assertEqual(fn(vid,OLD),'https://media.invalid/file')

if __name__=='__main__':
    unittest.main(verbosity=2)
