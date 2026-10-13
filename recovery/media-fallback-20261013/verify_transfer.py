#!/usr/bin/env python3
"""One bounded official Ubuntu transfer; cleans up only its own exact test torrent."""
import datetime,json,os,re,subprocess,sys,time
from pathlib import Path
import requests
ROOT=Path(os.environ["AFZ_FALLBACK_ROOT"])
BASE="http://127.0.0.1:18796"
TAG="afz-connectivity-check-20261013"
SAVE="/downloads/"+TAG
REPORT=ROOT/"bounded-transfer-20261013.json"
URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso.torrent"
NAME="ubuntu-24.04.5-live-server-amd64.iso"
def session():
    c=json.loads((ROOT/"qbit-credentials.json").read_text())
    s=requests.Session();s.headers.update({"Origin":BASE,"Referer":BASE+"/"})
    r=s.post(BASE+"/api/v2/auth/login",data={k:c[k] for k in ["username","password"]},timeout=8)
    r.raise_for_status()
    assert s.get(BASE+"/api/v2/app/version",timeout=8).status_code==200
    return s
def call(s,path,method="get",**kw):
    r=getattr(s,method)(BASE+"/api/v2/"+path,timeout=8,**kw);r.raise_for_status();return r
def owned(s,hsh):
    rows=call(s,"torrents/info",params={"hashes":hsh}).json()
    if not rows:return None
    assert len(rows)==1
    t=rows[0]
    assert t["name"]==NAME and t["category"]==TAG and t["save_path"].rstrip("/")==SAVE
    return t
def cleanup(hsh):
    s=session();t=owned(s,hsh)
    if t:
        call(s,"torrents/stop","post",data={"hashes":hsh})
        call(s,"torrents/delete","post",data={"hashes":hsh,"deleteFiles":"true"})
    assert not owned(s,hsh)
    s.close()
if len(sys.argv)==3 and sys.argv[1]=="--watchdog":
    assert re.fullmatch("[0-9a-f]{40}",sys.argv[2])
    time.sleep(55)
    cleanup(sys.argv[2])
    sys.exit(0)
assert not REPORT.exists(),"Completed test must not be repeated"
s=session()
assert call(s,"torrents/info").json()==[],"Existing queue: no probe"
r=requests.get(URL,timeout=(8,20));r.raise_for_status()
assert 1000<len(r.content)<1048576 and r.content.startswith(b"d")
call(s,"torrents/add","post",files={"torrents":("connectivity.torrent",r.content)},
     data={"savepath":SAVE,"category":TAG,"tags":TAG,"stopped":"true",
           "paused":"true","autoTMM":"false","dlLimit":"65536","upLimit":"1024"})
hsh=None;row=None
for _ in range(10):
    rows=call(s,"torrents/info",params={"category":TAG}).json()
    if rows:break
    time.sleep(.3)
assert len(rows)==1 and re.fullmatch("[0-9a-f]{40}",rows[0]["hash"])
hsh=rows[0]["hash"];row=owned(s,hsh)
watchlog=open(ROOT/"bounded-transfer-watchdog.log","a")
subprocess.Popen([sys.executable,str(Path(__file__).resolve()),"--watchdog",hsh],
                 stdin=subprocess.DEVNULL,stdout=watchlog,stderr=watchlog,start_new_session=True)
start=time.monotonic()
report={"status":"RUNNING","officialTorrent":URL,"maximumSeconds":40,"limitBytesPerSecond":65536,
        "checkedUtc":datetime.datetime.now(datetime.timezone.utc).isoformat(),"cleanup":False}
try:
    assert row["downloaded"]==0
    call(s,"torrents/start","post",data={"hashes":hsh})
    while time.monotonic()-start<40:
        row=owned(s,hsh);assert row
        if row.get("downloaded",0)>=262144:break
        time.sleep(1)
    report.update({"downloadedBytes":row.get("downloaded"),"completedBytes":row.get("completed"),
                   "state":row.get("state"),"connectedSeeds":row.get("num_seeds"),
                   "elapsedSeconds":round(time.monotonic()-start,2),
                   "status":"PASS" if row.get("downloaded",0)>0 else "NO_TRANSFER_OBSERVED"})
finally:
    cleanup(hsh);report["cleanup"]=True
    report["queueAfter"]=len(call(s,"torrents/info").json())
    REPORT.write_text(json.dumps(report,indent=2));os.chmod(REPORT,0o600)
    print(json.dumps(report),flush=True)
    s.close()
