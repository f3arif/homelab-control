"""Boundary tests of candidate AST functions. No application startup or network."""
import argparse
import ast
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import unittest
from fastapi import HTTPException

NS=None
class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.n=dict(NS)
        self.n.update({'AUTO_MEDIA_DOWNLOAD_POLICY_FILE':Path(self.tmp.name)/'policy.json',
            'auto_media_policy_lock':threading.Lock(),'watched_download_wake':threading.Event(),
            'personalized_movie_lock':threading.Lock(),'personalized_movie_cache':{},
            'NUVIO_PERSONALIZATION_PROFILE_ID':1,'watchlist_lock':threading.Lock(),
            'watched_download_status':{},'jellyfin_headers':lambda:{'Authorization':'private-test'},
            'JELLYFIN_URL':'http://test.invalid',
            '_nuvio_watch_state_map':lambda:{},'_stremio_watch_state_map':lambda:{},
            'rget':lambda path:[], 'watched_download_jellyfin':lambda:{}})
        exec(CODE,self.n)
        self.n['watched_download_jellyfin']=lambda:{}
        self.path=self.n['AUTO_MEDIA_DOWNLOAD_POLICY_FILE']
        self.path.write_text(json.dumps({'movies':{'tt27548557':False},'series':{}}))
    def tearDown(self): self.tmp.cleanup()
    def record(self,imdb='tt27165187',source='user-reported'):
        return self.n['watched_download_record'](imdb,'Test title',source)
    def test_completion_exclusion_survives_empty_history_and_existing_policy(self):
        self.record()
        self.n['watched_download_reconcile']()
        fresh=json.loads(self.path.read_text())
        self.assertFalse(self.n['auto_media_download_enabled']('movie','tt27165187',fresh))
        self.assertFalse(fresh['movies']['tt27548557'])
        self.assertTrue(self.n['auto_media_download_enabled']('movie','tt9999999'))
        self.assertTrue(self.n['auto_media_download_enabled']('series','tt27165187'))
        self.assertFalse(self.record())
    def test_completed_only_not_partial(self):
        self.n['_nuvio_watch_state_map']=lambda:{'tt1111111':{'finished':True},'tt2222222':{'finished':False,'started':True}}
        self.n['watched_download_reconcile']()
        self.assertFalse(self.n['auto_media_download_enabled']('movie','tt1111111'))
        self.assertTrue(self.n['auto_media_download_enabled']('movie','tt2222222'))
    def test_allow_cannot_clear_watched_or_mutate_policy(self):
        self.record()
        before=self.path.read_bytes()
        with self.assertRaises(HTTPException) as cm:
            self.n['auto_media_download_policy_set']('movie','tt27165187',True)
        self.assertEqual(cm.exception.status_code,409)
        self.assertEqual(before,self.path.read_bytes())
    def test_corrupt_policy_fails_closed_without_overwrite(self):
        self.path.write_text('{broken')
        with self.assertRaises(HTTPException): self.record()
        with self.assertRaises(HTTPException): self.n['auto_media_download_enabled']('movie','tt27165187')
        self.assertEqual(self.path.read_text(),'{broken')
    def test_unmonitor_does_not_delete_missing_or_existing_files(self):
        movies=[{'imdbId':'tt1111111','monitored':True,'hasFile':False},
                {'imdbId':'tt2222222','monitored':True,'hasFile':True,'movieFileId':123},
                {'imdbId':'tt3333333','monitored':True,'hasFile':False}]
        before=copy.deepcopy(movies)
        self.record('tt1111111');self.record('tt2222222')
        calls=[]
        def update(movie,value):
            calls.append((movie['imdbId'],value));return dict(movie,monitored=value)
        self.n['rget']=lambda path:movies
        self.n['set_radarr_movie_monitored']=update
        result=self.n['watched_download_reconcile']()
        self.assertEqual(calls,[('tt1111111',False),('tt2222222',False)])
        self.assertEqual(movies,before)
        self.assertTrue(result['radarrChecked'])
    def test_watched_auto_request_never_reaches_request_api(self):
        self.record()
        self.n['_watchlist_read']=lambda:{'items':{'tt27165187':{'imdbId':'tt27165187','autoRequest':True}}}
        changes=[]
        self.n['watchlist_set_auto']=lambda imdb,value:changes.append((imdb,value))
        self.n['spost']=lambda *a: self.fail('Watched title reached request API')
        self.assertTrue(self.n['_watchlist_auto_cycle']())
        self.assertEqual(changes,[('tt27165187',False)])
    def test_progress_profile_and_dryrun_and_older_completion(self):
        def invoke(profile,complete,dry=False):
            row={'profileId':profile,'imdbId':'tt4444444','positionMs':100000,'lastUpdatedEpochMs':50,'isCompleted':complete}
            self.n['_normalize_nuvio_progress']=lambda p:row
            self.n['_nuvio_progress_read']=lambda:{'1:tt4444444':{'lastUpdatedEpochMs':100}}
            self.n['_nuvio_progress_write']=lambda rows:True
            return self.n['nuvio_watch_progress']({'dryRun':dry})
        invoke(1,True,True)
        self.assertFalse(self.n['watched_download_blocked']('tt4444444'))
        invoke(2,True)
        self.assertFalse(self.n['watched_download_blocked']('tt4444444'))
        invoke(1,False)
        self.assertFalse(self.n['watched_download_blocked']('tt4444444'))
        result=invoke(1,True)
        self.assertEqual(result['reason'],'older-than-stored')
        self.assertTrue(self.n['watched_download_blocked']('tt4444444'))
    def test_unreachable_sources_keep_exclusion_and_reconcile(self):
        self.record()
        def fail(): raise TimeoutError('private upstream detail')
        self.n['_stremio_watch_state_map']=fail
        result=self.n['watched_download_reconcile']()
        self.assertEqual(result['sources']['stremio'],{'errorType':'TimeoutError'})
        self.assertEqual(result['excludedCount'],1)
        self.assertTrue(result['radarrChecked'])

def main():
    global NS,CODE
    ap=argparse.ArgumentParser();ap.add_argument('--candidate',type=Path,required=True);ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args()
    tree=ast.parse(args.candidate.read_text(encoding='utf-8-sig'))
    names={'watched_download_blocked','watched_download_record','watched_download_reconcile',
           'auto_media_download_policy_read','auto_media_download_enabled','auto_media_download_policy_set',
           '_watchlist_auto_cycle','nuvio_watch_progress'}
    selected=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names]
    if {n.name for n in selected}!=names: raise RuntimeError('Missing candidate functions')
    for n in selected:
        n.decorator_list=[]
        n.args.defaults=[]
        if n.name=='auto_media_download_enabled': n.args.defaults=[ast.Constant(None)]
        if n.name=='auto_media_download_policy_set': n.args.defaults=[ast.Constant('')]
        if n.name=='watched_download_blocked': n.args.defaults=[ast.Constant(None)]
    CODE=compile(ast.fix_missing_locations(ast.Module(body=selected,type_ignores=[])),str(args.candidate),'exec')
    NS={'json':json,'os':os,'re':re,'datetime':datetime,'timezone':timezone,'HTTPException':HTTPException}
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(GuardTests))
    receipt={'passed':result.wasSuccessful(),'tests':result.testsRun,'coreNotImported':True,'liveStateUnchanged':True}
    args.output.write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    if not result.wasSuccessful(): raise SystemExit(1)

if __name__=='__main__': main()
