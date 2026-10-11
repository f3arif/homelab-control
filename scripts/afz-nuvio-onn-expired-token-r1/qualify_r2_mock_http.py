import os, sys, json, time, hashlib, pathlib, subprocess, threading, socket, tempfile, urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import requests

stage=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
source=stage/"stremio_catalog.r2.candidate.py"
production=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py")
python=r"C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe"
want_live="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
want_r2="3dab113e23725a39401f8ba3c619b9eb0b6cd5eec47a0f677df2dc84404a74a5"
vid="tt22084616"
old_token="a"*28
new_token="b"*28
wrong_token="c"*28
expired_token="d"*28
unknown_token="f"*28
bridge_port=18787
sidecar_port=18786
bridge_base="http://127.0.0.1:"+str(bridge_port)
sidecar_base="http://127.0.0.1:"+str(sidecar_port)
fixture={
    "token":new_token,"provider":"TorBox","source":"Debridio",
    "resolution":1080,"size":4*1024**3,
    "filename":"Spider-Man.Brand.New.Day.2026.1080p.H264.mkv",
    "name":"AFZ TorBox","title":"2026 Spider-Man 1080p H264"
}
record={"utc":datetime.now(timezone.utc).isoformat(),
        "mode":"LOCAL_ONLY_HTTP_MOCK_PLUS_REAL_BRIDGE_INTEGRATION_SEPARATE",
        "candidate_sha":want_r2,"tests":[],"status":"STARTED",
        "production_changed":False,"mock_bridge_stopped":False,"sidecar_stopped":False,
        "provider_url_or_secret_logged":False}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def check(label,passed,**rest):
    record["tests"].append({"name":label,"pass":bool(passed),**rest})
    print(("PASS " if passed else "FAIL ")+label,flush=True)
    if not passed:raise RuntimeError(label)
def available(port):
    with socket.socket() as s:
        s.settimeout(0.35)
        return s.connect_ex(("127.0.0.1",port))!=0
def mockrow():
    return dict(fixture)
class Bridge(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        u=urllib.parse.urlsplit(self.path)
        q=urllib.parse.parse_qs(u.query)
        code=200
        if u.path=="/external-streams" and q.get("imdb",[""])[0]==vid:
            body={"ok":True,"sourceCount":1,"streams":[mockrow()]}
        elif u.path=="/external-resolve" and q.get("imdb",[""])[0]==vid and q.get("token",[""])[0]==new_token:
            body={"ok":True,"url":"https://example.invalid/sidecar-test-only-media.mp4"}
        else:
            code=404
            body={"ok":False,"error":"Expired or nonexistent test token"}
        payload=json.dumps(body,separators=(",",":")).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
def start_sidecar(home):
    env=os.environ.copy()
    env.update({
        "AFZ_STATE_FILE":str(home/"state"/"state.json"),
        "AFZ_STREMIO_FAILOVER_MODE":"1",
        "STREMIO_CONTROL_BRIDGE_URL":bridge_base,
        "STREMIO_PUBLIC_BASE_URL":sidecar_base,
        "AFZ_BROWSER_PUBLIC_BASE":sidecar_base,
        "STREMIO_MEDIA_ROOT":str(home/"no-media"),
        "STREMIO_MEDIA_STORAGE_ROOT":str(home/"no-media"/"Movies"),
        "STREMIO_TV_ROOT":str(home/"no-media"/"TV"),
        "STREMIO_TV_STORAGE_ROOT":str(home/"no-media"/"TV"),
        "STREMIO_JELLYFIN_ROOT":str(home/"no-media"),
        "SEERR_URL":"http://127.0.0.1:9/api/v1",
        "RADARR_URL":"http://127.0.0.1:9/api/v3",
        "SONARR_URL":"http://127.0.0.1:9/api/v3",
        "SEERR_API_KEY":"","RADARR_API_KEY":"",
        "JELLYFIN_URL":"http://127.0.0.1:9",
        "JELLYFIN_DB":str(home/"no-media"/"missing.db"),
        "JELLYSEERR_SETTINGS":str(home/"no-media"/"missing.json"),
        "RDT_TORBOX_DB":str(home/"no-media"/"missing-rdt.db"),
        "RDT_RD_DB":str(home/"no-media"/"missing-rd.db"),
        "NTFY_URL":"http://127.0.0.1:9"
    })
    logfile=open(home/"sidecar.log","ab")
    flags=subprocess.CREATE_NO_WINDOW|subprocess.CREATE_NEW_PROCESS_GROUP if os.name=="nt" else 0
    p=subprocess.Popen(
       [python,"-m","uvicorn","sidecar_app:app","--app-dir",str(home),
        "--host","127.0.0.1","--port",str(sidecar_port),
        "--lifespan","off","--no-access-log","--log-level","error"],
       cwd=str(home),env=env,stdout=logfile,stderr=subprocess.STDOUT,creationflags=flags)
    logfile.close()
    for _ in range(20):
        if p.poll() is not None:raise RuntimeError("Sidecar startup failure")
        try:
            r=requests.get(sidecar_base+"/manifest.json",timeout=1.5)
            if r.status_code==200:return p
        except requests.RequestException: pass
        time.sleep(.5)
    raise RuntimeError("Sidecar not ready")
def stop_sidecar(p):
    if p is None:return
    if p.poll() is None:
        subprocess.run(["taskkill.exe","/T","/F","/PID",str(p.pid)],
                       capture_output=True,text=True,timeout=13)
        try:p.wait(timeout=7)
        except subprocess.TimeoutExpired:pass

server=None
proc=None
home=None
try:
    check("catalog-source-baseline",sha(production)==want_live)
    check("candidate-sha-pinned",sha(source)==want_r2)
    check("fixture-ports-unused",available(bridge_port) and available(sidecar_port))
    home=pathlib.Path(tempfile.mkdtemp(prefix="r2-mock-http-",dir=stage))
    state=home/"state"
    state.mkdir()
    (home/"stremio_catalog.py").write_bytes(source.read_bytes())
    (home/"sidecar_app.py").write_text(
        "import stremio_catalog as impl\n"
        "impl.cache.setdefault('idmap',{})['tt22084616']={'title':'Spider-Man: Brand New Day','year':'2026'}\n"
        "app=impl.app\n",encoding="utf-8"
    )
    now=time.time()
    def history_row(token,filename,ts):
        x={**fixture,"token":token,"filename":filename}
        return {"ts":ts,"row":x}
    bad_name="Entirely.Different.Release.2026.1080p.H264.mkv"
    cache={
        "rows":{vid:[dict(fixture)]},
        "ts":{vid:now},
        "history":{vid:{
            old_token:history_row(old_token,fixture["filename"],now),
            wrong_token:history_row(wrong_token,bad_name,now),
            expired_token:history_row(expired_token,fixture["filename"],now-72*3600-15)
        }}
    }
    (state/"external-source-cache.json").write_text(json.dumps(cache),encoding="utf-8")
    server=ThreadingHTTPServer(("127.0.0.1",bridge_port),Bridge)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    proc=start_sidecar(home)
    manifest=requests.get(sidecar_base+"/manifest.json",timeout=4)
    check("candidate-sidecar-manifest",manifest.status_code==200 and manifest.json().get("version")=="0.6.243")
    miss=requests.get(bridge_base+"/external-resolve",params={"imdb":vid,"token":old_token},timeout=4)
    check("old-token-not-on-bridge",miss.status_code==404)
    response=requests.head(sidecar_base+f"/external-stream/{vid}/{old_token}",allow_redirects=False,timeout=16)
    check("historical-only-token-recovers-over-http",response.status_code==307,http_status=response.status_code)
    preserved=json.loads((state/"external-source-cache.json").read_text(encoding="utf-8"))
    check("history-persisted-by-http-refresh",
          old_token in (preserved.get("history")or{}).get(vid,{}) and
          old_token not in {x.get("token") for x in (preserved.get("rows")or{}).get(vid,[])})
    wrong=requests.head(sidecar_base+f"/external-stream/{vid}/{wrong_token}",allow_redirects=False,timeout=8)
    check("different-release-rejected",wrong.status_code==404,http_status=wrong.status_code)
    old=requests.head(sidecar_base+f"/external-stream/{vid}/{expired_token}",allow_redirects=False,timeout=8)
    check("expired-history-rejected",old.status_code==404,http_status=old.status_code)
    unknown=requests.head(sidecar_base+f"/external-stream/{vid}/{unknown_token}",allow_redirects=False,timeout=8)
    check("unknown-token-rejected",unknown.status_code==404,http_status=unknown.status_code)
    stop_sidecar(proc);proc=None
    proc=start_sidecar(home)
    after=requests.head(sidecar_base+f"/external-stream/{vid}/{old_token}",allow_redirects=False,timeout=16)
    check("historical-url-recovers-after-process-restart",after.status_code==307,http_status=after.status_code)
    check("production-source-still-original",sha(production)==want_live)
    prod=requests.get("http://127.0.0.1:18774/manifest.json",timeout=4)
    check("production-manifest-healthy",prod.status_code==200)
    record["status"]="PASS"
except Exception as exc:
    record["status"]="FAIL"
    record["error_type"]=type(exc).__name__
    record["error"]=str(exc)[:160]
finally:
    if proc is not None:stop_sidecar(proc)
    record["sidecar_stopped"]=True
    if server is not None:
        server.shutdown();server.server_close()
    record["mock_bridge_stopped"]=True
    record["completed_utc"]=datetime.now(timezone.utc).isoformat()
    if home is not None:record["test_folder"]=str(home)
    (stage/"r2-mocked-http-acceptance.json").write_text(json.dumps(record,indent=2),encoding="utf-8")
    print("R2_HTTP_MOCK_ACCEPTANCE",record["status"],"CHECKS",len(record["tests"]),flush=True)
sys.exit(0 if record["status"]=="PASS" else 1)
