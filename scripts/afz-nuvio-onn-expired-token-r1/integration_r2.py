import ast,pathlib,re,time,threading,json,requests,urllib.parse,hashlib
from datetime import datetime,timezone

stage=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
tree=ast.parse((stage/"stremio_catalog.r2.candidate.py").read_text(encoding="utf-8"))
need={"_external_old_release_row","_external_resolved_url","_external_candidate_identity","_external_token_history_compact_locked","_external_token_history_remember_locked"}
nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in need]
assert {x.name for x in nodes}==need
class HTTPException(Exception):
    def __init__(self,status_code,detail):self.status_code=status_code;super().__init__(detail)
ns={
 "re":re,"time":time,"threading":threading,"requests":requests,"HTTPException":HTTPException,
 "norm_title":lambda s: re.sub("[^a-z0-9]+","",str(s).lower()),
 "parse_series_video_id":lambda v:None,
 "external_source_lock":threading.RLock(),"resolved_stream_lock":threading.RLock(),
 "external_source_cache":{"rows":{},"ts":{},"history":{}},
 "external_resolved_cache":{},"RESOLVED_STREAM_TTL":90,"FAILOVER_MODE":True,
 "EXTERNAL_TOKEN_HISTORY_TTL":72*3600,
 "EXTERNAL_TOKEN_HISTORY_PER_TITLE":140,"EXTERNAL_TOKEN_HISTORY_GLOBAL_LIMIT":8000}
exec(compile(ast.Module(body=nodes,type_ignores=[]),"<r2-integration>","exec"),ns)
bridge="http://127.0.0.1:18768"
def discover(vid,force=False):
    assert force
    r=requests.get(bridge+"/external-streams",params={"imdb":vid},timeout=25)
    r.raise_for_status()
    j=r.json()
    assert j.get("ok")
    return j.get("streams") or []
def resolver(method,path,timeout):
    r=requests.get(bridge+path,timeout=timeout)
    try:obj=r.json()
    except:obj={}
    obj.setdefault("statusCode",r.status_code)
    return obj
ns.update({"external_source_rows":discover,"h3_order_call":resolver})
out=[]
for vid in ("tt6723592","tt22084616"):
    fresh=discover(vid,True)
    valid=[row for row in fresh if str(row.get("token")or"") and int(row.get("resolution")or 0)==1080]
    valid.sort(key=lambda x:abs(int(x.get("size")or 0)-4*1024**3))
    if not valid:raise RuntimeError(f"No 1080p source for {vid}")
    row=valid[0]
    fake_token=(hashlib.sha256((vid+"|synthetic-expired-source-token-R2").encode()).hexdigest()[:28])
    probe=resolver("GET",f"/external-resolve?token={fake_token}&imdb={vid}",8)
    assert probe.get("statusCode")==404 or not probe.get("ok")
    old={**row,"token":fake_token}
    # Source token is ABSENT from current list, but recorded in historical registry.
    ns["external_source_cache"]={"ts":{},"rows":{vid:[dict(r) for r in fresh]},"history":{}}
    ns["external_resolved_cache"]={}
    with ns["external_source_lock"]:
        ns["_external_token_history_remember_locked"](vid,[old],time.time())
    t0=time.monotonic()
    url=ns["_external_resolved_url"](vid,fake_token)
    assert url.startswith("https://") or url.startswith("http://")
    assert fake_token not in [r.get("token") for r in fresh]
    assert ns["_external_old_release_row"](vid,fake_token).get("filename")==row.get("filename")
    entry={"movie":vid,"result":"PASS","case":"historical-only token re-resolved via real live bridge",
           "fresh_source_count":len(fresh),"selection_resolution":row.get("resolution"),
           "provider":row.get("provider"),"source":row.get("source"),
           "recovered_url":True,"seconds":round(time.monotonic()-t0,2),"source_url_exposed":False}
    out.append(entry)
    print("INTEGRATION_PASS",vid,"fresh",len(fresh),"seconds",entry["seconds"],flush=True)
receipt={"result":"PASS","cases":out,"app_or_backend_modified":False,
         "tested_utc":datetime.now(timezone.utc).isoformat()}
(stage/"r2-bridge-integration.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print("R2_LIVE_BRIDGE_INTEGRATION_PASS",len(out),flush=True)
