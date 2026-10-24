"""Finalize -> cached acquisition -> real fixture bytes -> index through owner gateway."""
from pathlib import Path
from contextlib import contextmanager
import sys,os,tempfile,threading,time,json,subprocess,sqlite3,hashlib,io,socket
from contextlib import ExitStack
BASE=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(BASE/'src'),str(BASE/'tests'),str(BASE/'.test-deps'),str(BASE/'gateway')]
from test_downloads import Harness
from standalone_server import MovieNightServer
from webapp import create_app
from adapters import ffprobe,ProviderInventory
from cached_sources import CachedSources
import uvicorn

with tempfile.TemporaryDirectory(prefix='afz-auto-qa-') as td:
    root=Path(td);root.chmod(0o700);(root/'backend').mkdir(mode=0o700)
    video=root/'generated.mkv'
    subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=black:s=1920x1080:r=1','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-y',str(video)],check=True,timeout=30)
    h=Harness(root/'backend',video.read_bytes());h.worker.probe=ffprobe
    disk_fixture=None
    if os.environ.get('AFZ_QA_8TB')=='1':
        from storage_volume import MediaVolume
        volume=MediaVolume();volume.ensure()
        disk_fixture=tempfile.TemporaryDirectory(prefix='fixture-qa-',dir=volume.root)
        h.media=Path(disk_fixture.name);h.worker.root=h.media;h.index.root=h.media
        h.worker.storage_guard=volume.check;h.index.storage_guard=volume.check;h.controller.free=volume.check
    with sqlite3.connect(h.db) as db:db.execute('DELETE FROM movie_finalized')
    template=h.payload['movies'][0]
    h.payload['movies'].extend(dict(template,id='tt'+str(12348+i),name='Fixture Extra '+str(i+1)) for i in range(8))
    class Cache:
        added=[]
        def add_cached(self,info_hash):self.added.append(info_hash);return 12
        def _api(self,endpoint,query,bearer):
            f={'id':3,'name':h.choice.provider_name,'size':h.choice.size,'infected':False,'zipped':False}
            if endpoint=='checkcached':return {'a'*40:{'hash':'a'*40,'name':f['name'],'files':[f]}}
            if endpoint=='mylist':return dict(id=12,hash='a'*40,name=f['name'],files=[f],download_finished=True,download_present=True)
            raise AssertionError('unexpected provider request')
    cache=Cache()
    @contextmanager
    def streams(url):
        result=[{'behaviorHints':{'bingeGroup':'comet|torbox|'+'a'*40}}] if url.endswith('/tt12345.json') else []
        yield io.BytesIO(json.dumps({'streams':result}).encode())
    h.controller.choices=lambda imdb:[]
    h.controller.inventory=ProviderInventory(cache)
    h.controller.enable_auto_downloads(CachedSources(cache,lambda:h.payload,endpoint=lambda:'https://fixture.invalid',opener=streams).acquire)
    endpoint=root/'backend/review.sock';relay_endpoint=root/'backend/relay.sock';backend_origin='https://backend.example.test:8447'
    front=MovieNightServer('http://localhost',backend_origin,'owner@example.test',0,str(relay_endpoint))
    origin='http://localhost:'+str(front.server_port);front.public_origin=origin;front.host='localhost:'+str(front.server_port)
    app=create_app(h.controller,lambda r:'billing-owner' if r.headers.get('x-afz-review-principal')=='billing-owner' else None,allowed_origin=backend_origin)
    from private_relay import RelayAuth,RelayServer,RelayHandler
    tcp=socket.socket();tcp.bind(('127.0.0.1',0));tcp.listen(128)
    uds=socket.socket(socket.AF_UNIX);uds.bind(str(endpoint));endpoint.chmod(0o600);uds.listen(128)
    relay=RelayServer(str(relay_endpoint),RelayHandler);relay.host='127.0.0.1';relay.port=tcp.getsockname()[1];relay.secret='a'*64
    relay_endpoint.chmod(0o600)
    server=uvicorn.Server(uvicorn.Config(RelayAuth(app,relay.secret,peer='127.0.0.1',unix_path=endpoint),access_log=False,log_level='error',lifespan='off',proxy_headers=False))
    backend=threading.Thread(target=lambda:server.run(sockets=[tcp,uds]),daemon=True);backend.start()
    from movie_transport import UnixConnection
    def verify_index(imdb,size):
        c=UnixConnection(endpoint)
        try:
            c.request('HEAD','/movie-night/media/'+imdb,headers={'X-AFZ-Review-Principal':'billing-owner'});r=c.getresponse()
            return r.status==200 and int(r.getheader('Content-Length','-1'))==size
        finally:c.close()
    h.worker.verify_route=verify_index
    relay_thread=threading.Thread(target=relay.serve_forever,daemon=True);relay_thread.start()
    frontend=threading.Thread(target=front.serve_forever,daemon=True);frontend.start()
    try:
        out=BASE/'qa/auto';out.mkdir(parents=True,exist_ok=True)
        env=dict(os.environ,AFZ_GATEWAY_QA_ORIGIN=origin,AFZ_GATEWAY_QA_OUTPUT=str(out))
        result=subprocess.run([os.environ.get('AFZ_NODE','/home/coolyo/.local/bin/node'),str(BASE/'tests'/os.environ.get('AFZ_BROWSER_SCRIPT','auto_browser.cjs'))],capture_output=True,text=True,env=env,timeout=130)
        (out/'browser.log').write_text(result.stdout+result.stderr)
        (out/'fixture-state.json').write_text(json.dumps({'saved':h.controller.feedback.saved('billing-owner'),'downloads':h.controller.downloads('billing-owner'),'providerResolves':h.provider.resolves,'providerAdds':len(cache.added)},indent=2))
        assert result.returncode==0,(result.stdout+result.stderr)[-3000:]
        assert h.provider.resolves==1 and len(cache.added)==1
        paths=[p for folder in ('src','gateway','tests') for p in (BASE/folder).glob('*') if p.is_file() and p.suffix in ('.py','.js','.css','.html','.cjs')]
        (out/'tested-source.json').write_text(json.dumps({str(p.relative_to(BASE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},indent=2))
        print('AUTO_FINALIZE_CACHE_TRANSFER_RANGE_RELOAD_PASS_360_412_1280')
        print('PRIVATE_RELAY_PASS', 'REAL_8TB_VOLUME' if disk_fixture else 'DISPOSABLE_VOLUME')
    finally:
        front.shutdown();front.server_close();relay.shutdown();relay.server_close();server.should_exit=True;backend.join(10);tcp.close();uds.close();h.close()
        if disk_fixture:disk_fixture.cleanup()
