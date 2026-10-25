"""Real HTTP owner gateway + server persistence; disposable movie metadata only."""
from pathlib import Path
import hashlib,json,os,sqlite3,subprocess,sys,tempfile,threading,time
BASE=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(BASE/'src'),str(BASE/'tests'),str(BASE/'gateway')]
from test_downloads import Harness
from webapp import create_app
from standalone_server import MovieNightServer
import uvicorn

with tempfile.TemporaryDirectory(prefix='afz-title-popup-qa-') as td:
    root=Path(td);root.chmod(0o700);backend_root=root/'backend';backend_root.mkdir(mode=0o700)
    h=Harness(backend_root);h.clock=int(time.time());h.controller.clock=time.time;h.payload['generatedEpoch']=h.clock
    from test_similar_movies import MetadataFixture
    from similar_movies import CinemetaSimilar
    from metadata_discovery import CinemetaDiscovery
    metadata=MetadataFixture()
    def lookup(path):
        if '/search=Holid' in path:
            return {'metas':[dict(metadata.seed,id='tt80000'+str(i).zfill(2),name='Holiday Touchdown '+str(i)) for i in range(18)] +
                    [dict(metadata.seed,id='tt2556308',name='Holiday',releaseInfo='2014'),
                     dict(metadata.seed,id='tt0030241',name='Holiday',releaseInfo='1938')]}
        if path=='/meta/movie/tt2556308.json':
            return {'meta':dict(metadata.seed,id='tt2556308',name='Holiday',releaseInfo='2014',cast=['Akshay Kumar','Sonakshi Sinha','Freddy Daruwala'],director=['A.R. Murugadoss'],runtime='170 min',imdbRating='7.2',genres=['Action','Crime','Thriller'],description='A military officer hunts sleeper cells while home on leave.')}
        if path=='/meta/movie/tt0030241.json':
            return {'meta':dict(metadata.seed,id='tt0030241',name='Holiday',releaseInfo='1938',cast=['Cary Grant','Katharine Hepburn'],director=['George Cukor'],runtime='95 min',genres=['Comedy','Romance'],description='A young man must choose between a wealthy family and his own plans.')}
        for query,imdb,name in [('SlowDetails','tt8000099','Slow details movie'),('LatestDetails','tt8000098','Latest details movie'),('FailDetails','tt8000097','Failed details movie'),('LiteralDetails','tt8000096','Literal details movie'),('SparseDetails','tt8000095','Sparse details movie')]:
            if '/search='+query in path:return {'metas':[dict(metadata.seed,id=imdb,name=name)]}
            if path=='/meta/movie/'+imdb+'.json':
                if query=='SlowDetails':time.sleep(1.4)
                data=dict(metadata.seed,id=imdb,name=name,cast=['Current Actor' if query=='LatestDetails' else 'Old Actor'])
                if query=='LiteralDetails':data.update(cast=['<img src=x onerror=alert(1)>'],description='<script>alert(1)</script>')
                if query=='SparseDetails':data={k:data[k] for k in ('id','name','type','releaseInfo')}
                return {'meta':data}
        if path.startswith('/meta/movie/tt80000'):
            imdb=path.rsplit('/',1)[-1].removesuffix('.json')
            return {'meta':dict(metadata.seed,id=imdb,cast=['Catalog Actor'])}
        if '/search=Slow' in path:
            time.sleep(1.2)
            return {'metas':[dict(metadata.seed,name='Slow result')]}
        if '/search=Latest' in path:return {'metas':[dict(metadata.seed,name='Latest result')]}
        if '/search=Literal' in path:return {'metas':[dict(metadata.seed,name='Literal <img src=x onerror=alert(1)>')]}
        return metadata(path)
    h.controller.similar.source=CinemetaSimilar(CinemetaDiscovery(lookup))
    h.controller.finalize('billing-owner',['tt12345','tt12346','tt12347'])
    h.controller.enable_auto_downloads()
    endpoint=backend_root/'review.sock';backend_origin='https://backend.example.test:8447'
    front=MovieNightServer('http://localhost',backend_origin,'owner@example.test',0,str(endpoint))
    origin='http://localhost:'+str(front.server_port);front.public_origin=origin;front.host='localhost:'+str(front.server_port)
    app=create_app(h.controller,lambda r:'billing-owner' if r.headers.get('x-afz-review-principal')=='billing-owner' else None,allowed_origin=backend_origin)
    server=uvicorn.Server(uvicorn.Config(app,uds=str(endpoint),access_log=False,log_level='error',lifespan='off'))
    backend=threading.Thread(target=server.run,daemon=True);backend.start()
    for _ in range(100):
        if endpoint.exists():break
        time.sleep(.03)
    else:raise AssertionError('Fixture backend did not start')
    endpoint.chmod(0o600)
    thread=threading.Thread(target=front.serve_forever,daemon=True);thread.start()
    with sqlite3.connect(h.db) as db:before='\n'.join(db.iterdump())
    out=BASE/os.environ.get('AFZ_POPUP_QA_FOLDER','qa/title-popup');out.mkdir(parents=True,exist_ok=True)
    try:
        env=dict(os.environ,AFZ_GATEWAY_QA_ORIGIN=origin,AFZ_GATEWAY_QA_OUTPUT=str(out))
        result=subprocess.run([os.environ.get('AFZ_NODE','/home/coolyo/.local/bin/node'),str(BASE/'tests'/os.environ.get('AFZ_POPUP_QA_SCRIPT','title_popup_browser.cjs'))],capture_output=True,text=True,env=env,timeout=180)
        (out/'browser.log').write_text(result.stdout+result.stderr)
        assert result.returncode==0,(result.stdout+result.stderr)[-3500:]
        with sqlite3.connect(h.db) as db:assert before=='\n'.join(db.iterdump()),'Settings changed existing database content'
        assert h.provider.resolves==0 and h.provider.verifies==0
        assert not list(h.media.rglob('*.mkv'))
        added=h.controller.similar.store.read()
        assert len(added)==0
        (out/'server-result.json').write_text(json.dumps({'added':len(added),'databasesUnchanged':True,'mediaStarted':False},indent=2))
        files=[p for folder in ('src','gateway','tests') for p in (BASE/folder).iterdir() if p.is_file() and p.suffix in ('.py','.js','.css','.html','.cjs')]
        (out/'tested-source.json').write_text(json.dumps({str(p.relative_to(BASE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
        print('TITLE_POPUP_REAL_API_BROWSER_PASS_360_412_1280_NO_WRITES')
    finally:
        front.shutdown();front.server_close();server.should_exit=True;backend.join(10);h.close()
