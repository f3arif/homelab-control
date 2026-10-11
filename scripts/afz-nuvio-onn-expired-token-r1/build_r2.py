from pathlib import Path
import ast, hashlib, json, difflib, datetime

stage=Path(r"C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011")
src=stage/"stremio_catalog.original.py"
data=src.read_bytes()
old=data.decode("utf-8")
expected="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
if hashlib.sha256(data).hexdigest()!=expected:raise RuntimeError("Unexpected R1 baseline; refuse to build R2")

def subst(anchor,replacement,label):
    global old
    count=old.count(anchor)
    if count!=1:raise RuntimeError(f"{label}: expected one anchor; saw {count}")
    old=old.replace(anchor,replacement,1)

subst(
    "external_source_cache={'ts':{},'rows':{}}",
    """external_source_cache={'ts':{},'rows':{},'history':{}}
# Expired source tokens are opaque identifiers, NOT reusable media URLs.
# Retain only bounded release metadata to re-identify the same chosen source.
EXTERNAL_TOKEN_HISTORY_TTL=72*3600
EXTERNAL_TOKEN_HISTORY_PER_TITLE=140
EXTERNAL_TOKEN_HISTORY_GLOBAL_LIMIT=8000""",
    "cache schema"
)
subst(
    "        external_source_cache['rows']={str(k):[dict(x) for x in (v or []) if isinstance(x,dict)] for k,v in (_esc.get('rows') or {}).items()}\n",
    """        external_source_cache['rows']={str(k):[dict(x) for x in (v or []) if isinstance(x,dict)] for k,v in (_esc.get('rows') or {}).items()}
        external_source_cache['history']={
            str(vid):{str(tok):dict(record) for tok,record in recs.items()
                      if isinstance(record,dict)}
            for vid,recs in (_esc.get('history') or {}).items()
            if re.fullmatch(r'tt\\d+',str(vid)) and isinstance(recs,dict)
        }
""",
    "history loader"
)

history_functions="""
def _external_token_history_compact_locked(now):
    # Called with external_source_lock; no URL/headers/credentials stored.
    history=external_source_cache.setdefault('history',{})
    global_rows=[]
    for vid in list(history):
        records=history.get(vid)
        if not re.fullmatch(r'tt\\d+',str(vid or '')) or not isinstance(records,dict):
            history.pop(vid,None);continue
        for token,rec in list(records.items()):
            if not re.fullmatch(r'[a-f0-9]{20,64}',str(token)) or not isinstance(rec,dict):
                records.pop(token,None);continue
            try:
                ts=float(rec.get('ts') or 0)
                meta=rec.get('row') or {}
                valid=(isinstance(meta,dict) and
                       re.fullmatch(r'tt\\d+',str(vid)) and
                       0<=now-ts<=EXTERNAL_TOKEN_HISTORY_TTL and
                       str(meta.get('token') or '')==token)
            except (TypeError,ValueError):
                valid=False
            if not valid:records.pop(token,None)
        if len(records)>EXTERNAL_TOKEN_HISTORY_PER_TITLE:
            oldest=sorted(records,key=lambda tok:float(records[tok].get('ts') or 0))
            for token in oldest[:-EXTERNAL_TOKEN_HISTORY_PER_TITLE]:
                records.pop(token,None)
        if not records:history.pop(vid,None)
        else:
            global_rows.extend((float(rec.get('ts') or 0),vid,token) for token,rec in records.items())
    overflow=len(global_rows)-EXTERNAL_TOKEN_HISTORY_GLOBAL_LIMIT
    if overflow>0:
        for _,vid,token in sorted(global_rows)[:overflow]:
            records=history.get(vid) or {}
            records.pop(token,None)
            if not records:history.pop(vid,None)


def _external_token_history_remember_locked(vid,rows,now):
    if not re.fullmatch(r'tt\\d+',str(vid or '')):
        return
    per=external_source_cache.setdefault('history',{}).setdefault(vid,{})
    for source in (rows or []):
        if not isinstance(source,dict):continue
        token=str(source.get('token') or '')
        if not re.fullmatch(r'[a-f0-9]{20,64}',token):continue
        row={k:source.get(k) for k in (
            'token','provider','source','resolution','size','name','title','filename'
        )}
        try:
            if int(row.get('resolution') or 0) not in (1080,2160):continue
            if int(row.get('size') or 0)<0:continue
            # Never persist media URLs in the historical-token map.
            if any('://' in str(row.get(k) or '') for k in ('filename','title','name')):continue
        except (TypeError,ValueError):
            continue
        per[token]={'ts':now,'row':row}
    _external_token_history_compact_locked(now)


def _external_old_release_row(vid,token):
    now=time.time()
    with external_source_lock:
        for candidate in (external_source_cache.get('rows') or {}).get(vid,[]):
            if isinstance(candidate,dict) and str(candidate.get('token') or '')==str(token):
                return dict(candidate)
        record=((external_source_cache.get('history') or {}).get(vid) or {}).get(token)
        if not isinstance(record,dict):return None
        try:ts=float(record.get('ts') or 0)
        except (TypeError,ValueError):return None
        if not 0<=now-ts<=EXTERNAL_TOKEN_HISTORY_TTL:return None
        row=record.get('row')
        if not isinstance(row,dict) or str(row.get('token') or '')!=str(token):
            return None
        return dict(row)


"""
subst(
    "def _persist_external_source_cache():\n",
    history_functions+"def _persist_external_source_cache():\n",
    "history functions"
)
subst(
    "                'rows':{str(k):[dict(x) for x in (v or []) if isinstance(x,dict)] for k,v in (external_source_cache.get('rows') or {}).items()}\n",
    """                'rows':{str(k):[dict(x) for x in (v or []) if isinstance(x,dict)] for k,v in (external_source_cache.get('rows') or {}).items()},
                'history':{str(vid):{str(tok):dict(rec) for tok,rec in (records or {}).items()}
                           for vid,records in (external_source_cache.get('history') or {}).items()}
""",
    "history persistence"
)
subst(
    """        with external_source_lock:
            external_source_cache.setdefault('ts',{})[vid]=time.time()
            external_source_cache.setdefault('rows',{})[vid]=[dict(x) for x in clean]
        _persist_external_source_cache()
        return clean
""",
    """        with external_source_lock:
            now=time.time()
            old_rows=(external_source_cache.get('rows') or {}).get(vid) or []
            _external_token_history_remember_locked(vid,old_rows,now)
            external_source_cache.setdefault('ts',{})[vid]=now
            external_source_cache.setdefault('rows',{})[vid]=[dict(x) for x in clean]
        _persist_external_source_cache()
        return clean
""",
    "refresh archiving"
)
subst(
    """    if not re.match(r'^https?://',url,re.I):
        raise HTTPException(404,'External stream expired; refresh the Stremio stream list')
    with resolved_stream_lock:
        external_resolved_cache[key]={'ts':time.time(),'url':url}
""",
    """    if not re.match(r'^https?://',url,re.I):
        # First try a live catalog entry, then bounded historical metadata
        # retained from earlier catalog refreshes. Match SAME exact release.
        old_row=_external_old_release_row(vid,token)
        if old_row:
            try:
                refreshed=external_source_rows(vid,force=True)
                fingerprint=_external_candidate_identity(old_row)
                fresh=next((row for row in refreshed
                            if _external_candidate_identity(row)==fingerprint
                            and re.fullmatch(r'[a-f0-9]{20,64}',str(row.get('token') or ''))),None)
                if fresh:
                    fresh_token=requests.utils.quote(str(fresh['token']),safe='')
                    reply=h3_order_call(
                        'GET',f'/external-resolve?token={fresh_token}&imdb={qimdb}',timeout
                    )
                    if isinstance(reply,dict) and reply.get('ok'):
                        candidate_url=str(reply.get('url') or '')
                        if re.match(r'^https?://',candidate_url,re.I):
                            url=candidate_url
            except Exception:
                pass
    if not re.match(r'^https?://',url,re.I):
        raise HTTPException(404,'External stream expired; refresh the Stremio stream list')
    with resolved_stream_lock:
        external_resolved_cache[key]={'ts':time.time(),'url':url}
""",
    "resolve expired"
)

# Serialize source-cache snapshots and use a per-writer temporary file.
# Without this, concurrent catalog refresh workers can race on the same .tmp
# file and silently discard the historical map.
subst("external_source_lock=threading.Lock()\n",
      "external_source_lock=threading.Lock()\nexternal_source_persist_lock=threading.Lock()\n",
      "history save synchronization")
start=old.index("def _persist_external_source_cache():")
end=old.index("\n\ndef external_source_rows(vid,force=False):",start)
persist_function="""def _persist_external_source_cache():
    try:
        with external_source_persist_lock:
            with external_source_lock:
                _external_token_history_compact_locked(time.time())
                obj={
                    'ts':dict(external_source_cache.get('ts') or {}),
                    'rows':{str(k):[dict(x) for x in (v or []) if isinstance(x,dict)] for k,v in (external_source_cache.get('rows') or {}).items()},
                    'history':{str(vid):{str(tok):dict(rec) for tok,rec in (records or {}).items()}
                               for vid,records in (external_source_cache.get('history') or {}).items()}
                }
            tmp=EXTERNAL_SOURCE_CACHE_FILE.with_name(
                EXTERNAL_SOURCE_CACHE_FILE.name+'.'+str(threading.get_ident())+'.tmp'
            )
            tmp.write_text(json.dumps(obj,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
            tmp.replace(EXTERNAL_SOURCE_CACHE_FILE)
    except Exception:
        pass"""
old=old[:start]+persist_function+old[end:]

ast.parse(old)
out=stage/"stremio_catalog.r2.candidate.py"
out.write_text(old,encoding="utf-8",newline="")
patch="\n".join(difflib.unified_diff(data.decode("utf-8").splitlines(),old.splitlines(),fromfile="a/stremio_catalog.py",tofile="b/stremio_catalog.py",lineterm=""))+"\n"
(stage/"expired-token-history-r2.patch").write_text(patch,encoding="utf-8",newline="")
receipt={
    "candidate":"R2 bounded historical AFZ source tokens",
    "created_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "original_sha256":expected,
    "candidate_sha256":hashlib.sha256(out.read_bytes()).hexdigest(),
    "candidate_bytes":out.stat().st_size,
    "patch_lines":len(patch.splitlines()),
    "ast_parse":"PASS","live_service_changed":False,
    "history_ttl_hours":72,"history_per_title":140,"history_global_limit":8000
}
(stage/"r2-staging-receipt.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print(json.dumps(receipt,indent=2),flush=True)
