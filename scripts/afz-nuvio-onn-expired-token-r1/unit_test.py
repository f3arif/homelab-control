from pathlib import Path
import ast, json, re, time, threading, types, urllib.parse
stage=Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
s=(stage/"stremio_catalog.candidate.py").read_text(encoding="utf-8")
tree=ast.parse(s)
needed=["_external_candidate_identity","_external_resolved_url"]
fns=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name in needed]
assert len(fns)==2
ns={"re":re,"time":time,"requests":types.SimpleNamespace(utils=types.SimpleNamespace(quote=urllib.parse.quote))}
exec(compile(ast.Module(body=fns,type_ignores=[]),"<isolated backend token tests>","exec"),ns)
class HTTPException(Exception):
    def __init__(self,code,message):
        super().__init__(message);self.status_code=code
ns["HTTPException"]=HTTPException
ns["norm_title"]=lambda s: re.sub(r"[^a-z0-9]+","",str(s).lower())
ns["parse_series_video_id"]=lambda vid:None
ns["external_source_lock"]=threading.RLock()
ns["resolved_stream_lock"]=threading.RLock()
ns["RESOLVED_STREAM_TTL"]=90
ns["FAILOVER_MODE"]=True
old_token="a"*28
new_token="b"*28
unknown_token="f"*28
old={"provider":"TorBox","source":"Debridio","resolution":1080,"size":3221225472,"filename":"Test.Movie.1080p.H264.mkv","token":old_token}
fresh={**old,"token":new_token}
different={**fresh,"filename":"Wrong.Movie.1080p.H264.mkv"}
cases=[]
def testcase(name,cache,discovery,valid,expect_ok,expect_refresh=None,token=old_token,vid="tt1234567",cached_url=None):
    ns["external_source_cache"]={"rows":cache}
    ns["external_resolved_cache"]={}
    if cached_url:
        ns["external_resolved_cache"][vid+"|"+token]={"url":cached_url,"ts":time.time()}
    counts={"resolve":0,"refresh":0}
    def bridge(method,path,timeout):
        counts["resolve"]+=1
        q=urllib.parse.parse_qs(urllib.parse.urlparse("http://mock.local"+path).query)
        t=q.get("token",[""])[0]
        if t in valid and not (name=="same token restored by bridge discovery" and counts["refresh"]==0):return {"ok":True,"url":"https://example.invalid/media/same-release"}
        return {"ok":False,"statusCode":404}
    def refresh(v,force=False):
        counts["refresh"]+=1
        assert v==vid and force is True
        if isinstance(discovery,Exception):raise discovery
        return discovery
    ns["h3_order_call"]=bridge
    ns["external_source_rows"]=refresh
    try:
        result=ns["_external_resolved_url"](vid,token)
        ok=result.startswith("https://")
    except HTTPException as e:
        result=str(e);ok=False
        assert e.status_code==404
    assert ok==expect_ok, (name,result)
    if expect_refresh is not None:assert counts["refresh"]==expect_refresh,(name,counts)
    cases.append({"name":name,"pass":True,"refreshCalls":counts["refresh"],"resolveCalls":counts["resolve"],"status":"success" if ok else "404"})
testcase("valid live token",{"tt1234567":[old]},[],{old_token},True,0)
testcase("expired persisted token refreshes exact release",{"tt1234567":[old]},[fresh],{new_token},True,1)
testcase("same token restored by bridge discovery",{"tt1234567":[old]},[old],{old_token},True,1)
testcase("different movie forbidden even if metadata otherwise similar",{"tt1234567":[old]},[different],{new_token},False,1)
testcase("no available replacement",{"tt1234567":[old]},[],set(),False,1)
testcase("new resolver unavailable",{"tt1234567":[old]},[fresh],set(),False,1)
testcase("unknown original token cannot refresh arbitrary source",{"tt1234567":[old]},[fresh],{new_token},False,0,token=unknown_token)
testcase("old persisted token absent",{"tt1234567":[]},[fresh],{new_token},False,0)
testcase("refresh throws exception safely",{"tt1234567":[old]},RuntimeError("bridge offline"),{new_token},False,1)
testcase("valid 90s cached resolved URL",{"tt1234567":[old]},[],set(),True,0,cached_url="https://example.invalid/media/cached")
testcase("invalid movie id rejected",{"tt1234567":[old]},[],set(),False,0,vid="../bad")
(stage/"unit-regression.json").write_text(json.dumps({"candidate":"expired AFZ external playback token refresh","result":"PASS","tested":len(cases),"cases":cases},indent=2),encoding="utf-8")
print("RESULT=PASS",len(cases),"ISOLATED_REGRESSIONS")
for c in cases:print("PASS",c["name"],"refreshCalls",c["refreshCalls"],"resolverCalls",c["resolveCalls"])
