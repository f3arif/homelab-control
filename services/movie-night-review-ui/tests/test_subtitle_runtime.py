"""Subtitle startup, prewarm and actual gateway->relay->backend qualification."""
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'src'), str(ROOT/'gateway'), str(ROOT/'tests')]
import test_server_subtitles as fixtures
import uvicorn
import review_service
from nuvio_subtitle_bridge import subtitle_request_id
from private_relay import RelayAuth, RelayServer, RelayHandler
from standalone_server import MovieNightServer
from subtitle_service_entry import add_subtitles_to_factory
from subtitle_gateway_entry import gateway_class_with_subtitles
from subtitle_prewarm import ReadOnlySubtitleIndex, transfers_idle, prewarm_once


class TvRequestTests(unittest.TestCase):
    def test_plain_phone_and_native_tv_paths(self):
        base='/movie-night/subtitles/movie/'+fixtures.ID
        for suffix in ('.json', '/videoHash=0123456789abcdef.json',
            '/videoSize=12345.json', '/filename=Example%20Movie.2024.mkv.json',
            '/videoHash=0123456789abcdef&videoSize=12345&filename=Example%20Movie.mkv.json'):
            self.assertEqual(subtitle_request_id(base+suffix), fixtures.ID)

    def test_rejects_invalid_or_duplicate_hints(self):
        base='/movie-night/subtitles/movie/'+fixtures.ID+'/'
        for extra in ('videoHash=bad', 'videoSize=0', 'videoSize=15000000001',
            'url=https://evil.test', 'videoSize=1&videoSize=2', 'filename=%2Fetc%2Fpasswd',
            'filename=..%5Cprivate', 'filename=%252Fetc', 'filename=bad%ZZ',
            'filename=bad%0Aheader', 'filename=', 'videoHash=0123456789abcdef?x=1'):
            self.assertIsNone(subtitle_request_id(base+extra+'.json'),extra)


class PreparedPolicyTests(fixtures.CacheFixture):
    def test_policy_bound_cache_and_no_repeat_extraction(self):
        self.assertFalse(self.cache.prepared(fixtures.ID,languages={'eng'},max_tracks=4))
        self.cache.prepare(fixtures.ID,languages={'eng'},max_tracks=4)
        count=len(self.calls)
        self.assertTrue(self.cache.prepared(fixtures.ID,languages={'eng'},max_tracks=4))
        self.assertEqual(len(self.calls),count)
        self.assertFalse(self.cache.prepared(fixtures.ID,languages={'hin'},max_tracks=4))
        self.assertFalse(self.cache.prepared(fixtures.ID,languages={'eng'},max_tracks=1))

    def test_missing_caption_asset_is_prepared_again(self):
        tracks=self.cache.prepare(fixtures.ID,languages={'eng'},max_tracks=4)
        (self.cache.directory/(tracks[0]['id']+'.vtt')).unlink()
        self.assertFalse(self.cache.prepared(fixtures.ID,languages={'eng'},max_tracks=4))

    def test_preparation_deadline_stops_before_extraction(self):
        with patch('server_subtitles.time.monotonic', side_effect=[0.0, 0.0, 2.0]):
            with self.assertRaises(ValueError):
                self.cache.prepare(fixtures.ID, budget_seconds=1)
        self.assertEqual(len(self.calls),1)  # Probe only, no text extraction.
        self.assertFalse(list(self.cache.directory.glob('*.json')))

    def test_zero_tracks_is_a_completed_pass_not_retry_loop(self):
        self.cache.prepare(fixtures.ID,languages={'hin'})
        self.assertTrue(self.cache.prepared(fixtures.ID,languages={'hin'}))
        self.assertEqual(self.cache.tracks(fixtures.ID),[])

    def test_readonly_index_and_transfer_gate_preserve_database(self):
        self.index.db.chmod(0o600)
        before=hashlib.sha256(self.index.db.read_bytes()).hexdigest()
        ro=ReadOnlySubtitleIndex(self.index.db,self.media,storage_guard=lambda:None)
        self.assertEqual(ro.ids(),[fixtures.ID])
        self.assertEqual(ro.resolve(fixtures.ID),self.file)
        self.assertEqual(before,hashlib.sha256(self.index.db.read_bytes()).hexdigest())
        jobs=self.root/'jobs.db'
        with sqlite3.connect(jobs) as c:
            c.execute('CREATE TABLE jobs(state TEXT)')
            c.execute("INSERT INTO jobs VALUES('downloading')")
        jobs.chmod(0o600)
        self.assertFalse(transfers_idle(jobs))
        with sqlite3.connect(jobs) as c:c.execute("UPDATE jobs SET state='indexed'")
        self.assertTrue(transfers_idle(jobs))
        self.assertFalse(transfers_idle(self.root/'missing.db'))
        self.assertFalse((self.root/'missing.db').exists())


class PrewarmTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='afz-prewarm-')
        root=Path(self.temp.name);root.chmod(0o700)
        class Index:
            def ids(self):return ['tt90001','tt90002','tt90003']
        class Cache:
            directory=root
            index=Index()
            done=set()
            calls=[]
            def prepared(self,imdb,**kw):return imdb in self.done
            def prepare(self,imdb,**kw):self.done.add(imdb);self.calls.append(imdb)
        self.cache=Cache()

    def tearDown(self):self.temp.cleanup()

    def test_bounded_pass_resumes_and_skips_completed_movies(self):
        a=prewarm_once(self.cache,idle=lambda:True,max_movies=2)
        self.assertEqual(a['prepared'],2)
        b=prewarm_once(self.cache,idle=lambda:True,max_movies=2)
        self.assertEqual((b['prepared'],b['alreadyReady']),(1,2))
        self.assertEqual(len(self.cache.calls),3)

    def test_busy_unknown_transfer_state_does_not_extract(self):
        self.assertEqual(prewarm_once(self.cache,idle=lambda:False)['prepared'],0)
        self.assertFalse(self.cache.calls)

    def test_cross_process_lock_prevents_duplicate_worker(self):
        path=self.cache.directory/'worker.lock'
        with path.open('w') as lock:
            path.chmod(0o600);fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertTrue(prewarm_once(self.cache,idle=lambda:True)['busy'])
        self.assertFalse(self.cache.calls)


class FullRelaySubtitleTests(fixtures.CacheFixture):
    def setUp(self):
        super().setUp()
        state=self.root/'state';state.mkdir(mode=0o700)
        class NoProvider:
            def _api(self,*a,**k):raise AssertionError('No provider use in subtitle fixtures')
        wrapped=add_subtitles_to_factory(review_service.build_app,
            cache_dir=self.root/'runtime-cache', principal=review_service.PRINCIPAL,
            ffmpeg=sys.executable,ffprobe=sys.executable)
        self.app,self.controller=wrapped(state,fixtures.PUBLIC,downloads=True,
                                         provider=NoProvider(),media_root=self.media)
        self.assertIsNone(self.controller.delete_service)
        with sqlite3.connect(self.controller.index.db) as db:
            db.execute('INSERT INTO media VALUES(?,?,?,?,?,1)',(fixtures.ID,self.file.name,
                json.dumps({'title':'Synthetic subtitle fixture','year':2024}),self.file.stat().st_size,
                hashlib.sha256(self.file.read_bytes()).hexdigest()))
        self.cache=self.app.state.movie_night_subtitles
        self.cache.tool=self.tool
        self.cache.prepare(fixtures.ID)
        self.secret=secrets.token_hex(32)
        self.listener=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1',0));self.listener.listen(16)
        self.backend=uvicorn.Server(uvicorn.Config(RelayAuth(self.app,self.secret,peer='127.0.0.1'),
            log_level='critical',access_log=False,proxy_headers=False,lifespan='off'))
        self.bt=threading.Thread(target=self.backend.run,kwargs={'sockets':[self.listener]},daemon=True)
        self.bt.start()
        end=time.monotonic()+5
        while not self.backend.started and time.monotonic()<end:time.sleep(.01)
        self.assertTrue(self.backend.started)
        path=self.root/'relay.sock'
        self.relay=RelayServer(str(path),RelayHandler);path.chmod(0o600)
        self.relay.host,self.relay.port,self.relay.secret='127.0.0.1',self.listener.getsockname()[1],self.secret
        self.rt=threading.Thread(target=self.relay.serve_forever,kwargs={'poll_interval':.01},daemon=True)
        self.rt.start()
        self.front=gateway_class_with_subtitles(MovieNightServer)(fixtures.PUBLIC,fixtures.PUBLIC,
            fixtures.OWNER,port=0,movie_socket=str(path))
        self.ft=threading.Thread(target=self.front.serve_forever,kwargs={'poll_interval':.01},daemon=True)
        self.ft.start()

    def tearDown(self):
        self.front.shutdown();self.front.server_close();self.ft.join(3)
        self.relay.shutdown();self.relay.server_close();self.rt.join(3)
        self.backend.should_exit=True;self.bt.join(3);self.listener.close()
        self.controller.close()
        super().tearDown()

    def request(self,path,method='GET',owner=fixtures.OWNER,headers=None):
        con=http.client.HTTPConnection('127.0.0.1',self.front.server_port,timeout=5)
        values={'Host':'movie.example.test:8453'}
        if owner is not None:values['Tailscale-User-Login']=owner
        values.update(headers or {})
        con.request(method,path,headers=values)
        r=con.getresponse();out=(r.status,dict(r.getheaders()),r.read());con.close();return out

    def test_tv_extra_request_through_all_boundaries_and_vtt_head(self):
        path='/movie-night/subtitles/movie/'+fixtures.ID+'/videoHash=0123456789abcdef&videoSize=123&filename=Synthetic%20Test.mkv.json'
        status,headers,body=self.request(path)
        self.assertEqual(status,200,body)
        tracks=json.loads(body)['subtitles'];self.assertEqual(len(tracks),2)
        self.assertIn('name',tracks[0]);self.assertIn('language',tracks[0])
        route=tracks[0]['url'].removeprefix(fixtures.PUBLIC)
        status,_,body=self.request(route);self.assertEqual((status,body),(200,fixtures.VTT))
        status,h,body=self.request(route,'HEAD')
        self.assertEqual((status,body),(200,b''));self.assertEqual(int(h['Content-Length']),len(fixtures.VTT))
        status,_,body=self.request('/movie-night/stream/movie/'+fixtures.ID+'.json')
        self.assertEqual(status,200);self.assertEqual(len(json.loads(body)['streams'][0]['subtitles']),2)
        self.assertEqual(self.request('/movie-night/api/delete-server/'+fixtures.ID)[0],404)

    def test_no_owner_or_invalid_origin_still_denied(self):
        path='/movie-night/subtitles/movie/'+fixtures.ID+'/videoSize=123.json'
        self.assertEqual(self.request(path,owner=None)[0],403)
        self.assertEqual(self.request(path,owner='other@example.test')[0],403)
        self.assertEqual(self.request(path,headers={'Origin':'https://evil.test'})[0],403)
        con=http.client.HTTPConnection('127.0.0.1',self.listener.getsockname()[1],timeout=5)
        con.request('GET','/movie-night/api/subtitles/'+fixtures.ID,
                    headers={'X-AFZ-Review-Principal':'billing-owner'})
        r=con.getresponse();r.read();con.close();self.assertEqual(r.status,403)

    def test_stream_survives_caption_cache_outage_without_triggering_work(self):
        count=len(self.calls)
        for p in self.cache.directory.glob('*.json'):p.unlink()
        status,_,body=self.request('/movie-night/stream/movie/'+fixtures.ID+'.json')
        self.assertEqual(status,200);streams=json.loads(body)['streams']
        self.assertEqual(len(streams),1);self.assertNotIn('subtitles',streams[0])
        self.assertEqual(len(self.calls),count)


class LauncherTests(unittest.TestCase):
    def test_backend_preserves_arguments_and_restores_factory(self):
        import subtitle_service_entry as entry
        original = review_service.build_app
        argv = sys.argv
        args = ['--state','/fixture/state','--origin',fixtures.PUBLIC,'--downloads',
                '--auto-downloads','--relay-secret','/fixture/secret','--listen','100.77.196.70']
        seen = []
        def existing_main():
            seen.extend(sys.argv[1:])
            self.assertIsNot(review_service.build_app,original)
        with patch.object(review_service,'main',existing_main):
            entry.main(['--subtitle-cache','/fixture/cache',*args])
        self.assertEqual(seen,args)
        self.assertIs(review_service.build_app,original)
        self.assertIs(sys.argv,argv)

    def test_gateway_preserves_owner_configuration_arguments(self):
        import subtitle_gateway_entry as entry
        import standalone_server
        original = standalone_server.MovieNightServer
        argv = sys.argv
        args = ['--owner-config','/fixture/owner.json','--origin',fixtures.PUBLIC,
                '--backend-origin',fixtures.PUBLIC,'--socket','/fixture/review.sock']
        seen = []
        def existing_main():
            seen.extend(sys.argv[1:])
            self.assertTrue(issubclass(standalone_server.MovieNightServer,original))
        with patch.object(standalone_server,'main',existing_main):
            entry.main(args)
        self.assertEqual(seen,args)
        self.assertIs(standalone_server.MovieNightServer,original)
        self.assertIs(sys.argv,argv)


if __name__=='__main__':unittest.main()
