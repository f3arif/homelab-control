import ast, pathlib, re, time, threading, types, urllib.parse, json, tempfile, hashlib, os
from datetime import datetime,timezone

stage=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
code=(stage/"stremio_catalog.r2.candidate.py").read_text(encoding="utf-8")
module=ast.parse(code)
required={"_external_token_history_compact_locked","_external_token_history_remember_locked","_external_old_release_row",
          "_external_candidate_identity","_external_resolved_url","_persist_external_source_cache"}
nodes=[n for n in module.body if isinstance(n,ast.FunctionDef) and n.name in required]
assert {n.name for n in nodes}==required
class HTTPException(Exception):
    def __init__(self,status_code,detail):
        self.status_code=status_code
        super().__init__(detail)
ns={
    "re":re,"time":time,"threading":threading,"json":json,
    "requests":types.SimpleNamespace(utils=types.SimpleNamespace(quote=urllib.parse.quote)),
    "norm_title":lambda s: re.sub("[^a-z0-9]+","",str(s).lower()),
    "parse_series_video_id":lambda v:None,
    "HTTPException":HTTPException,
    "external_source_lock":threading.RLock(),
    "external_source_persist_lock":threading.RLock(),
    "resolved_stream_lock":threading.RLock(),
    "external_resolved_cache":{},
    "EXTERNAL_TOKEN_HISTORY_TTL":72*3600,
    "EXTERNAL_TOKEN_HISTORY_PER_TITLE":140,
    "EXTERNAL_TOKEN_HISTORY_GLOBAL_LIMIT":8000,
    "RESOLVED_STREAM_TTL":90,
    "FAILOVER_MODE":True,
    "external_source_cache":{"ts":{},"rows":{},"history":{}},
}
exec(compile(ast.Module(body=nodes,type_ignores=[]),"<R2-isolated>","exec"),ns)
VID="tt22084616"
OLD="a"*28
NEW="b"*28
BAD="f"*28
RELEASE={"token":OLD,"provider":"TorBox","source":"Comet","resolution":1080,"size":4*1024**3,
        "filename":"Spider-Man.Brand.New.Day.2026.1080p.mkv","title":"Spider Man 1080p","name":"AFZ TV"}
CHANGED={**RELEASE,"token":NEW}
tested=[]

def assert_true(name,condition):
    if not condition:raise AssertionError(name)
    tested.append(name)
    print("PASS",name,flush=True)

def cache(rows=None,hist=None):
    ns["external_source_cache"]={"ts":{},"rows":{VID:list(rows or [])},"history":hist or {}}
    ns["external_resolved_cache"]={}

def bridge(valid_tokens,force_old=False):
    stats={"resolves":0,"refreshes":0}
    def mock(method,path,timeout):
        stats["resolves"]+=1
        q=urllib.parse.parse_qs(urllib.parse.urlsplit("http://mock.local"+path).query)
        token=q.get("token",[""])[0]
        if token in valid_tokens and not(force_old and token==OLD and stats["refreshes"]==0):
            return {"ok":True,"url":"https://example.invalid/selected-movie"}
        return {"ok":False,"statusCode":404}
    ns["h3_order_call"]=mock
    return stats

def discovery(rows,stats):
    def refresh(vid,force=False):
        assert vid==VID and force
        stats["refreshes"]+=1
        # Mirror actual successful background refresh; archive outgoing rows
        with ns["external_source_lock"]:
            prev=ns["external_source_cache"]["rows"].get(vid,[])
            ns["_external_token_history_remember_locked"](vid,prev,time.time())
            ns["external_source_cache"]["rows"][vid]=[dict(x) for x in rows]
        return [dict(x) for x in rows]
    ns["external_source_rows"]=refresh

def resolves(token=OLD,vid=VID):
    try:
        return ns["_external_resolved_url"](vid,token)
    except HTTPException as exc:
        assert exc.status_code==404
        return ""

cache([RELEASE])
s=bridge({OLD});discovery([],s)
assert_true("currently-valid-token-direct",bool(resolves()) and s["refreshes"]==0)

cache([RELEASE]);s=bridge({NEW});discovery([CHANGED],s)
assert_true("current-cache-token-refresh-exact-release",bool(resolves()) and s["refreshes"]==1)

cache([RELEASE])
with ns["external_source_lock"]:ns["_external_token_history_remember_locked"](VID,[RELEASE],time.time())
oldhist=ns["external_source_cache"]["history"]
cache([CHANGED],oldhist)
s=bridge({NEW});discovery([CHANGED],s)
assert_true("lost-current-row-recovers-from-history",bool(resolves()) and s["refreshes"]==1)

# Validate persistence before/after runtime restart with nothing except release metadata.
with tempfile.TemporaryDirectory() as temp:
    ns["EXTERNAL_SOURCE_CACHE_FILE"]=pathlib.Path(temp)/"external-source-cache.json"
    ns["_persist_external_source_cache"]()
    filedata=json.loads(ns["EXTERNAL_SOURCE_CACHE_FILE"].read_text(encoding="utf-8"))
    assert_true("history-persisted-with-existing-cache-schema",
                bool(filedata.get("history",{}).get(VID,{}).get(OLD)) and bool(filedata.get("rows",{}).get(VID)))
    assert_true("no-signed-provider-url-in-history",
                "https://" not in json.dumps(filedata["history"]) and "http://" not in json.dumps(filedata["history"]))
    # Restart simulation: object parsed from disk and validates the original token
    cache(filedata["rows"][VID],filedata["history"])
    s=bridge({NEW});discovery([CHANGED],s)
    assert_true("history-survives-restart",bool(resolves()))

def fails_for(changed_old,desc):
    cache([RELEASE])
    with ns["external_source_lock"]:ns["_external_token_history_remember_locked"](VID,[RELEASE],time.time())
    cache([CHANGED],ns["external_source_cache"]["history"])
    s=bridge({NEW})
    discovery([changed_old],s)
    assert_true(desc,not resolves() and s["refreshes"]==1)

fails_for({**CHANGED,"filename":"Wrong.Release.2026.1080p.mkv"},"refuse-different-release")
fails_for({**CHANGED,"size":5*1024**3},"refuse-different-size")
fails_for({**CHANGED,"provider":"RealDebrid"},"refuse-different-provider")
fails_for({**CHANGED,"source":"Torrentio"},"refuse-different-source")
fails_for({**CHANGED,"resolution":2160},"refuse-different-resolution")

cache([CHANGED],oldhist)
s=bridge({NEW});discovery([CHANGED],s)
assert_true("refuse-unknown-token",not resolves(BAD) and s["refreshes"]==0)
assert_true("refuse-invalid-video-id",not resolves(OLD,"../wrong") and s["refreshes"]==0)

expired={VID:{OLD:{"ts":time.time()-72*3600-2,"row":dict(RELEASE)}}}
cache([CHANGED],expired)
s=bridge({NEW});discovery([CHANGED],s)
assert_true("refuse-history-past-72h",not resolves() and s["refreshes"]==0)

cache([CHANGED],{VID:{OLD:{"ts":time.time(),"row":{**RELEASE,"token":BAD}}}})
assert_true("refuse-history-token-mismatch",ns["_external_old_release_row"](VID,OLD) is None)

cache([CHANGED])
malicious={**RELEASE,"filename":"https://exfil.invalid/key?a=1"}
with ns["external_source_lock"]:ns["_external_token_history_remember_locked"](VID,[malicious],time.time())
assert_true("refuse-urls-in-historical-metadata",not ns["external_source_cache"]["history"].get(VID))

cache([CHANGED])
many=[{**RELEASE,"token":f"{i:028x}"} for i in range(215)]
with ns["external_source_lock"]:ns["_external_token_history_remember_locked"](VID,many,time.time())
assert_true("history-bound-per-title",len(ns["external_source_cache"]["history"][VID])==140)

# Global upper bound and TTL pruning.
cache([CHANGED])
now=time.time()
with ns["external_source_lock"]:
    for j in range(65):
        vid=f"tt{1000000+j}"
        ns["_external_token_history_remember_locked"](vid,[{**RELEASE,"token":f"{j*200+i:028x}"} for i in range(140)],now)
    total=sum(len(v) for v in ns["external_source_cache"]["history"].values())
assert_true("history-global-cap-8000",total<=8000)

# If fresh discovery is unreachable, no cross-source substitution.
cache([RELEASE])
with ns["external_source_lock"]:ns["_external_token_history_remember_locked"](VID,[RELEASE],time.time())
cache([CHANGED],ns["external_source_cache"]["history"])
s=bridge(set())
ns["external_source_rows"]=lambda *a,**kw: (_ for _ in ()).throw(ConnectionError("Provider unavailable"))
assert_true("fail-closed-on-provider-outage",not resolves())


with tempfile.TemporaryDirectory() as temp:
    ns["EXTERNAL_SOURCE_CACHE_FILE"]=pathlib.Path(temp)/"external-source-cache.json"
    cache([CHANGED])
    with ns["external_source_lock"]:
        ns["_external_token_history_remember_locked"](VID,[RELEASE],time.time())
    threads=[threading.Thread(target=ns["_persist_external_source_cache"]) for _ in range(16)]
    for th in threads:th.start()
    for th in threads:th.join(timeout=12)
    assert_true("concurrent-history-save-threads-completed",not any(th.is_alive() for th in threads))
    j=json.loads(ns["EXTERNAL_SOURCE_CACHE_FILE"].read_text(encoding="utf-8"))
    assert_true("concurrent-history-save-valid-json-and-content",
                OLD in j.get("history",{}).get(VID,{}) and len(j.get("rows",{}).get(VID,[]))==1)
    assert_true("no-racy-shared-temp-file-after-persistence",
                not list(pathlib.Path(temp).glob("*.tmp")))

assert_true("live-H3-backend-file-unchanged",
            hashlib.sha256(pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py").read_bytes()).hexdigest()
            =="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f")
receipt={"result":"PASS","test_count":len(tested),"tests":tested,
         "created_utc":datetime.now(timezone.utc).isoformat(),"live_backend_changed":False}
(stage/"r2-regression.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print("ALL_R2_REGRESSIONS_PASSED",len(tested))
