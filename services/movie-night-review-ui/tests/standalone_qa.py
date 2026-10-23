"""Disposable full UI/worker verification through the separate identity gateway."""
from pathlib import Path
import sys, os, tempfile, threading, time, json, subprocess, sqlite3, hashlib
BASE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BASE/'src'),str(BASE/'tests'),str(BASE/'.test-deps'),str(BASE/'gateway')]
from test_downloads import Harness
from standalone_server import MovieNightServer
from webapp import create_app
from adapters import ffprobe
import uvicorn

with tempfile.TemporaryDirectory(prefix='afz-access-qa-') as td:
    root=Path(td); root.chmod(0o700); (root/'backend').mkdir(mode=0o700)
    video=root/'generated.mkv'
    subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=black:s=1920x1080:r=1','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-y',str(video)],check=True,timeout=30)
    h=Harness(root/'backend',video.read_bytes()); h.worker.probe=ffprobe
    with sqlite3.connect(h.db) as c: c.execute('DELETE FROM movie_finalized')
    template=h.payload['movies'][0]
    h.payload['movies'].extend(dict(template,id='tt'+str(12348+i),name='Fixture Extra '+str(i+1)) for i in range(8))
    endpoint=root/'backend/review.sock'
    backend_origin='https://backend.example.test:8447'
    front=MovieNightServer('http://localhost',backend_origin,'owner@example.test',0,str(endpoint))
    port=front.server_port; origin='http://localhost:'+str(port)
    front.public_origin=origin; front.host='localhost:'+str(port)
    app=create_app(h.controller,lambda r:'billing-owner' if r.headers.get('x-afz-review-principal')=='billing-owner' else None,allowed_origin=backend_origin)
    server=uvicorn.Server(uvicorn.Config(app,uds=str(endpoint),access_log=False,log_level='error',lifespan='off'))
    backend=threading.Thread(target=server.run,daemon=True); backend.start()
    for _ in range(100):
        if endpoint.exists(): break
        time.sleep(.05)
    endpoint.chmod(0o600)
    frontend=threading.Thread(target=front.serve_forever,daemon=True); frontend.start()
    try:
        out=BASE/'qa/access'; out.mkdir(parents=True,exist_ok=True)
        # Reuse the full Pick -> Finalize -> exact-file confirmation -> transfer ->
        # Range retrieval/reload browser flow, changing only its auth fixture.
        browser=(BASE/'tests/gateway_browser.cjs').read_text()
        cookie="await p.setCookie({name:'afz_owner',value:process.env.AFZ_GATEWAY_QA_COOKIE,url:origin,httpOnly:true,sameSite:'Strict'});"
        assert cookie in browser
        browser=browser.replace(cookie,"await p.setExtraHTTPHeaders({'Tailscale-User-Login':'owner@example.test'});")
        script=out/'identity_browser.cjs'; script.write_text(browser)
        env=dict(os.environ,AFZ_GATEWAY_QA_ORIGIN=origin,AFZ_GATEWAY_QA_OUTPUT=str(out))
        result=subprocess.run(['/home/coolyo/.local/bin/node',str(script)],capture_output=True,text=True,env=env,timeout=130)
        (out/'browser.log').write_text(result.stdout+result.stderr)
        assert result.returncode==0,(result.stdout+result.stderr)[-2500:]
        assert h.provider.resolves==1
        (out/'tested-source.json').write_text(json.dumps({name:hashlib.sha256((BASE/name).read_bytes()).hexdigest() for name in ['gateway/standalone_server.py','gateway/movie_gateway.py','src/feedback.py','src/webapp.py','src/screen.html','src/screen.js']},indent=2))
        print('STANDALONE_IDENTITY_FULL_UI_TRANSFER_PASS_360_412_1280')
    finally:
        front.shutdown(); front.server_close(); server.should_exit=True; backend.join(10); h.close()
