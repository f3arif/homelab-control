#!/usr/bin/env python3
"""Secure the *new* isolated qBittorrent instance, no torrents added."""
import json,os,pathlib,re,secrets,subprocess,sys,time
import requests
root=pathlib.Path(os.environ["AFZ_FALLBACK_ROOT"])
creds=root/"qbit-credentials.json"
report=root/"qbit-security-receipt.json"
base="http://127.0.0.1:18796"
def req(s,path,method="get",**kw):
    headers={"Origin":base,"Referer":base+"/"}
    headers.update(kw.pop("headers",{}))
    return getattr(s,method)(base+path,headers=headers,timeout=(3,8),**kw)
def login(username,password):
    s=requests.Session()
    r=req(s,"/api/v2/auth/login","post",data={"username":username,"password":password})
    return s,r
if creds.exists():
    os.chmod(creds,0o600)
    prev=json.loads(creds.read_text())
    s,r=login(prev["username"],prev["password"])
    if not ((r.status_code==200 and r.text.strip()=="Ok.") or (r.status_code==204 and bool(s.cookies.get("QBT_SID_18796") or s.cookies.get("SID")))):
        raise SystemExit("EXISTING_LOCAL_CREDENTIAL_FILE_LOGIN_FAILED")
    v=req(s,"/api/v2/app/version")
    print("ALREADY_SECURED",v.status_code, v.text.strip()[:40],flush=True)
    raise SystemExit(0)
logs=subprocess.run(["docker","logs","--tail","240","afz-media-qbit-fallback-r1"],
                    capture_output=True,text=True,timeout=15)
if logs.returncode:raise SystemExit("NEW_INSTANCE_LOG_UNAVAILABLE")
m=re.search("temporary password is provided for this session:\\s*([^\\s]+)",
            logs.stdout+"\n"+logs.stderr,re.I)
if not m:raise SystemExit("NEW_INSTANCE_TEMPORARY_PASSWORD_NOT_FOUND")
s,r=login("admin",m.group(1))
if not ((r.status_code==200 and r.text.strip()=="Ok.") or (r.status_code==204 and bool(s.cookies.get("QBT_SID_18796") or s.cookies.get("SID")))):
    print("TEMP_LOGIN_HTTP",r.status_code,flush=True)
    raise SystemExit("TEMP_LOCAL_LOGIN_REJECTED")
existing=req(s,"/api/v2/torrents/info")
if existing.status_code!=200 or existing.json()!=[]:
    raise SystemExit("NEW_INSTANCE_NOT_EMPTY_OR_UNHEALTHY")
name="afzqbit"
password=secrets.token_urlsafe(32)
data={"username":name,"password":password,
      "createdUtc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),
      "scope":"isolated Envy qBittorrent; no existing user configuration changed"}
fd=os.open(str(creds),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,"w") as f:
    json.dump(data,f,indent=2);f.flush();os.fsync(f.fileno())
os.chmod(creds,0o600)
prefs={
  "web_ui_username":name,"web_ui_password":password,
  "save_path":"/downloads",
  "temp_path_enabled":False,
  "bypass_local_auth":False,
  "bypass_auth_subnet_whitelist_enabled":False,
  "web_ui_upnp":False,
  "web_ui_host_header_validation_enabled":True,
  "web_ui_domain_list":"localhost;127.0.0.1;qbittorrent"
}
res=req(s,"/api/v2/app/setPreferences","post",data={"json":json.dumps(prefs)})
print("SECURITY_UPDATE_HTTP",res.status_code,flush=True)
if res.status_code not in (200,204):raise SystemExit("SET_PREFERENCES_FAILED_CREDENTIALS_LOCAL")
time.sleep(.9)
s2,auth=login(name,password)
if not ((auth.status_code==200 and auth.text.strip()=="Ok.") or (auth.status_code==204 and bool(s2.cookies.get("QBT_SID_18796") or s2.cookies.get("SID")))):
    print("NEW_LOCAL_LOGIN_HTTP",auth.status_code,flush=True)
    raise SystemExit("NEW_PASSWORD_NOT_VERIFIED")
v=req(s2,"/api/v2/app/version")
t=req(s2,"/api/v2/torrents/info")
if v.status_code!=200 or t.status_code!=200 or t.json()!=[]:
    raise SystemExit("NEW_SESSION_HEALTH_CHECK_FAILED")
options=req(s2,"/api/v2/app/preferences")
j=options.json() if options.ok else {}
out={"status":"SECURE_LOCAL_QBIT_READY",
     "version":v.text.strip(),"checkedUtc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),
     "localhostPort":18796,"torrentCount":0,
     "credentialsMode":"0600","downloadDir":j.get("save_path"),
     "hostHeaderValidation":j.get("web_ui_host_header_validation_enabled"),
     "noDownloadsAdded":True}
report.write_text(json.dumps(out,indent=2))
print("QBIT_SECURITY_PASS",json.dumps(out),flush=True)