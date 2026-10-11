import json, pathlib, re, requests, time, sys, datetime

stage=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
cache_path=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\state\external-source-cache.json")
bridge="http://127.0.0.1:18768"
catalog="http://127.0.0.1:18774"
result={"created_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "cases":[],"status":"STARTED","read_only_http":True,
        "media_downloaded":False,"provider_urls_logged":False}
def add(name,ok,status=None,**info):
    result["cases"].append({"check":name,"pass":bool(ok),"status":status,**info})
    print("PASS" if ok else "FAIL",name,"status",status,flush=True)
    return ok
def identity(x):
    return (str(x.get("provider")or"").lower(),str(x.get("source")or"").lower(),
            int(x.get("resolution")or 0),int(x.get("size")or 0),
            re.sub("[^a-z0-9]+","",str(x.get("filename") or x.get("title") or x.get("name") or "").lower()))
try:
    m=requests.get(catalog+"/manifest.json",timeout=7)
    obj=m.json() if m.status_code==200 else {}
    if not add("catalog-manifest",m.status_code==200 and obj.get("id")=="com.afzengineering.releasecatalog"
               and obj.get("version")=="0.6.243",m.status_code):
        raise RuntimeError("Manifest baseline failed")

    disk=json.loads(cache_path.read_text(encoding="utf-8"))
    history=disk.get("history") or {}
    # Current service may have refreshed a few titles on startup.
    # Validate that any preexisting archive loads without losing current sources.
    add("cache-json-valid",isinstance(disk.get("rows"),dict) and isinstance(history,dict))

    found=False
    for vid in ("tt6723592","tt32393988","tt22084616"):
        snapshot=[dict(x) for x in (disk.get("rows") or {}).get(vid,[]) if isinstance(x,dict)]
        if not snapshot:continue
        resp=requests.get(bridge+"/external-streams",params={"imdb":vid},timeout=30)
        fresh=(resp.json() or {}).get("streams") or [] if resp.status_code==200 else []
        if not fresh:continue
        matches={identity(x) for x in fresh}
        current_tokens={x.get("token") for x in fresh}
        stale=[]
        for x in snapshot:
            tok=str(x.get("token") or "")
            if not re.fullmatch("[a-f0-9]{20,64}",tok) or tok in current_tokens:
                continue
            if identity(x) not in matches:continue
            r=requests.get(bridge+"/external-resolve",params={"imdb":vid,"token":tok},timeout=5)
            if r.status_code==404:
                stale.append(x)
            if len(stale)==3:break
        if len(stale)<2:continue
        # First stale token causes live refresh and archives existing old metadata.
        for idx,x in enumerate(stale[:2]):
            rr=requests.head(catalog+f"/external-stream/{vid}/{x['token']}",
                             allow_redirects=False,timeout=15)
            if not add("expired-link-"+vid+"-"+str(idx+1),rr.status_code==307,rr.status_code,
                       expected_bounded_same_release=True):
                raise RuntimeError("Expired media link did not recover")
            if idx==0:
                current=json.loads(cache_path.read_text(encoding="utf-8"))
                past=(current.get("history") or {}).get(vid) or {}
                ok=x["token"] in past
                if not add("persisted-history-after-refresh-"+vid,ok):raise RuntimeError("Recovery history not persisted")
                # The second HEAD must have no matching current source row.
                other=stale[1]["token"]
                if other in {row.get("token") for row in (current.get("rows") or {}).get(vid,[])}:
                    raise RuntimeError("Second token still in current rows; historical test not proven")
        found=True
        break
    if not found:
        add("two-real-stale-tokens",False,status="NO_TWO_MATCHING_STALE_SOURCES")
        raise RuntimeError("Could not demonstrate historical-only stale link recovery")
    unknown=requests.head(catalog+"/external-stream/tt6723592/"+("f"*28),
                          allow_redirects=False,timeout=6)
    add("unknown-token-fails-closed",unknown.status_code==404,unknown.status_code)
    if any(not x["pass"] for x in result["cases"]):raise RuntimeError("An acceptance check failed")
    result["status"]="PASS"
except Exception as exc:
    result["status"]="FAIL"
    result["error_type"]=type(exc).__name__
    result["error"]=str(exc)[:145]
(stage/"r2-postdeploy-smoke.json").write_text(json.dumps(result,indent=2),encoding="utf-8")
print("R2_POSTDEPLOY="+result["status"],flush=True)
sys.exit(0 if result["status"]=="PASS" else 1)
