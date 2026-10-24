from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch
import io,json,tempfile,unittest
from cached_sources import CachedSources,configured_comet
from worker_candidate import Provider

HASH='a'*40
NAME='Fixture.One.2024.1080p.x264.mkv'
MOVIE={'id':'tt12345','name':'Fixture One','year':2024}


class CacheProvider:
    def __init__(self):
        self.added=[];self.calls=[];self.ready=True;self.safe=True;self.changed=False
        self.cached={HASH:{'hash':HASH,'name':NAME,'files':[{'name':NAME,'size':4_000_000_000}]}}
    def add_cached(self,h):self.added.append(h);return 987
    def _api(self,endpoint,query,bearer):
        self.calls.append((endpoint,query,bearer))
        if endpoint=='checkcached':return self.cached
        if endpoint=='mylist':return {'id':987,'hash':HASH,'name':NAME,'download_finished':self.ready,'download_present':self.ready,'files':[{'id':32,'name':NAME,'size':4_000_000_001 if self.changed else 4_000_000_000,'infected':False if self.safe else None,'zipped':False}]}
        raise AssertionError('unexpected endpoint')


class CachedSourceTests(unittest.TestCase):
    def setUp(self):
        self.provider=CacheProvider();self.opened=[];self.guards=[]
        self.streams=[{'behaviorHints':{'bingeGroup':'comet|torbox|'+HASH},'url':'https://untrusted.invalid/play?secret=fixture'}]
        self.sources=CachedSources(self.provider,lambda:{'movies':[MOVIE]},endpoint=lambda:'https://comet.elfhosted.com/fixture',opener=self.open,sleep=lambda _:None)
        self.net=patch('socket.create_connection',side_effect=AssertionError('real network forbidden'));self.net.start()
    def tearDown(self):self.net.stop()
    @contextmanager
    def open(self,url):self.opened.append(url);yield io.BytesIO(json.dumps({'streams':self.streams}).encode())
    def guard(self,size):self.guards.append(size)
    def test_discovery_is_read_only_and_never_opens_stream_url(self):
        choices=self.sources.candidates('tt12345')
        self.assertEqual(1,len(choices));self.assertEqual([],self.provider.added)
        self.assertEqual(['https://comet.elfhosted.com/fixture/stream/movie/tt12345.json'],self.opened)
    def test_acquire_requires_fresh_real_ids_safety_and_size(self):
        result=self.sources.acquire('tt12345',self.guard)
        self.assertEqual((987,32,4_000_000_000),(result.torrent_id,result.file_id,result.size))
        self.assertEqual([HASH],self.provider.added);self.assertGreaterEqual(len(self.guards),2)
    def test_missing_cache_does_not_add(self):
        self.provider.cached={};self.assertIsNone(self.sources.acquire('tt12345',self.guard))
        self.assertEqual([],self.provider.added)
    def test_mismatched_title_year_quality_and_size_are_excluded(self):
        for name,size in [('Wrong.2024.1080p.x264.mkv',4_000_000_000),('Fixture.One.2023.1080p.x264.mkv',4_000_000_000),('Fixture.One.2024.2160p.x264.mkv',4_000_000_000),(NAME,9_000_000_001),(NAME,None)]:
            self.provider.cached[HASH]['files']=[{'name':name,'size':size}]
            self.assertIsNone(self.sources.acquire('tt12345',self.guard))
        self.assertEqual([],self.provider.added)
    def test_changed_metadata_and_unknown_safety_never_return_worker_choice(self):
        self.provider.changed=True
        with self.assertRaises(ValueError):self.sources.acquire('tt12345',self.guard)
        self.provider.changed=False;self.provider.safe=False
        with self.assertRaises(ValueError):self.sources.acquire('tt12345',self.guard)
    def test_guard_stops_before_add_and_again_before_media(self):
        def cancelled(_):raise ValueError('cancelled')
        with self.assertRaises(ValueError):self.sources.acquire('tt12345',cancelled)
        self.assertEqual([],self.provider.added)
        calls=[]
        def cancel_after_add(_):
            calls.append(1)
            if len(calls)>1:raise ValueError('cancelled')
        with self.assertRaises(ValueError):self.sources.acquire('tt12345',cancel_after_add)
        self.assertEqual([HASH],self.provider.added)
        self.assertFalse(any(x[0]=='mylist' for x in self.provider.calls))
    def test_incomplete_provider_entry_is_bounded_and_not_readded(self):
        self.provider.ready=False
        with self.assertRaises(ValueError):self.sources.acquire('tt12345',self.guard)
        self.assertEqual([HASH],self.provider.added)
        self.assertEqual(8,sum(x[0]=='mylist' for x in self.provider.calls))
    def test_bad_hashes_and_urls_are_not_used(self):
        self.streams=[{'infoHash':'bad','url':'https://comet.elfhosted.com/playback/'+HASH},{'behaviorHints':{'bingeGroup':'comet|other|'+HASH}}]
        self.assertEqual([],self.sources.candidates('tt12345'));self.assertEqual([],self.provider.calls)
    def test_cache_lookup_batches_and_bounds_hashes(self):
        self.streams=[{'behaviorHints':{'bingeGroup':'comet|torbox|'+format(i,'040x')}} for i in range(201)]
        self.sources.candidates('tt12345')
        self.assertEqual([100,100],[len(q['hash'].split(',')) for e,q,b in self.provider.calls])
    def test_cache_hash_must_match_requested_hash(self):
        self.provider.cached[HASH]['hash']='b'*40
        self.assertIsNone(self.sources.acquire('tt12345',self.guard));self.assertEqual([],self.provider.added)
    def test_ambiguous_post_is_never_retried(self):
        def fail(h):self.provider.added.append(h);raise TimeoutError('private URL')
        self.provider.add_cached=fail
        with self.assertRaises(TimeoutError):self.sources.acquire('tt12345',self.guard)
        self.assertEqual([HASH],self.provider.added)
    def test_provider_post_enforces_cached_only_and_no_seeding(self):
        calls=[]
        @contextmanager
        def request(url,headers,**kw):
            calls.append((url,headers,kw))
            yield io.BytesIO(json.dumps({'success':True,'data':{'torrent_id':987}}).encode())
        with patch('worker_candidate.https_request',request):
            self.assertEqual(987,Provider('fixture-key').add_cached(HASH))
            with self.assertRaises(Exception):Provider('fixture-key').add_cached('bad')
        self.assertEqual(1,len(calls));url,headers,kw=calls[0]
        self.assertEqual('https://api.torbox.app/v1/api/torrents/createtorrent',url)
        self.assertEqual('POST',kw['method']);body=kw['body'].decode()
        self.assertIn('name="add_only_if_cached"\r\n\r\ntrue',body)
        self.assertIn('name="seed"\r\n\r\n3',body);self.assertIn('name="allow_zip"\r\n\r\nfalse',body)
        self.assertNotIn('fixture-key',body);self.assertEqual('Bearer fixture-key',headers['Authorization'])
    def test_existing_endpoint_must_be_unique_https_and_no_credentials_in_authority(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'config.json'
            for value in ('http://comet.elfhosted.com/x/manifest.json','https://user:pass@comet.elfhosted.com/x/manifest.json','https://other.invalid/x/manifest.json'):
                path.write_text(json.dumps({'addons':[{'transportUrl':value}]}))
                with self.assertRaises(ValueError):configured_comet(path)
            path.write_text(json.dumps({'addons':[{'transportUrl':'https://comet.elfhosted.com/x/manifest.json'}]}))
            self.assertEqual('https://comet.elfhosted.com/x',configured_comet(path))


if __name__=='__main__':unittest.main()
