from contextlib import contextmanager,closing
from dataclasses import replace
import io,json,re,tempfile,threading,time,unittest
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
from movie_night import Choice,ROOT,ApprovalStore,RESERVE
from adapters import MediaIndex,WorkerAdapter
from webapp import Controller,create_app
from download_provider import InventoryChoices

def probe(path):
    return {'format':{'duration':'7200'},'streams':[{'codec_type':'video','codec_name':'h264','width':1920,'height':1080}]}

class Provider:
    def __init__(self):self.changed=False;self.resolves=0;self.verifies=0;self.present=True
    def verify(self,c):
        self.verifies+=1
        if not self.present:raise ValueError('provider file is not completed and present')
        return replace(c,size=c.size+1) if self.changed else c
    def resolve(self,row):self.resolves+=1;return 'https://fixture.invalid/media'

class Harness:
    def __init__(self,tmp,body=None):
        self.root=Path(tmp);self.media=self.root/'media';self.media.mkdir()
        self.state=self.root/'transfers';self.state.mkdir();self.body=body or b'fixture bytes'*8
        self.choice=Choice('tt12345','Fixture One',2024,'Theatrical','torbox',12,3,'Fixture.One.2024.1080p.x264.mkv','1080p','AVC',len(self.body),ROOT+'/tt12345.2024.mkv')
        self.provider=Provider();self.db=self.root/'preferences.sqlite3';self.index=MediaIndex(self.root/'index.sqlite3',self.media)
        self.block=threading.Event();self.entered=threading.Event();self.slow=False;self.truncated=False
        self.clock=1000
        self.payload={'generatedEpoch':1000,'movies':[{'id':imdb,'name':name,'year':2024,'genres':['Action'],'scareLevel':'low','intensityReviewed':True,'intenseSupernatural':False,'fitTags':['twists']} for imdb,name in [('tt12345','Fixture One'),('tt12346','Fixture Two'),('tt12347','Fixture Three')]]}
        self.worker=WorkerAdapter(self.db,self.media,self.state,self.provider,self.index,enabled=True,open_media=self.open_media,free=lambda _:200_000_000_000,probe=probe)
        self.controller=Controller(self.db,lambda imdb:[self.choice] if imdb==self.choice.imdb else [],self.provider,self.worker,self.index,lambda:200_000_000_000,enabled=True,review_enabled=True,shortlist_payload=lambda:self.payload,clock=lambda:self.clock)
        self.app=create_app(self.controller,lambda r:'fixture' if r.headers.get('x-fixture')=='yes' else None,allowed_origin='http://testserver')
        self.client=TestClient(self.app);self.client.headers['x-fixture']='yes'
        self.worker.verify_route=lambda imdb,size:self.client.head('/movie-night/media/'+imdb).status_code==200
        html=self.client.get('/movie-night').text
        self.headers={'origin':'http://testserver','x-movie-night-csrf':re.search('name="mn-csrf" content="([^"]+)"',html)[1]}
        self.controller.finalize('fixture',['tt12345','tt12346','tt12347'])
    @contextmanager
    def open_media(self,*args,**kw):
        self.entered.set()
        if self.slow:self.block.wait(5)
        r=io.BytesIO(self.body[:-1] if self.truncated else self.body);r.headers={'Content-Length':str(len(self.body))}
        try:yield r
        finally:r.close()
    def post(self,path,data):return self.client.post('/movie-night/api/'+path,json=data,headers=self.headers)
    def plan(self):
        lookup=self.post('propose',{'imdb':'tt12345'}).json()
        if 'lookupId' not in lookup:raise AssertionError(lookup)
        self.controller.lookups[lookup['lookupId']][3].result(5)
        r=self.client.get('/movie-night/api/lookup/'+lookup['lookupId']);assert r.status_code==200,r.text
        return r.json()
    def approve(self,p,reply='yes'):
        return self.post('approve',{'confirmationId':p['confirmationId'],'binding':p['binding'],'reply':reply})
    def wait(self,p):return self.controller.futures[p['confirmationId']].result(5)
    def close(self):self.block.set();self.controller.close();self.client.close()

class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.h=Harness(self.tmp.name)
        self.net=patch('socket.create_connection',side_effect=AssertionError('real network forbidden'));self.net.start()
    def tearDown(self):self.h.close();self.net.stop();self.tmp.cleanup()
    def test_source_check_never_resolves_media(self):
        self.h.plan();self.assertEqual(0,self.h.provider.resolves);self.assertFalse(list(self.h.media.rglob('*.mkv')))
    def test_success_verified_file_index_and_durable_list(self):
        p=self.h.plan();self.assertEqual(200,self.h.approve(p).status_code)
        s=self.h.wait(p);self.assertTrue(s['downloaded']);self.assertTrue(s['indexed']);self.assertFalse(s['playbackTested'])
        self.assertEqual(self.h.body,self.h.client.get('/movie-night/media/tt12345').content)
        self.assertEqual(self.h.body[2:9],self.h.client.get('/movie-night/media/tt12345',headers={'Range':'bytes=2-8'}).content)
        self.assertEqual(p['confirmationId'],self.h.client.get('/movie-night/api/downloads').json()['jobs'][0]['id'])
        self.assertEqual('tt12345',self.h.client.get('/movie-night/catalog/movie/downloaded.json').json()['metas'][0]['id'])
    def test_requires_exact_yes(self):
        p=self.h.plan();self.assertEqual(409,self.h.approve(p,'next').status_code);self.assertEqual(0,self.h.provider.resolves)
    def test_duplicate_confirmation_dispatches_once(self):
        p=self.h.plan();self.h.approve(p);self.h.wait(p);self.assertFalse(self.h.approve(p).json()['newJob']);self.assertEqual(1,self.h.provider.resolves)
    def test_source_changed(self):
        p=self.h.plan();self.h.provider.changed=True;self.assertEqual(409,self.h.approve(p).status_code);self.assertEqual(0,self.h.provider.resolves)
    def test_source_no_longer_completed(self):
        p=self.h.plan();self.h.provider.present=False;self.assertEqual(409,self.h.approve(p).status_code)
    def test_expired_confirmation(self):
        p=self.h.plan();self.h.clock+=901;self.assertEqual(409,self.h.approve(p).status_code)
    def test_low_space(self):
        p=self.h.plan();self.h.controller.free=lambda:RESERVE;self.assertEqual(409,self.h.approve(p).status_code);self.assertEqual(0,self.h.provider.resolves)
    def test_disabled_before_provider(self):
        self.h.controller.enabled=False;self.assertEqual(409,self.h.post('propose',{'imdb':'tt12345'}).status_code);self.assertEqual(0,self.h.provider.verifies)
    def test_requires_finalized_and_seen_excluded(self):
        self.h.controller.rate('fixture','tt12345','seen');self.assertEqual(409,self.h.post('propose',{'imdb':'tt12345'}).status_code)
    def test_auth_csrf_and_origin(self):
        self.assertEqual(403,self.h.client.post('/movie-night/api/propose',json={'imdb':'tt12345'}).status_code)
        bad=dict(self.h.headers,origin='https://bad.invalid')
        self.assertEqual(403,self.h.client.post('/movie-night/api/propose',json={'imdb':'tt12345'},headers=bad).status_code)
        self.h.client.headers.clear();self.assertEqual(403,self.h.client.get('/movie-night/api/downloads').status_code)
    def test_owner_bound_lookup_status(self):
        p=self.h.plan()
        with self.assertRaises(PermissionError):self.h.controller.status(p['confirmationId'],'other')
        pid=self.h.controller.prepare('tt12345','fixture')['lookupId']
        with self.assertRaises(PermissionError):self.h.controller.lookup(pid,'other')
        self.assertEqual([],self.h.controller.downloads('other')['jobs'])
    def test_cancel_preserves_partial(self):
        self.h.slow=True;p=self.h.plan();self.h.approve(p);self.assertTrue(self.h.entered.wait(2))
        self.assertEqual(200,self.h.post('cancel',{'confirmationId':p['confirmationId']}).status_code)
        self.h.block.set();s=self.h.wait(p);self.assertEqual('cancelled',s['state']);self.assertTrue(list(self.h.media.rglob('*.part')));self.assertFalse(self.h.index.metas())
    def test_truncation_preserves_partial_and_no_index(self):
        self.h.truncated=True;p=self.h.plan();self.h.approve(p);s=self.h.wait(p);self.assertEqual('failed',s['state']);self.assertTrue(list(self.h.media.rglob('*.part')));self.assertFalse(self.h.index.metas())
    def test_completed_file_never_overwritten(self):
        p=self.h.plan();self.h.approve(p);self.h.wait(p)
        self.assertEqual(409,self.h.post('cancel',{'confirmationId':p['confirmationId']}).status_code)
        with self.assertRaises(ValueError):self.h.controller.propose('tt12345','fixture')
        self.assertEqual(self.h.body,self.h.index.resolve('tt12345').read_bytes())
    def test_index_failure_reports_downloaded_only(self):
        self.h.worker.verify_route=lambda *_:False;p=self.h.plan();self.h.approve(p);s=self.h.wait(p)
        self.assertTrue(s['downloaded']);self.assertFalse(s['indexed']);self.assertEqual([],self.h.index.metas())

class InventoryTests(unittest.TestCase):
    def rows(self,name='Fixture.One.2024.1080p.x264.mkv',**kw):
        f={'id':3,'name':name,'size':4_000_000_000,'infected':False,'zipped':False};f.update(kw)
        return [{'id':12,'download_finished':True,'download_present':True,'name':name,'files':[f]}]
    def parse(self,rows):
        class P:
            def _api(self,*a,**kw):return rows
        return InventoryChoices(P(),lambda:{'movies':[{'id':'tt12345','name':'Fixture One','year':2024}]} )('tt12345')
    def test_exact_feature(self):self.assertEqual(1,len(self.parse(self.rows())))
    def test_wrong_year(self):self.assertEqual([],self.parse(self.rows(name='Fixture.One.2023.1080p.x264.mkv')))
    def test_different_title(self):self.assertEqual([],self.parse(self.rows(name='Fixture.One.More.2024.1080p.x264.mkv')))
    def test_unknown_safety(self):self.assertEqual([],self.parse(self.rows(infected=None)))
    def test_incomplete(self):
        rows=self.rows();rows[0]['download_finished']=False;self.assertEqual([],self.parse(rows))
    def test_unknown_codec(self):self.assertEqual([],self.parse(self.rows(name='Fixture.One.2024.1080p.mkv')))
    def test_large_or_720p(self):
        self.assertEqual([],self.parse(self.rows(size=9_000_000_001)))
        self.assertEqual([],self.parse(self.rows(name='Fixture.One.2024.720p.x264.mkv')))

if __name__=='__main__':unittest.main()
