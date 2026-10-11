import os,sys,json,time,hashlib,pathlib,tempfile,threading,socket,subprocess,urllib.parse
from datetime import datetime,timezone
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import requests

root=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-auto-source-r3-20261011")
candidate=root/"stremio_catalog.auto-r3.candidate.py"
production=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py")
expected_live="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
expected_candidate="2e5b2c55967b31cd8eb149c9291ca12b5246d34ce80bd4cc276f21ea1654f013"
python=r"C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe"
vid="tt22084616";mockport=18789;sideport=18788
mockbase=f"http://127.0.0.1:{mockport}"
sidebase=f"http://127.0.0.1:{sideport}"
gi=1024**3
comet={"token":"b"*28,"provider":"TorBox","source":"Comet","resolution":1080,
       "size":int(3.4*gi),"cached":True,"sizeExact":True,
       "name":"AFZ 1080p Comet","title":"Spider-Man Brand New Day 2026 1080p WEBRip",
       "filename":"Spider-Man.Brand.New.Day.2026.1080p.WEBRip.H264.mkv"}
debridio={"token":"a"*28,"provider":"TorBox","source":"Debridio","resolution":1080,
          "size":int(3.7*gi),"cached":True,"sizeExact":True,
          "name":"AFZ 1080p Debridio","title":"Spider-Man Brand New Day 2026 1080p WEB-DL",
          "filename":"Spider-Man.Brand.New.Day.2026.1080p.WEB-DL.H264.mkv"}
fixture=(debridio,comet)
record={"created_utc":datetime.now(timezone.utc).isoformat(),"status":"STARTED","tests":[],
        "isolation":"private H3 localhost-only mock bridge and sidecar",
        "provider_media_downloaded":False,"production_modified":False,"sidecar_stopped":False,"mock_stopped":False}
def check(name,condition,**details):
    record["tests"].append({"name":name,"pass":bool(condition),**details})
    print(("PASS " if condition else "FAIL ")+name,flush=True)
    if not condition:raise RuntimeError("Assertion failed: "+name)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def free(port):
    with socket.socket() as s:
        s.settimeout(.5);return s.connect_ex(("127.0.0.1",port))!=0
class Resolver(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        url=urllib.parse.urlsplit(self.path)
        q=urllib.parse.parse_qs(url.query)
        code=200
        if url.path=="/external-streams" and q.get("imdb")==[vid]:
            body={"ok":True,"sourceCount":2,"streams":list(fixture)}
        elif url.path=="/external-resolve" and q.get("imdb")==[vid]:
            tok=q.get("token",[""])[0]
            if tok==comet["token"]: body={"ok":True,"url":"https://comet.example.invalid/video.mkv"}
            elif tok==debridio["token"]:body={"ok":True,"url":"https://debridio.example.invalid/video.mkv"}
            else:code=404;body={"ok":False,"error":"Expired selection"}
        elif url.path=="/direct-streams":
            body={"ok":True,"streams":[]}
        else:
            code=404;body={"ok":False,"error":"Unavailable"}
        payload=json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
def launch(home):
    env=os.environ.copy()
    env.update({
        "AFZ_STATE_FILE":str(home/"state"/"state.json"),
        "AFZ_STREMIO_FAILOVER_MODE":"1",
        "STREMIO_CONTROL_BRIDGE_URL":mockbase,
        "STREMIO_PUBLIC_BASE_URL":sidebase,
        "AFZ_BROWSER_PUBLIC_BASE":sidebase,
        "STREMIO_MEDIA_ROOT":str(home/"no-media"),
        "STREMIO_MEDIA_STORAGE_ROOT":str(home/"no-media"/"Movies"),
        "STREMIO_TV_ROOT":str(home/"no-media"/"TV"),
        "STREMIO_TV_STORAGE_ROOT":str(home/"no-media"/"TV"),
        "STREMIO_JELLYFIN_ROOT":str(home/"no-media"),
        "SEERR_URL":"http://127.0.0.1:9/api/v1","SEERR_API_KEY":"",
        "RADARR_URL":"http://127.0.0.1:9/api/v3","RADARR_API_KEY":"",
        "SONARR_URL":"http://127.0.0.1:9/api/v3",
        "JELLYFIN_URL":"http://127.0.0.1:9",
        "JELLYFIN_DB":str(home/"no-media"/"missing.db"),
        "JELLYSEERR_SETTINGS":str(home/"no-media"/"missing.json"),
        "RDT_TORBOX_DB":str(home/"no-media"/"missing-rdt.db"),
        "RDT_RD_DB":str(home/"no-media"/"missing-rd.db"),
        "NTFY_URL":"http://127.0.0.1:9"
    })
    output=open(home/"sidecar.log","ab")
    flags=(subprocess.CREATE_NO_WINDOW|subprocess.CREATE_NEW_PROCESS_GROUP) if os.name=="nt" else 0
    p=subprocess.Popen([python,"-m","uvicorn","sidecar_app:app","--app-dir",str(home),
        "--host","127.0.0.1","--port",str(sideport),"--lifespan","off",
        "--no-access-log","--log-level","error"],
        cwd=str(home),env=env,stdout=output,stderr=subprocess.STDOUT,creationflags=flags)
    output.close()
    for i in range(26):
        if p.poll() is not None:raise RuntimeError("Sidecar exited before manifest ready")
        try:
            r=requests.get(sidebase+"/manifest.json",timeout=1.5)
            if r.status_code==200:return p
        except requests.RequestException:pass
        time.sleep(.5)
    raise RuntimeError("Sidecar did not start")
def stop(p):
    if p is not None and p.poll() is None:
        subprocess.run(["taskkill.exe","/F","/T","/PID",str(p.pid)],
                       capture_output=True,text=True,timeout=12)
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:pass
home=None;server=None;proc=None
try:
    check("source-baseline-unchanged",sha(production)==expected_live)
    check("candidate-SHA-pinned",sha(candidate)==expected_candidate)
    check("local-test-ports-free",free(sideport) and free(mockport))
    home=pathlib.Path(tempfile.mkdtemp(prefix="r3-http-",dir=root))
    state=home/"state";state.mkdir()
    (home/"stremio_catalog.py").write_bytes(candidate.read_bytes())
    wrapper="""
import pathlib,json,urllib.parse
import stremio_catalog as impl
impl.cache.setdefault('idmap',{})['tt22084616']={'title':'Spider-Man: Brand New Day','year':'2026'}
impl._failover_movie_item=lambda vid:{'_afzFailover':True,'imdbId':vid,'title':'Spider-Man: Brand New Day'}
impl._failover_movie_playback_allowed=lambda item:True
def mock_health(url,*args,**kwargs):
    mode=json.loads((pathlib.Path(__file__).parent/'mode.json').read_text(encoding='utf-8'))['mode']
    host=urllib.parse.urlsplit(url).hostname or ''
    return mode=='all_good' or (mode=='fail_comet' and host.startswith('debridio'))
impl._playback_url_healthy=mock_health
app=impl.app
"""
    (home/"sidecar_app.py").write_text(wrapper,encoding="utf-8")
    now=time.time()
    cache={"rows":{vid:[{**debridio,"token":"c"*28}]},"ts":{vid:now-4*3600}}
    (state/"external-source-cache.json").write_text(json.dumps(cache),encoding="utf-8")
    state_providers={"providers":{
      "torbox|comet":{"checks":100,"success":98,"failure":2,"successRate":0.98,
                     "consecutiveFailures":0,"lastLatencyMs":1150,"lastFailureEpoch":now-4000},
      "torbox|debridio":{"checks":100,"success":60,"failure":40,"successRate":0.60,
                        "consecutiveFailures":8,"lastLatencyMs":3500,"lastFailureEpoch":now-1200}
    }}
    (state/"provider-health.json").write_text(json.dumps(state_providers),encoding="utf-8")
    (home/"mode.json").write_text('{"mode":"all_good"}',encoding="utf-8")
    server=ThreadingHTTPServer(("127.0.0.1",mockport),Resolver)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    proc=launch(home)
    r=requests.head(sidebase+f"/auto-stream/{vid}/saver",allow_redirects=False,timeout=25)
    check("stale-saver-auto-chooses-comet",r.status_code==307 and
          (r.headers.get("X-AFZ-Auto-Source")or"").lower()=="comet",
          http_status=r.status_code)
    refreshed=json.loads((state/"external-source-cache.json").read_text(encoding="utf-8"))
    check("stale-source-refresh-over-http",
          any(x.get("source")=="Comet" for x in (refreshed.get("rows")or{}).get(vid,[])))
    r=requests.get(sidebase+f"/auto-stream/{vid}/mobile",allow_redirects=False,timeout=25)
    check("mobile-auto-chooses-comet",r.status_code==307 and
          (r.headers.get("X-AFZ-Auto-Source")or"").lower()=="comet",
          http_status=r.status_code)
    (home/"mode.json").write_text('{"mode":"fail_comet"}',encoding="utf-8")
    r=requests.head(sidebase+f"/auto-stream/{vid}/saver",allow_redirects=False,timeout=25)
    check("failed-comet-auto-falls-back-to-debridio",r.status_code==307 and
          (r.headers.get("X-AFZ-Auto-Source")or"").lower()=="debridio",
          http_status=r.status_code)
    check("fallback-marked-in-http-header",
          (r.headers.get("X-AFZ-Auto-Failover")or"").lower()=="true")
    check("test-does-not-change-live-source",sha(production)==expected_live)
    check("live-manifest-still-healthy",
          requests.get("http://127.0.0.1:18774/manifest.json",timeout=5).status_code==200)
    record["status"]="PASS"
except Exception as exc:
    record["status"]="FAIL"
    record["error_type"]=type(exc).__name__
    record["error"]=str(exc)[:140]
finally:
    stop(proc);record["sidecar_stopped"]=True
    if server is not None:server.shutdown();server.server_close()
    record["mock_stopped"]=True
    record["completed_utc"]=datetime.now(timezone.utc).isoformat()
    if home is not None:record["test_folder"]=str(home)
    (root/"r3-http-acceptance.json").write_text(json.dumps(record,indent=2),encoding="utf-8")
    print("R3_HTTP_RESULT",record["status"],"PASS",sum(x["pass"] for x in record["tests"]),"TOTAL",len(record["tests"]),flush=True)
sys.exit(0 if record["status"]=="PASS" else 1)
