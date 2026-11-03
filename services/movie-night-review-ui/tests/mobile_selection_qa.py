"""Production factory + real owner gateway, generated clip, disposable state only."""
from contextlib import contextmanager
from pathlib import Path
import hashlib
import http.client
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch
from uuid import uuid4

BASE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BASE / name) for name in ('src', 'tests', 'gateway')]
from fastapi.testclient import TestClient
from metadata_discovery import CinemetaDiscovery
from review_service import build_app
from similar_movies import CinemetaSimilar
from standalone_server import MovieNightServer
from test_similar_movies import MetadataFixture
import uvicorn


def main():
    with tempfile.TemporaryDirectory(prefix='afz-selection-qa-') as tmp:
        root = Path(tmp)
        state = root / 'state'; state.mkdir(mode=0o700)
        (state / 'run').mkdir(mode=0o700)
        clip = root / 'generated.mp4'
        subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=black:s=1920x1080:r=1',
                        '-t','1','-c:v','libx264','-pix_fmt','yuv420p','-y',str(clip)], check=True, timeout=30)
        media = clip.read_bytes()
        class Provider:
            resolves = 0
            def _api(self, endpoint, query, bearer=False):
                assert endpoint == 'mylist'
                return [{'id':12, 'name':'Dream.Mission.1.2024.1080p.x264',
                         'download_finished':True, 'download_present':True,
                         'files':[{'id':3,'name':'Dream.Mission.1.2024.1080p.x264.mp4',
                                   'size':len(media),'infected':False,'zipped':False}]}]
            def resolve(self, row):
                assert row['torrentId'] == 12 and row['fileId'] == 3
                self.resolves += 1
                return 'https://fixture.invalid/generated-media'
        provider = Provider()
        @contextmanager
        def open_media(*args, **kwargs):
            response = io.BytesIO(media); response.headers = {'Content-Length':str(len(media))}
            try: yield response
            finally: response.close()
        # A tiny generated clip exercises actual validation. Production byte limits
        # are unchanged; their exact 5–15 GB boundaries have separate unit coverage.
        with patch('movie_night.MIN_BYTES',1), patch('worker_candidate.MIN_BYTES',1):
            origin = 'https://backend.example.test:8447'
            app, controller = build_app(state, origin, downloads=True, auto_downloads=True,
                                        provider=provider, media_root=root / 'media')
            controller.similar.source = CinemetaSimilar(CinemetaDiscovery(MetadataFixture()))
            controller.worker.open_media = open_media
            controller.free = lambda: 200_000_000_000
            controller.worker.free = lambda _: 200_000_000_000
            endpoint = state / 'run/review.sock'
            server = uvicorn.Server(uvicorn.Config(app, uds=str(endpoint), access_log=False,
                                                   log_level='error', lifespan='off'))
            backend = threading.Thread(target=server.run, daemon=True); backend.start()
            for _ in range(100):
                if endpoint.exists(): break
                time.sleep(.02)
            else: raise AssertionError('fixture backend unavailable')
            endpoint.chmod(0o600)
            front = MovieNightServer('http://localhost', origin, 'owner@example.test', 0, str(endpoint))
            public = 'http://localhost:' + str(front.server_port)
            front.public_origin = public; front.host = 'localhost:' + str(front.server_port)
            thread = threading.Thread(target=front.serve_forever, daemon=True); thread.start()
            def request(path, body=None, headers=None, method=None):
                h = {'Tailscale-User-Login':'owner@example.test', **(headers or {})}
                if body is not None: h.update({'Origin':public,'Content-Type':'application/json'})
                c = http.client.HTTPConnection('localhost', front.server_port, timeout=8)
                try:
                    c.request(method or ('POST' if body is not None else 'GET'), '/movie-night/' + path,
                              json.dumps(body).encode() if body is not None else None, h)
                    r = c.getresponse(); data = r.read()
                    return r.status, data
                finally: c.close()
            try:
                before = controller.feedback.saved('billing-owner')
                code, raw = request('api/add-session'); assert code == 200
                session = json.loads(raw); assert session['selectionDownloadEnabled'] is True
                csrf = {'X-Movie-Night-CSRF':session['csrfToken']}
                key = str(uuid4())
                body = {'action':'select-download','imdb':'tt90000001','requestId':key,'retryDownload':False}
                assert request('api/feedback', body)[0] == 403
                assert request('api/add-session', headers={'Tailscale-User-Login':'other@example.test'})[0] == 403
                def select():
                    code, raw = request('api/feedback', body, csrf); assert code == 200, raw
                    job = json.loads(raw)['jobId']
                    for _ in range(100):
                        code, raw = request('api/feedback', {'action':'similar-status','jobId':job}, csrf)
                        assert code == 200, raw
                        value = json.loads(raw)
                        if value['state'] == 'ready': return value
                        time.sleep(.02)
                    raise AssertionError('selection acknowledgment timed out')
                selected = select(); assert selected['selected'] and selected['downloadRequested']
                for _ in range(150):
                    code, raw = request('api/downloads'); assert code == 200
                    downloads = json.loads(raw)
                    if downloads['jobs'] and downloads['jobs'][0]['indexed']: break
                    time.sleep(.02)
                else: raise AssertionError(downloads)
                assert len(downloads['jobs']) == len(downloads['requests']) == 1
                assert downloads['requests'][0]['selectionSource'] == 'nuvio-selection'
                assert controller.feedback.saved('billing-owner') == before
                assert provider.resolves == 1
                code, raw = request('catalog/movie/downloaded.json'); assert code == 200
                assert [m['id'] for m in json.loads(raw)['metas']] == ['tt90000001']
                code, byte = request('media/tt90000001', headers={'Range':'bytes=0-0'})
                assert code == 206 and byte == media[:1]
                assert select()['downloadRequested'] is True
                assert provider.resolves == 1
            finally:
                front.shutdown(); front.server_close(); server.should_exit=True
                backend.join(10); controller.close()
            # Reconstruct the real production controller: authorization/request,
            # file/index and owner isolation all survive without another dispatch.
            app2, restored = build_app(state, origin, downloads=True, auto_downloads=True,
                                       provider=provider, media_root=root/'media')
            try:
                with TestClient(app2) as client:
                    code = client.get('/movie-night/api/downloads', headers={'X-AFZ-Review-Principal':'billing-owner'})
                    assert code.status_code == 200
                    saved = code.json()
                    assert len(saved['requests']) == len(saved['jobs']) == 1
                    assert saved['jobs'][0]['indexed'] is True
                    assert saved['requests'][0]['selectionSource'] == 'nuvio-selection'
                    assert client.get('/movie-night/api/downloads').status_code == 403
                    assert provider.resolves == 1
            finally: restored.close()
            result = {'passed':True,'productionFactory':True,'realOwnerGateway':True,
                      'generatedClipBytes':len(media),'generatedClipSha256':hashlib.sha256(media).hexdigest(),
                      'actualFfprobeValidation':True,'mediaTransfers':provider.resolves,'duplicateTransferPrevented':True,
                      'groupUnchanged':True,'readyCatalogVerified':True,'range206':True,'ownerCsrfEnforced':True,
                      'restartPersistence':True,'realMoviesUsed':False,'productionDataUsed':False}
            output = Path(os.environ.get('AFZ_SELECTION_QA_OUTPUT', str(BASE/'qa/selection-integration.json')))
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(result, indent=2)+'\n')
            print(json.dumps(result))

if __name__ == '__main__': main()

