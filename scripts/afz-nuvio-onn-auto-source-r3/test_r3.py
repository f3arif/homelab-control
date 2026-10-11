import ast, pathlib, re, time, threading, json, requests, hashlib
from datetime import datetime,timezone
root=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-auto-source-r3-20261011")
baseline=ast.parse((root/"stremio_catalog.original.py").read_text(encoding="utf-8"))
candidate=ast.parse((root/"stremio_catalog.auto-r3.candidate.py").read_text(encoding="utf-8"))
wanted={"_external_release_text","_external_rank","_auto_profile_rank",
        "_quality_size_floor_bytes","_prefer_quality_size",
        "_auto_quick_source_rows","_auto_quick_source_unhealthy","_auto_quick_ranked_candidates",
        "best_profile_source"}
live=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py")
health=json.loads(pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\state\provider-health.json").read_text(encoding="utf-8"))
cached=json.loads(pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\state\external-source-cache.json").read_text(encoding="utf-8"))
modeSpecs={"best":{"resolutions":(2160,1080)},"tv":{"resolutions":(2160,1080)},
           "mobile":{"resolutions":(1080,)},"saver":{"resolutions":(1080,)}}
fixtures={}
for movie in ("tt22084616","tt6723592","tt32393988"):
    req=requests.get("http://127.0.0.1:18768/external-streams",
        params={"imdb":movie},timeout=15)
    assert req.ok and req.json().get("ok")
    fixtures[movie]=[x for x in req.json().get("streams",[]) if isinstance(x,dict)]
    assert fixtures[movie]
state={"provider":health,"ts":{},"calls":[],"rows":fixtures}
def key(pr,source):return str(pr or"").lower()+"|"+str(source or"").lower()
def snapshot():return state["provider"]
def provider_cooldown(pr,src):
    o=(state["provider"].get("providers")or{}).get(key(pr,src),{})
    return max(0,int(float(o.get("cooldownUntilEpoch")or 0)-time.time()))
def provider_adjust(pr,src):
    h=(state["provider"].get("providers")or{}).get(key(pr,src),{})
    checks=int(h.get("checks")or 0)
    if checks<2:return 0
    rate=float(h.get("successRate")or 0)
    failures=int(h.get("consecutiveFailures")or 0)
    score=int((rate-.75)*1200)-min(1200,failures*350)
    latency=int(h.get("lastLatencyMs")or 0)
    if latency:score+=max(-250,min(150,int((1800-latency)/8)))
    return max(-1800,min(900,score))
def sources(vid,force=False):
    state["calls"].append((vid,bool(force)))
    return [dict(x) for x in state["rows"].get(vid,[])]
def instance(root_ast, names):
    fn=[x for x in root_ast.body if isinstance(x,ast.FunctionDef) and x.name in names]
    scope={"re":re,"time":time,"AUTO_QUICK_RECENT_FAILURE_SECONDS":21600,"AUTO_QUICK_SOURCE_STALE_SECONDS":300,"external_source_cache":{"ts":state["ts"]},
           "external_source_lock":threading.RLock(),"provider_health_lock":threading.RLock(),
           "_provider_health_key":key,"_provider_health_snapshot":snapshot,
           "provider_health_cooldown_seconds":provider_cooldown,"provider_health_adjustment":provider_adjust,
           "external_source_rows":sources,"AUTO_PROFILE_SPECS":modeSpecs}
    exec(compile(ast.Module(body=fn,type_ignores=[]),"<auto-policy-test>","exec"),scope)
    return scope
old=instance(baseline,{"_external_release_text","_external_rank","_auto_profile_rank",
                       "_quality_size_floor_bytes","_prefer_quality_size","best_profile_source"})
new=instance(candidate,wanted)
assert "_auto_quick_ranked_candidates" in new
checks=[]
def passed(label,condition,**data):
    if not condition:raise AssertionError(label+" "+str(data))
    checks.append({"name":label,"pass":True,**data})
    print("PASS",label,flush=True)

# Demonstrate the prior real-world failure: the stale cache had no healthy
# small Comet source for Spider-Man even while the bridge has them.
oldcache=cached.get("rows",{}).get("tt22084616",[])
oldsmall=[x for x in oldcache if int(x.get("resolution")or 0)==1080 and
          bool(x.get("cached")) and 2*1024**3<=int(x.get("size")or 0)<=5*1024**3]
passed("stale-spiderman-cache-previously-without-comet",
       bool(oldsmall) and not any(str(x.get("source") or "").lower()=="comet" for x in oldsmall))
passed("fresh-spiderman-has-smaller-comet-options",
       any(str(x.get("source")or"").lower()=="comet" and 2*1024**3<=int(x.get("size")or 0)<=5*1024**3 for x in fixtures["tt22084616"]))

for vid in fixtures:
    for mode in ("mobile","saver"):
        rows=[x for x in fixtures[vid] if int(x.get("resolution")or 0)==1080]
        ranked=new["_auto_quick_ranked_candidates"](rows,mode)
        passed(f"r3-nonempty-{vid}-{mode}",len(ranked)==len(rows))
        passed(f"r3-retains-all-fallbacks-{vid}-{mode}",
               {x.get("token") for x in ranked}=={x.get("token") for x in rows})
        first=ranked[0]
        print("SELECTED",vid,mode,
              "SOURCE",first.get("source"),"GIB",round(int(first.get("size")or 0)/1073741824,1),
              "CACHED",first.get("cached"),flush=True)
        passed(f"r3-selects-small-cached-comet-{vid}-{mode}",
               str(first.get("source")or"").lower()=="comet" and
               bool(first.get("cached")) and 2*1024**3<=int(first.get("size")or 0)<=8*1024**3)
        peers=[x for x in ranked if str(x.get("source")or"").lower()=="debridio"]
        if peers:passed(f"r3-preserves-debridio-as-fallback-{vid}-{mode}",len(peers)>0)
    for mode in ("best","tv"):
        rows=[x for x in fixtures[vid] if x.get("resolution") in (1080,2160)]
        baseline_rank=sorted(rows,key=lambda x:(old["_auto_profile_rank"](x,mode),int(x.get("size")or 0)),reverse=True)
        candidate_rank=new["_auto_quick_ranked_candidates"](rows,mode)
        passed(f"r3-best-and-tv-unchanged-{vid}-{mode}",
               [x.get("token") for x in candidate_rank]==[x.get("token") for x in baseline_rank])

# The candidate must never force synchronous refresh just for rendering a
# stream list. At playback, stale cached source lists trigger one bounded
# bridge refresh; fresh lists are reused.
vid="tt22084616"
for age,mode,forced in ((10000,"saver",True),(10000,"mobile",True),
                        (12,"saver",False),(12,"mobile",False),
                        (10000,"best",False),(10000,"tv",False)):
    state["ts"]={vid:time.time()-age}
    new["external_source_cache"]={"ts":state["ts"]}
    state["calls"]=[]
    got=new["_auto_quick_source_rows"](vid,mode)
    passed(f"refresh-age-{age}-{mode}",
           bool(got) and state["calls"]==[(vid,forced)])
    print("REFRESH",mode,"age",age,"force",forced)

# All unhealthy: it must still offer the complete original pool and never
# permanently blacklist a provider.
saved=state["provider"]
now=int(time.time())
sick={k:{**v,"consecutiveFailures":8,"lastFailureEpoch":now,"cooldownUntilEpoch":0}
      for k,v in (saved.get("providers")or{}).items()}
state["provider"]={"providers":sick}
rows=[x for x in fixtures[vid] if int(x.get("resolution")or 0)==1080]
ranked=new["_auto_quick_ranked_candidates"](rows,"saver")
passed("all-providers-bad-fallback-still-nonempty",len(ranked)==len(rows))
state["provider"]=saved
# Restoring a provider immediately after successful probes makes it eligible.
recovered={k:dict(v) for k,v in (saved.get("providers")or{}).items()}
for v in recovered.values():
    v.update({"consecutiveFailures":0,"cooldownUntilEpoch":0,
              "successRate":0.98,"lastFailureEpoch":0})
state["provider"]={"providers":recovered}
passed("recovered-providers-eligible",
       not new["_auto_quick_source_unhealthy"]({"provider":"TorBox","source":"Debridio"}))
state["provider"]=saved

# If every cached source is too large, preserve a fallback rather than block
# playback or fabricate new choices.
big=[{"provider":"TorBox","source":"Comet","resolution":1080,
      "size":25*1024**3,"cached":True,"token":"e"*28,"filename":"Movie.1080p.mkv"}]
passed("no-viable-small-source-uses-existing-large-fallback",
       new["_auto_quick_ranked_candidates"](big,"saver")[0]["token"]=="e"*28)
passed("no-fabricated-streams",
       len(new["_auto_quick_ranked_candidates"]([],"saver"))==0)

passed("production-h3-sha-still-original",
       hashlib.sha256(live.read_bytes()).hexdigest()
       =="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f")
receipt={"status":"PASS","checked_utc":datetime.now(timezone.utc).isoformat(),
         "cases":checks,"count":len(checks),"production_changed":False,
         "live_bridge_discovery_titles":list(fixtures),
         "scope":"staged auto Mobile/Saver source freshness and reliability policy only"}
(root/"r3-test-result.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print("R3_TESTS_PASS",len(checks),flush=True)
