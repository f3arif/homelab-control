"""Real HTTP owner gateway + server persistence; disposable movie metadata only."""
from pathlib import Path
import hashlib,json,os,sqlite3,subprocess,sys,tempfile,threading,time
BASE=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(BASE/'src'),str(BASE/'tests'),str(BASE/'gateway')]
from test_downloads import Harness
from webapp import create_app
from standalone_server import MovieNightServer
import uvicorn

with tempfile.TemporaryDirectory(prefix='afz-genres-qa-') as td:
    root=Path(td);root.chmod(0o700);backend_root=root/'backend';backend_root.mkdir(mode=0o700)
    h=Harness(backend_root);h.clock=int(time.time());h.payload['generatedEpoch']=h.clock
    template=h.payload['movies'][0]
    for i,genre in enumerate(['Animation','Drama','Horror','Romance']):
        h.payload['movies'].append(dict(template,id='tt'+str(12348+i),name='Fixture '+genre,genres=[genre]))
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
    out=BASE/'qa/genre-settings';out.mkdir(parents=True,exist_ok=True)
    try:
        env=dict(os.environ,AFZ_GATEWAY_QA_ORIGIN=origin,AFZ_GATEWAY_QA_OUTPUT=str(out))
        result=subprocess.run([os.environ.get('AFZ_NODE','/home/coolyo/.local/bin/node'),str(BASE/'tests/genre_settings_browser.cjs')],capture_output=True,text=True,env=env,timeout=180)
        (out/'browser.log').write_text(result.stdout+result.stderr)
        assert result.returncode==0,(result.stdout+result.stderr)[-3500:]
        with sqlite3.connect(h.db) as db:assert before=='\n'.join(db.iterdump()),'Settings changed existing database content'
        assert h.provider.resolves==0 and h.provider.verifies==0
        assert not list(h.media.rglob('*.mkv'))
        final=h.controller.genre_settings.read()
        assert final['revision']>0 and h.controller.genre_settings.path.is_file()
        (out/'server-result.json').write_text(json.dumps({'settings':final,'databasesUnchanged':True,'mediaStarted':False},indent=2))
        files=[p for folder in ('src','gateway','tests') for p in (BASE/folder).iterdir() if p.is_file() and p.suffix in ('.py','.js','.css','.html','.cjs')]
        (out/'tested-source.json').write_text(json.dumps({str(p.relative_to(BASE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
        print('GENRE_SETTINGS_REAL_API_BROWSER_PASS_360_412_1280_NO_MEDIA')
    finally:
        front.shutdown();front.server_close();server.should_exit=True;backend.join(10);h.close()
