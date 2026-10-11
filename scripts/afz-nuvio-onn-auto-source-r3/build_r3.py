from pathlib import Path
from datetime import datetime,timezone
import hashlib, json, ast, difflib

src=Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py")
out=Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-auto-source-r3-20261011")
original=src.read_bytes()
expected="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
if hashlib.sha256(original).hexdigest()!=expected:raise RuntimeError("Refuse: unverified live H3 baseline")
candidate=original.decode("utf-8")
def subst(before,after,label):
    global candidate
    occurrences=candidate.count(before)
    if occurrences!=1:raise RuntimeError(f"{label} anchor count={occurrences}")
    candidate=candidate.replace(before,after,1)

addon="""
# Conservative automatic-playback freshness and source-health routing.
# Does not change explicit manual streams, source links, or movie identity.
AUTO_QUICK_SOURCE_STALE_SECONDS=300
AUTO_QUICK_RECENT_FAILURE_SECONDS=6*3600


def _auto_quick_source_rows(vid,mode):
    # H3 failover source cache can be many hours old and contain only
    # providers whose bridge tokens have expired. Force a bounded refresh
    # at playback (not while rendering the stream picker) for Mobile/Saver.
    if str(mode or '').lower() not in ('mobile','saver'):
        return external_source_rows(vid,force=False)
    with external_source_lock:
        stamp=float((external_source_cache.get('ts') or {}).get(str(vid)) or 0)
    stale=stamp<=0 or (time.time()-stamp)>AUTO_QUICK_SOURCE_STALE_SECONDS
    return external_source_rows(vid,force=stale)


def _auto_quick_source_unhealthy(row):
    provider=row.get('provider')
    source=row.get('source')
    if provider_health_cooldown_seconds(provider,source)>0:
        return True
    key=_provider_health_key(provider,source)
    obj=_provider_health_snapshot()
    with provider_health_lock:
        health=dict((obj.get('providers') or {}).get(key) or {})
    try:
        failures=max(0,int(health.get('consecutiveFailures') or 0))
        last_failure=max(0,float(health.get('lastFailureEpoch') or 0))
        checks=max(0,int(health.get('checks') or 0))
        rate=float(health.get('successRate') or 0)
    except (ValueError,TypeError):
        return False
    recent=(last_failure>0 and 0<=time.time()-last_failure<=AUTO_QUICK_RECENT_FAILURE_SECONDS)
    return bool(recent and (failures>=3 or (checks>=10 and rate<0.6)))


def _auto_quick_ranked_candidates(rows,mode):
    # Full pool survives below preferred tier so the existing two-source
    # fallback can still try an alternate provider when the first fails.
    mode=str(mode or '').lower()
    ordered=sorted(
        (dict(x) for x in rows if isinstance(x,dict)),
        key=lambda x:(_auto_profile_rank(x,mode),int(x.get('size') or 0)),
        reverse=True
    )
    if mode not in ('mobile','saver') or not ordered:
        return ordered
    reliable=[x for x in ordered if not _auto_quick_source_unhealthy(x)]
    reliable=reliable or ordered
    cached=[x for x in reliable if x.get('cached')]
    cached=cached or reliable
    limits=(5,8,12) if mode=='saver' else (8,12,20)
    preferred=[]
    for cap in limits:
        preferred=[x for x in cached
                   if 2*1024**3<=int(x.get('size') or 0)<=cap*1024**3]
        if preferred:
            break
    preferred=preferred or cached
    tokens={str(x.get('token') or '') for x in preferred}
    return preferred+[x for x in ordered if str(x.get('token') or '') not in tokens]


"""
subst("def best_profile_source(vid,profile,force=False):\n",
      addon+"def best_profile_source(vid,profile,force=False):\n",
      "new source helpers")
subst(
"""    rows.sort(key=lambda x:(_auto_profile_rank(x,profile),int(x.get('size') or 0)),reverse=True)
    return dict(rows[0])

def best_external_source(vid,resolution,force=False):
""",
"""    if str(profile or '').lower() in ('mobile','saver'):
        rows=_auto_quick_ranked_candidates(rows,profile)
    else:
        rows.sort(key=lambda x:(_auto_profile_rank(x,profile),int(x.get('size') or 0)),reverse=True)
    return dict(rows[0])

def best_external_source(vid,resolution,force=False):
""",
"stream picker Mobile/Saver estimate"
)
subst(
"""        rows=[x for x in external_source_rows(vid,force=False)
              if int(x.get('resolution') or 0) in allowed]
        rows.sort(key=lambda x:(_auto_profile_rank(x,mode),int(x.get('size') or 0)),reverse=True)
        direct_target=int(profile['directTarget'])
""",
"""        rows=[x for x in _auto_quick_source_rows(vid,mode)
              if int(x.get('resolution') or 0) in allowed]
        rows=_auto_quick_ranked_candidates(rows,mode)
        direct_target=int(profile['directTarget'])
""",
"actual Auto playback candidate ordering"
)
ast.parse(candidate)
(out/"stremio_catalog.original.py").write_bytes(original)
cpath=out/"stremio_catalog.auto-r3.candidate.py"
cpath.write_text(candidate,encoding="utf-8",newline="")
patch="\n".join(difflib.unified_diff(original.decode("utf-8").splitlines(),candidate.splitlines(),
                    fromfile="a/stremio_catalog.py",tofile="b/stremio_catalog.py",lineterm=""))+"\n"
(out/"auto-source-ranking-r3.patch").write_text(patch,encoding="utf-8",newline="")
receipt={"status":"STAGED_ONLY","created_utc":datetime.now(timezone.utc).isoformat(),
 "production_source_sha":expected,"candidate_source_sha":hashlib.sha256(cpath.read_bytes()).hexdigest(),
 "patch_lines":len(patch.splitlines()),"python_ast":"PASS",
 "changes_live_service":False,"refresh_stale_after_seconds":300,
 "provider_failure_recent_seconds":21600,"preserves_fallback_pool":True,
 "touches_only_mobile_saver":True}
(out/"r3-staging.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print(json.dumps(receipt,indent=2),flush=True)
