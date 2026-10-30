"""Isolated subtitle tests: fictional IDs, generated clips, private loopback only."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'src'), str(ROOT/'gateway')]
from adapters import MediaIndex
from server_subtitles import SubtitleCache, SubtitleUnavailable, attach_subtitle_routes, _bounded_tool, _vtt
from nuvio_subtitle_bridge import descriptors, enable_subtitles, with_stream_subtitles, with_subtitle_resource
from standalone_server import MovieNightServer

ID = 'tt90001'
PUBLIC = 'https://movie.example.test:8453'
OWNER = 'owner@example.test'
VTT = b'WEBVTT\n\n00:00.000 --> 00:01.500\nSynthetic subtitle fixture.\n'
PROBE = {'streams': [
    {'index': 1, 'codec_name': 'subrip', 'tags': {'language': 'eng', 'title': 'English [SDH]'}, 'disposition': {'forced': 0}},
    {'index': 2, 'codec_name': 'subrip', 'tags': {'language': 'eng', 'title': 'English'}, 'disposition': {'forced': 1}},
    {'index': 3, 'codec_name': 'dvd_subtitle', 'tags': {'language': 'ger'}},
]}


class CacheFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='afz-subtitles-')
        self.root = Path(self.tmp.name); self.root.chmod(0o700)
        self.media = self.root/'media'; self.media.mkdir(mode=0o700)
        (self.media/'Movies').mkdir(mode=0o700)
        self.file = self.media/'Movies'/(ID+'.2024.mkv')
        self.file.write_bytes(b'disposable fake movie bytes')
        self.index = MediaIndex(self.root/'index.db', self.media)
        self.put_index()
        self.calls = []
        def tool(args, fd, **kwargs):
            self.calls.append(args[0])
            return json.dumps(PROBE).encode() if '-show_entries' in args else VTT
        self.tool = tool
        self.cache = SubtitleCache(self.index, self.root/'cache', ffprobe=sys.executable,
                                   ffmpeg=sys.executable, tool=tool)

    def put_index(self):
        with sqlite3.connect(self.index.db) as db:
            db.execute('INSERT OR REPLACE INTO media VALUES(?,?,?,?,?,1)',
                       (ID, self.file.name, json.dumps({'title':'Subtitle fixture','year':2024}),
                        self.file.stat().st_size, hashlib.sha256(self.file.read_bytes()).hexdigest()))

    def tearDown(self):
        self.tmp.cleanup()


class CacheTests(CacheFixture):
    def test_prepare_lists_full_sdh_forced_and_skips_bitmap(self):
        before = self.file.read_bytes()
        rows = self.cache.prepare(ID)
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[0]['hearingImpaired'])
        self.assertTrue(rows[1]['forced'])
        self.assertIn('Forced', rows[1]['label'])
        self.assertNotEqual(rows[0]['id'], rows[1]['id'])
        self.assertEqual(self.cache.content(ID, rows[0]['id']), VTT)
        self.assertEqual(self.file.read_bytes(), before)

    def test_cold_reads_never_extract_or_fetch(self):
        self.assertEqual(self.cache.tracks(ID), [])
        self.assertEqual(self.calls, [])

    def test_cache_hit_does_not_reextract(self):
        self.cache.prepare(ID)
        count = len(self.calls)
        self.cache.prepare(ID)
        self.assertEqual(len(self.calls), count + 1)  # metadata probe only, not text extraction

    def test_language_filter_and_track_budget(self):
        self.assertEqual(self.cache.prepare(ID, languages={'hin'}), [])
        rows = self.cache.prepare(ID, languages={'eng'}, max_tracks=1)
        self.assertEqual(len(rows), 1)

    def test_invalid_id_or_budget_refused(self):
        for ident in ('../file', 'tt1', ID+'/etc/passwd', 'file:///movie'):
            with self.assertRaises(ValueError): self.cache.prepare(ident)
        for count in (True, 0, 65):
            with self.assertRaises(ValueError): self.cache.prepare(ID, max_tracks=count)
        with self.assertRaises(ValueError): self.cache.prepare(ID, languages={'eng; rm'})
        self.assertFalse(self.calls)

    def test_deleted_movie_never_serves_cached_track(self):
        track = self.cache.prepare(ID)[0]
        self.file.unlink()
        with self.assertRaises(ValueError): self.cache.content(ID, track['id'])

    def test_same_size_replacement_invalidates_cache(self):
        old = self.cache.prepare(ID)[0]
        other = self.file.with_suffix('.tmp'); other.write_bytes(self.file.read_bytes())
        other.replace(self.file)
        self.assertEqual(self.cache.tracks(ID), [])
        with self.assertRaises(ValueError): self.cache.content(ID, old['id'])

    def test_unindexed_or_hidden_movie_fails_closed(self):
        old = self.cache.prepare(ID)[0]
        with sqlite3.connect(self.index.db) as db: db.execute('UPDATE media SET visible=0')
        with self.assertRaises(ValueError): self.cache.content(ID, old['id'])

    def test_deletion_tombstone_blocks_cached_text(self):
        old = self.cache.prepare(ID)[0]
        with sqlite3.connect(self.index.db) as db:
            db.execute('CREATE TABLE removed_media(id TEXT PRIMARY KEY)')
            db.execute('INSERT INTO removed_media VALUES(?)', (ID,))
        with self.assertRaises(ValueError): self.cache.content(ID, old['id'])

    def test_movie_symlink_and_hardlink_rejected(self):
        real = self.file.with_suffix('.original'); self.file.rename(real)
        self.file.symlink_to(real)
        with self.assertRaises(ValueError): self.cache.prepare(ID)
        self.file.unlink(); self.file.hardlink_to(real)
        with self.assertRaises(ValueError): self.cache.prepare(ID)

    def test_cache_symlink_and_tamper_rejected(self):
        old = self.cache.prepare(ID)[0]; text = self.cache.directory/(old['id']+'.vtt')
        text.write_bytes(VTT+b'tamper'); text.chmod(0o600)
        with self.assertRaises(ValueError): self.cache.content(ID, old['id'])
        text.unlink(); text.symlink_to(self.file)
        with self.assertRaises((ValueError,OSError)): self.cache.content(ID, old['id'])

    def test_cache_root_must_be_private(self):
        self.cache.directory.chmod(0o755)
        with self.assertRaises(ValueError): self.cache.tracks(ID)

    def test_changed_source_during_extract_not_published(self):
        original = self.tool
        before = self.file.stat()
        extractions = []
        def replace(args,fd,**kwargs):
            value=original(args,fd,**kwargs)
            if '-show_entries' not in args:
                # The tool callback runs after _movie captures its fingerprint
                # and before its exit check. Same-size writes alone can keep
                # both timestamps on a coarse filesystem clock tick; control
                # mtime explicitly instead of waiting for the clock to advance.
                self.file.write_bytes(b'Z'*before.st_size)
                os.utime(self.file, ns=(before.st_atime_ns,
                                        before.st_mtime_ns + 2_000_000_000))
                changed = os.fstat(fd)
                self.assertEqual(changed.st_ino, before.st_ino)
                self.assertEqual(changed.st_size, before.st_size)
                self.assertNotEqual(changed.st_mtime_ns, before.st_mtime_ns)
                extractions.append(fd)
            return value
        self.cache.tool=replace
        with self.assertRaisesRegex(SubtitleUnavailable, 'Movie identity changed'):
            self.cache.prepare(ID)
        self.assertTrue(extractions)
        self.assertFalse(list(self.cache.directory.glob('*.json')))
        self.assertEqual(self.cache.tracks(ID), [])

    def test_single_preparation_worker_and_no_partial_manifest(self):
        self.cache.prepare_lock.acquire()
        try:
            with self.assertRaises(ValueError): self.cache.prepare(ID)
        finally: self.cache.prepare_lock.release()
        self.cache.tool=lambda *a,**k: b'not json'
        with self.assertRaises(ValueError): self.cache.prepare(ID)
        self.assertFalse(list(self.cache.directory.glob('*.json')))

    def test_valid_utf8_arabic_and_vtt_rejection(self):
        text='WEBVTT\n\n00:00.000 --> 00:01.500\nاختبار الترجمة\n'.encode()
        self.assertEqual(_vtt(text),text)
        for bad in (b'',b'<html>Error</html>',b'WEBVTT\n',b'WEBVTT\n\xff'):
            with self.assertRaises(ValueError):_vtt(bad)

    def test_tool_output_and_timeout_bounds(self):
        with self.file.open('rb') as f:
            with self.assertRaises(ValueError):
                _bounded_tool([sys.executable,'-c','import sys;sys.stdout.write("x"*1000)'],f.fileno(),cap=30,timeout=2)
            with self.assertRaises(ValueError):
                _bounded_tool([sys.executable,'-c','import time;time.sleep(2)'],f.fileno(),cap=30,timeout=.1)


class BridgePureTests(unittest.TestCase):
    def test_fixed_same_origin_url_label_and_manifest(self):
        track={'id':'a'*32+'-s2','lang':'eng','label':'English [SDH]','url':'https://evil.test/x'}
        rows=descriptors(PUBLIC,ID,{'tracks':[track,track]})
        self.assertEqual(len(rows),1)
        self.assertTrue(rows[0]['url'].startswith(PUBLIC+'/movie-night/subtitle-files/'+ID+'/'))
        self.assertNotIn('evil',str(rows))
        self.assertIn('SDH',rows[0]['label'])
        manifest={'resources':['catalog','stream']}
        result=with_subtitle_resource(manifest)
        self.assertEqual(manifest,{'resources':['catalog','stream']})
        self.assertEqual(with_subtitle_resource(result),result)

    def test_invalid_descriptor_no_path_or_url_injection(self):
        for track in ({'id':'../x','lang':'eng'}, {'id':'a'*32+'-s2','lang':'en/../../../x'},
                      {'id':'a'*32+'-s2','lang':'eng','label':'bad\nheader'}):
            with self.assertRaises(ValueError):descriptors(PUBLIC,ID,{'tracks':[track]})
        with self.assertRaises(ValueError):descriptors('http://public.test',ID,{'tracks':[]})

    def test_attach_only_matching_stream_and_preserve_existing(self):
        own=PUBLIC+'/movie-night/media/'+ID
        payload={'streams':[{'url':own},{'url':'https://unrelated.test/movie'}]}
        tracks=[{'id':'a','lang':'eng','url':PUBLIC+'/sub.vtt'}]
        out=with_stream_subtitles(payload,PUBLIC,ID,tracks)
        self.assertNotIn('subtitles',payload['streams'][0])
        self.assertEqual(out['streams'][0]['subtitles'],tracks)
        self.assertNotIn('subtitles',out['streams'][1])


class GatewayTests(CacheFixture):
    def setUp(self):
        super().setUp()
        from fastapi import FastAPI,Request,HTTPException
        import uvicorn
        self.track=self.cache.prepare(ID)[0]
        def authorize(request):
            return request.headers.getlist('x-afz-review-principal')==['billing-owner']
        app=FastAPI()
        @app.get('/movie-night/catalog/movie/downloaded.json')
        def downloaded(request: Request):
            if not authorize(request):raise HTTPException(403)
            return {'metas':self.index.metas()}
        attach_subtitle_routes(app,self.cache,authorize=authorize)
        self.path=self.root/'review.sock'
        self.backend=uvicorn.Server(uvicorn.Config(app,uds=str(self.path),log_level='critical',access_log=False,lifespan='off'))
        self.bt=threading.Thread(target=self.backend.run,daemon=True);self.bt.start()
        deadline=time.monotonic()+5
        while not self.backend.started and time.monotonic()<deadline:time.sleep(.01)
        self.assertTrue(self.backend.started)
        self.path.chmod(0o600)
        self.front=MovieNightServer(PUBLIC,PUBLIC,OWNER,port=0,movie_socket=str(self.path))
        enable_subtitles(self.front)
        self.ft=threading.Thread(target=self.front.serve_forever,kwargs={'poll_interval':.01},daemon=True);self.ft.start()

    def tearDown(self):
        self.front.shutdown();self.front.server_close();self.ft.join(3)
        self.backend.should_exit=True;self.bt.join(5)
        super().tearDown()

    def call(self,path,method='GET',headers=None,identity=OWNER):
        con=http.client.HTTPConnection('127.0.0.1',self.front.server_port,timeout=5)
        con.putrequest(method,path,skip_host=True)
        h=[('Host','movie.example.test:8453')]
        if identity is not None:h.append(('Tailscale-User-Login',identity))
        h.extend(headers or [])
        for k,v in h:con.putheader(k,v)
        con.endheaders();r=con.getresponse()
        ans=(r.status,dict(r.getheaders()),r.read());con.close();return ans

    def test_owner_manifest_stream_list_and_vtt_download(self):
        status,headers,body=self.call('/movie-night/manifest.json')
        self.assertEqual(status,200)
        self.assertTrue(any(isinstance(x,dict) and x.get('name')=='subtitles' for x in json.loads(body)['resources']))
        status,_,body=self.call('/movie-night/stream/movie/'+ID+'.json')
        self.assertEqual(status,200)
        stream=json.loads(body)['streams'][0]
        self.assertEqual(len(stream['subtitles']),2)
        self.assertEqual(stream['url'],PUBLIC+'/movie-night/media/'+ID)
        status,_,body=self.call('/movie-night/subtitles/movie/'+ID+'.json')
        self.assertEqual(status,200)
        track=json.loads(body)['subtitles'][0]
        route=track['url'].removeprefix(PUBLIC)
        status,headers,body=self.call(route)
        self.assertEqual((status,body),(200,VTT))
        self.assertIn('no-store',headers['Cache-Control'])
        self.assertEqual(headers['Content-Type'],'text/vtt; charset=utf-8')
        status,headers,body=self.call(route,'HEAD')
        self.assertEqual((status,body),(200,b''))
        self.assertEqual(int(headers['Content-Length']),len(VTT))

    def test_owner_origin_host_and_duplicate_identity_gates(self):
        route='/movie-night/subtitles/movie/'+ID+'.json'
        for identity in (None,'stranger@example.test'):
            self.assertEqual(self.call(route,identity=identity)[0],403)
        for headers in ([('Origin','https://evil.test')],[('Host','evil.test')],
                        [('Tailscale-User-Login',OWNER)],[('Sec-Fetch-Site','cross-site')]):
            self.assertEqual(self.call(route,headers=headers)[0],403)

    def test_no_writes_query_traversal_and_bad_route(self):
        for route in ('/movie-night/subtitles/movie/'+ID+'.json?x=1',
                      '/movie-night/subtitles/movie/tt1.json',
                      '/movie-night/subtitle-files/'+ID+'/../secret.vtt',
                      '/movie-night/subtitle-files/'+ID+'/%2e%2e.vtt'):
            self.assertEqual(self.call(route)[0],404)
        self.assertEqual(self.call('/movie-night/subtitles/movie/'+ID+'.json','POST',headers=[('Origin',PUBLIC)])[0],404)

    def test_unavailable_caption_does_not_break_video(self):
        for p in self.cache.directory.glob('*.json'):p.unlink()
        calls=len(self.calls)
        status,_,body=self.call('/movie-night/stream/movie/'+ID+'.json')
        self.assertEqual(status,200)
        self.assertEqual(len(json.loads(body)['streams']),1)
        self.assertNotIn('subtitles',json.loads(body)['streams'][0])
        self.assertEqual(len(self.calls),calls)

    def test_replaced_movie_cached_subtitle_is_not_served(self):
        route='/movie-night/subtitle-files/'+ID+'/'+self.track['id']+'.vtt'
        self.file.write_bytes(b'X'*self.file.stat().st_size)
        self.assertEqual(self.call(route)[0],404)


class RealMediaTests(CacheFixture):
    def test_real_ffmpeg_extraction_and_utf8_timestamps(self):
        ffmpeg=shutil.which('ffmpeg');ffprobe=shutil.which('ffprobe')
        self.assertIsNotNone(ffmpeg,'Provide the actual service runtime bin directory on PATH')
        self.assertIsNotNone(ffprobe)
        eng=self.root/'fixture.eng.srt';ara=self.root/'fixture.ara.srt'
        eng.write_text('1\n00:00:00,200 --> 00:00:01,200\nSynthetic English test cue.\n',encoding='utf-8')
        ara.write_text('1\n00:00:00,200 --> 00:00:01,200\nاختبار ترجمة\n',encoding='utf-8')
        subprocess.run([ffmpeg,'-nostdin','-v','error','-f','lavfi','-i','color=c=black:s=32x32:r=1',
            '-i',str(eng),'-i',str(ara),'-map','0:v','-map','1:s','-map','2:s',
            '-t','2','-c:v','libx264','-c:s','srt','-metadata:s:s:0','language=eng',
            '-metadata:s:s:0','title=English [SDH]','-metadata:s:s:1','language=ara',
            '-y',str(self.file)],check=True,timeout=20)
        self.put_index()
        before=hashlib.sha256(self.file.read_bytes()).hexdigest()
        cache=SubtitleCache(self.index,self.root/'real-cache',ffmpeg=ffmpeg,ffprobe=ffprobe)
        tracks=cache.prepare(ID)
        self.assertEqual({x['lang'] for x in tracks},{'eng','ara'})
        for track in tracks:
            text=cache.content(ID,track['id']).decode()
            self.assertIn('00:00.200 --> 00:01.200',text)
            self.assertIn('Synthetic English' if track['lang']=='eng' else 'اختبار ترجمة',text)
        self.assertEqual(hashlib.sha256(self.file.read_bytes()).hexdigest(),before)


if __name__=='__main__':unittest.main()
