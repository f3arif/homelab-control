"""Actual owner gateway + backend + worker, with disposable owner and generated video only."""
from pathlib import Path
import sys,os,tempfile,threading,time,json,re,secrets,http.client,urllib.parse,subprocess,socket,stat
BASE=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(BASE/'src'),str(BASE/'tests'),str(BASE/'.test-deps'),str(BASE/'gateway'),'/home/coolyo/afz-billing/src']
from test_downloads import Harness
from owner_auth import credential
from private_store import write
from private_server import PrivateServer
from webapp import create_app
from adapters import ffprobe
import uvicorn
with tempfile.TemporaryDirectory(prefix='afz-download-qa-') as td:
 root=Path(td);root.chmod(0o700);(root/'owner').mkdir(mode=0o700);(root/'backend').mkdir(mode=0o700)
 video=root/'generated.mkv'
 subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=c=black:s=1920x1080:r=1','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-y',str(video)],check=True,timeout=30)
 h=Harness(root/'backend',video.read_bytes());h.worker.probe=ffprobe
 # The fixture remains unfinalized until the browser clicks the real flow.
 h.controller.feedback.db if hasattr(h.controller.feedback,'db') else None
 import sqlite3
 with sqlite3.connect(h.db) as c:c.execute('DELETE FROM movie_finalized')
 password=secrets.token_urlsafe(24);write(root/'owner/owner.json',credential(password))
 endpoint=root/'backend/review.sock'
 front=PrivateServer(root/'owner','http://localhost',port=0,movie_socket=str(endpoint))
 port=front.server_address[1];origin='http://localhost:'+str(port);front.origin=origin;front.host='localhost:'+str(port)
 app=create_app(h.controller,lambda r:'billing-owner' if r.headers.get('x-afz-review-principal')=='billing-owner' else None,allowed_origin=origin)
 server=uvicorn.Server(uvicorn.Config(app,uds=str(endpoint),access_log=False,log_level='error',lifespan='off'))
 backend=threading.Thread(target=server.run,daemon=True);backend.start()
 for _ in range(100):
  if endpoint.exists():break
  time.sleep(.05)
 endpoint.chmod(0o600)
 frontend=threading.Thread(target=front.serve_forever,daemon=True);frontend.start()
 def request(method,path,body=None,headers=None):
  c=http.client.HTTPConnection('localhost',port,timeout=15);c.request(method,path,body=body,headers=headers or {})
  r=c.getresponse();data=r.read();result=(r.status,dict(r.getheaders()),data);c.close();return result
 try:
  assert request('GET','/movie-night/api/downloads')[0]==401
  status,heads,body=request('GET','/login');assert status==200
  nonce=re.search(rb'name="csrf" value="([^"]+)"',body)[1].decode()
  status,heads,_=request('POST','/login',urllib.parse.urlencode({'csrf':nonce,'password':password}),{'Origin':origin,'Content-Type':'application/x-www-form-urlencoded','Cookie':heads['Set-Cookie'].split(';')[0]})
  assert status==303;owner=heads['Set-Cookie'].split(';')[0]
  for path in ['/movie-night','/movie-night/screen.css','/movie-night/screen.js','/movie-night/api/shortlist','/movie-night/api/downloads']:
   assert request('GET',path,headers={'Cookie':owner})[0]==200,path
  for path in ['/movie-night/screen.css?v=test','/movie-night/api/downloads?x=1','/movie-night/api/lookup/invalid','/movie-night/media/tt12345?token=x']:
   assert request('GET',path,headers={'Cookie':owner})[0]==404,path
  assert request('GET','/movie-night/api/downloads',headers={'Cookie':owner,'Host':'wrong.invalid'})[0]==403
  assert request('POST','/movie-night/api/propose','{"imdb":"tt12345"}',{'Cookie':owner,'Origin':'https://bad.invalid','Content-Type':'application/json'})[0]==403
  assert request('POST','/movie-night/api/propose','{"imdb":"tt12345"}',{'Cookie':owner,'Origin':origin,'Content-Type':'application/json'})[0]==403
  out=BASE/'qa';out.mkdir(exist_ok=True)
  env=dict(os.environ,AFZ_GATEWAY_QA_ORIGIN=origin,AFZ_GATEWAY_QA_COOKIE=owner.split('=',1)[1],AFZ_GATEWAY_QA_OUTPUT=str(out))
  result=subprocess.run(['/home/coolyo/.local/bin/node',str(BASE/'tests/gateway_browser.cjs')],capture_output=True,text=True,env=env,timeout=130)
  (out/'browser.log').write_text(result.stdout+result.stderr)
  assert result.returncode==0,(result.stdout+result.stderr)[-2500:]
  assert h.provider.resolves==1,h.provider.resolves
  import hashlib
  (out/'tested-source.json').write_text(json.dumps({str(p.relative_to(BASE)):hashlib.sha256(p.read_bytes()).hexdigest() for d in ['src','gateway'] for p in (BASE/d).iterdir() if p.is_file() and p.suffix in ('.py','.js','.css','.html')},indent=2))
  print('AUTH_HOST_ORIGIN_CSRF_EXACT_ROUTES_AND_FIXTURE_TRANSFER_PASS')
 finally:
  front.shutdown();front.server_close();server.should_exit=True;backend.join(10);h.close()
