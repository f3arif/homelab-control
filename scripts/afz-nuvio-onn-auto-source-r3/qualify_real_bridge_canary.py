import os, sys, time, json, hashlib, pathlib, shutil, tempfile, socket, subprocess
from datetime import datetime, timezone
import requests

base=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-r2-r3-combined-20261011")
source=base/"stremio_catalog.r2-plus-r3.candidate.py"
live=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py")
live_state=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\state")
python=r"C:\AFZ\Stremio-Failover-H3\.venv\Scripts\python.exe"
expected_old="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
expected_combined="2b7a5b73392f21b99ee4b2234062b4d75c7118fd6f7fecc0d841f32691ae6572"
port=18786
urlbase=f"http://127.0.0.1:{port}"
bridge="http://127.0.0.1:18768"
titles={"tt22084616":"Spider-Man: Brand New Day","tt6723592":"Tenet"}
summary={"checked_utc":datetime.now(timezone.utc).isoformat(),"status":"STARTED",
         "mode":"H3 real-bridge localhost-only HEAD canary",
         "production_code_changed":False,"full_media_downloaded":False,
         "source_urls_written":False,"cases":[],"sidecar_closed":False}
def sha(x):return hashlib.sha256(x.read_bytes()).hexdigest()
def test(name,ok,**details):
    data={"check":name,"pass":bool(ok),**details}
    summary["cases"].append(data)
    print(("PASS " if ok else "FAIL ")+name+
          (" "+json.dumps({k:v for k,v in details.items() if k!="error"}) if details else ""),flush=True)
    if not ok:raise RuntimeError("Test gate failed: "+name)
def port_free():
    with socket.socket() as sk:
        sk.settimeout(.6)
        return sk.connect_ex(("127.0.0.1",port))!=0
def launch(work):
    env=os.environ.copy()
    media=work/"no-media"
    env.update({
        "AFZ_STATE_FILE":str(work/"state"/"state.json"),
        "AFZ_STREMIO_FAILOVER_MODE":"1",
        "STREMIO_CONTROL_BRIDGE_URL":bridge,
        "STREMIO_PUBLIC_BASE_URL":urlbase,
        "AFZ_BROWSER_PUBLIC_BASE":urlbase,
        "STREMIO_MEDIA_ROOT":str(media),
        "STREMIO_MEDIA_STORAGE_ROOT":str(media/"Movies"),
        "STREMIO_TV_ROOT":str(media/"TV"),
        "STREMIO_TV_STORAGE_ROOT":str(media/"TV"),
        "STREMIO_JELLYFIN_ROOT":str(media),
        "SEERR_URL":"http://127.0.0.1:9/api/v1",
        "SONARR_URL":"http://127.0.0.1:9/api/v3",
        "RADARR_URL":"http://127.0.0.1:9/api/v3",
        "SEERR_API_KEY":"","RADARR_API_KEY":"",
        "JELLYFIN_URL":"http://127.0.0.1:9",
        "JELLYFIN_DB":str(media/"missing.db"),
        "JELLYSEERR_SETTINGS":str(media/"missing.json"),
        "RDT_TORBOX_DB":str(media/"missing-rdt.db"),
        "RDT_RD_DB":str(media/"missing-rd.db"),
        "NTFY_URL":"http://127.0.0.1:9"
    })
    flags=(subprocess.CREATE_NO_WINDOW|subprocess.CREATE_NEW_PROCESS_GROUP) if os.name=="nt" else 0
    log=open(work/"canary-error.log","ab")
    p=subprocess.Popen(
        [python,"-m","uvicorn","sidecar_app:app","--app-dir",str(work),
         "--host","127.0.0.1","--port",str(port),"--lifespan","off",
         "--no-access-log","--log-level","error"],cwd=str(work),env=env,
         stdout=log,stderr=subprocess.STDOUT,creationflags=flags)
    log.close()
    for i in range(25):
        if p.poll() is not None:raise RuntimeError("Sidecar exited")
        try:
            r=requests.get(urlbase+"/manifest.json",timeout=1.5)
            if r.status_code==200:return p
        except requests.RequestException:pass
        time.sleep(.5)
    raise RuntimeError("Sidecar not ready")
p=None;workdir=None
try:
    test("original-production-SHA",sha(live)==expected_old)
    test("combined-staged-SHA",sha(source)==expected_combined)
    test("private-test-port-unused",port_free())
    result=requests.get(bridge+"/health",timeout=4)
    test("real-H3-bridge-healthy",result.ok and result.json().get("ok"))
    with tempfile.TemporaryDirectory(prefix="r2r3-live-bridge-",dir=base) as tmp:
        workdir=pathlib.Path(tmp)
        state=workdir/"state";state.mkdir()
        shutil.copyfile(source,workdir/"stremio_catalog.py")
        # This wrapper isolates only the release-date policy so a real
        # provider HEAD can be tested without changing real user records.
        wrapper=("import stremio_catalog as impl\n"
                 "titles="+repr(titles)+"\n"
                 "for key,title in titles.items():\n"
                 "    impl.cache.setdefault('idmap',{})[key]={'title':title,'year':'2026'}\n"
                 "impl._failover_movie_item=lambda v: {'_afzFailover':True,'imdbId':v,'title':titles[v]} if v in titles else None\n"
                 "impl._failover_movie_playback_allowed=lambda x: True\n"
                 "app=impl.app\n")
        (workdir/"sidecar_app.py").write_text(wrapper,encoding="utf-8")
        original_cache=json.loads((live_state/"external-source-cache.json").read_text(encoding="utf-8"))
        now=time.time()
        snapshot={"rows":{},"ts":{},"history":{}}
        for vid in titles:
            snapshot["rows"][vid]=[dict(row) for row in original_cache.get("rows",{}).get(vid,[])[:80]]
            snapshot["ts"][vid]=now-3600
        (state/"external-source-cache.json").write_text(json.dumps(snapshot),encoding="utf-8")
        if (live_state/"provider-health.json").exists():
            shutil.copyfile(live_state/"provider-health.json",state/"provider-health.json")
        p=launch(workdir)
        test("canary-original-addon-manifest",requests.get(urlbase+"/manifest.json",timeout=4).status_code==200)
        for vid,title in titles.items():
            start=time.monotonic()
            resp=requests.head(urlbase+f"/auto-stream/{vid}/saver",timeout=(3,22),allow_redirects=False)
            sec=round(time.monotonic()-start,2)
            source_name=(resp.headers.get("X-AFZ-Auto-Source")or"unknown")
            provider_name=(resp.headers.get("X-AFZ-Auto-Provider")or"unknown")
            real_result={
                "movie_id":vid,"http_status":resp.status_code,
                "source":source_name,"provider":provider_name,"seconds":sec,
                "redirect_or_relay":resp.status_code in (200,206,307)
            }
            summary["cases"].append({"check":"live-provider-HEAD-"+vid,"pass":real_result["redirect_or_relay"],**real_result})
            print("LIVE_PROVIDER_HEAD",json.dumps(real_result),flush=True)
            fresh=json.loads((state/"external-source-cache.json").read_text(encoding="utf-8"))
            rrows=fresh.get("rows",{}).get(vid,[])
            summary["cases"].append({
                "check":"auto-source-refresh-"+vid,"pass":bool(rrows) and
                abs(float(fresh.get("ts",{}).get(vid)or 0)-now)<180,
                "fresh_row_count":len(rrows),
                "comet_row_count":sum(1 for row in rrows if str(row.get("source")or"").lower()=="comet")
            })
            print("CACHE_REFRESHED",vid,"ROWS",len(rrows),"COMET",
                  sum(1 for row in rrows if str(row.get("source")or"").lower()=="comet"),flush=True)
        test("production-source-still-unchanged",sha(live)==expected_old)
        test("production-manifest-still-200",
             requests.get("http://127.0.0.1:18774/manifest.json",timeout=5).status_code==200)
        summary["status"]="PASS" if all(c["pass"] for c in summary["cases"]) else "PARTIAL"
        if p and p.poll() is None:
            subprocess.run(["taskkill.exe","/T","/F","/PID",str(p.pid)],
                           capture_output=True,text=True,timeout=12)
            p.wait(timeout=6)
            p=None
        summary["sidecar_closed"]=True
except Exception as exc:
    summary["status"]="INCOMPLETE"
    summary["exception_type"]=type(exc).__name__
    summary["exception_hint"]=str(exc)[:150]
finally:
    if p is not None and p.poll() is None:
        subprocess.run(["taskkill.exe","/T","/F","/PID",str(p.pid)],capture_output=True,text=True,timeout=12)
        p=None
    summary["sidecar_closed"]=True
    summary["closed_utc"]=datetime.now(timezone.utc).isoformat()
    (base/"r2r3-real-provider-canary.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
    print("REAL_CANARY_FINAL",summary["status"],"CHECKS",len(summary["cases"]),flush=True)
sys.exit(0 if summary["status"]=="PASS" else 1)
