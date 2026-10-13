"""Prepare a paired core/launcher/guard update; never change live files."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

EXPECTED = {
    'core': 'eaea71d7be0ffd3a78650602ee010b2360406bb95486fac286f8f9acefe56b59',
    'launcher': '9e1a7a77d4eaaba2e825ddfe9f719f94bb565f82c0c68e78a4dc5cd0e729cc8f',
    'guard': '6b9d1d999bf3b4211e21d73d42e4b6b71cb203e076ff6d44a8c7ac4b5b28f16a',
}

HELPERS = r'''
# AFZ_WATCHED_DOWNLOAD_GUARD_V1. Completion exclusions survive progress pruning,
# an empty/disconnected history feed, restarts, and toggling the normal policy.
watched_download_wake=threading.Event()
watched_download_status={'checkedAt':None,'sources':{},'unmonitored':[]}

def watched_download_blocked(imdb,policy=None):
    obj=policy if isinstance(policy,dict) else auto_media_download_policy_read()
    rows=obj.get('watchedMovies') or {}
    return isinstance(rows,dict) and str(imdb) in rows

def watched_download_record(imdb,title,source):
    imdb=str(imdb or '')
    if not re.fullmatch(r'tt\d+',imdb):
        return False
    if source not in ('user-reported','nuvio','stremio','jellyfin'):
        raise ValueError('Unknown completion source')
    with auto_media_policy_lock:
        obj=auto_media_download_policy_read()
        watched=obj.setdefault('watchedMovies',{})
        prev=watched.get(imdb) or {}
        sources=sorted(set(prev.get('sources') or [])|{source})
        if prev and sources==prev.get('sources') and obj['movies'].get(imdb) is False:
            return False
        now=datetime.now(timezone.utc).isoformat()
        watched[imdb]={'title':str(title or prev.get('title') or imdb)[:180],
                       'recordedAt':prev.get('recordedAt') or now,'sources':sources}
        obj['movies'][imdb]=False
        obj['updatedAt']=now
        AUTO_MEDIA_DOWNLOAD_POLICY_FILE.parent.mkdir(parents=True,exist_ok=True)
        tmp=AUTO_MEDIA_DOWNLOAD_POLICY_FILE.with_suffix('.tmp')
        tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')
        tmp.replace(AUTO_MEDIA_DOWNLOAD_POLICY_FILE)
    watched_download_wake.set()
    return True

def watched_download_jellyfin():
    name=os.getenv('AFZ_WATCHED_JELLYFIN_USER','').strip().casefold()
    headers=jellyfin_headers()
    if not name or not headers:
        raise RuntimeError('Jellyfin watched account is not configured')
    res=requests.get(JELLYFIN_URL+'/Users',headers=headers,timeout=(3,8))
    res.raise_for_status()
    users=[u for u in res.json() if str(u.get('Name') or '').casefold()==name]
    if len(users)!=1:
        raise RuntimeError('Jellyfin watched account is not uniquely identified')
    rows={}
    for start in range(0,20000,1000):
        res=requests.get(JELLYFIN_URL+'/Items',headers=headers,timeout=(3,8),params={
            'UserId':users[0]['Id'],'Recursive':'true','IncludeItemTypes':'Movie',
            'IsPlayed':'true','Fields':'ProviderIds','Limit':1000,'StartIndex':start})
        res.raise_for_status()
        obj=res.json()
        items=obj.get('Items') or []
        for item in items:
            imdb=str((item.get('ProviderIds') or {}).get('Imdb') or '').lower()
            if item.get('Type')=='Movie' and (item.get('UserData') or {}).get('Played') is True and re.fullmatch(r'tt\d+',imdb):
                rows[imdb]={'finished':True,'title':item.get('Name') or imdb}
        if start+len(items)>=int(obj.get('TotalRecordCount') or 0) or len(items)<1000:
            break
    return rows

def watched_download_reconcile():
    global watched_download_status
    status={'checkedAt':datetime.now(timezone.utc).isoformat(),'sources':{},'unmonitored':[]}
    for source,reader in [('nuvio',_nuvio_watch_state_map),('stremio',_stremio_watch_state_map),('jellyfin',watched_download_jellyfin)]:
        try:
            rows=reader() or {}
            finished={imdb:row for imdb,row in rows.items() if isinstance(row,dict) and row.get('finished') is True}
            for imdb,row in finished.items():
                watched_download_record(imdb,row.get('title') or imdb,source)
            status['sources'][source]={'records':len(rows),'completed':len(finished)}
        except Exception as exc:
            # Do not expose upstream URLs, authentication material, or user IDs.
            status['sources'][source]={'errorType':type(exc).__name__}
    policy=auto_media_download_policy_read()
    watched=policy.get('watchedMovies') or {}
    status['excludedCount']=len(watched)
    try:
        for movie in rget('/movie') or []:
            imdb=str(movie.get('imdbId') or '')
            if watched_download_blocked(imdb,policy) and movie.get('monitored'):
                updated=set_radarr_movie_monitored(movie,False)
                if updated and updated.get('monitored') is False:
                    status['unmonitored'].append(imdb)
        status['radarrChecked']=True
    except Exception as exc:
        status['radarrChecked']=False
        status['radarrErrorType']=type(exc).__name__
    watched_download_status=status
    return status

def watched_download_bg():
    while True:
        watched_download_wake.clear()
        try:
            watched_download_reconcile()
        except Exception as exc:
            watched_download_status['errorType']=type(exc).__name__
        watched_download_wake.wait(120)

@app.get('/auto-media/watched-guard.json')
def watched_download_guard_status():
    obj=auto_media_download_policy_read()
    return {'ok':True,'profileId':NUVIO_PERSONALIZATION_PROFILE_ID,
            'watchedMovies':obj.get('watchedMovies') or {},**watched_download_status}

'''

def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Source anchor changed or duplicated: '+old[:70])
    return text.replace(old,new,1)

def patch_core(text):
    text=once(text,'def auto_media_download_policy_read():',HELPERS+'def auto_media_download_policy_read():')
    policy_old="""    except Exception:
        obj={}
    if not isinstance(obj,dict):
        obj={}
    if not isinstance(obj.get('movies'),dict):
        obj['movies']={}
    if not isinstance(obj.get('series'),dict):
        obj['series']={}
    return obj

def auto_media_download_enabled"""
    policy_new="""    except Exception:
        raise HTTPException(503,'Could not read automatic download policy')
    if not isinstance(obj,dict):
        raise HTTPException(503,'Invalid automatic download policy')
    for key in ('movies','series','watchedMovies'):
        if key in obj and not isinstance(obj[key],dict):
            raise HTTPException(503,'Invalid automatic download policy')
        obj.setdefault(key,{})
    return obj

def auto_media_download_enabled"""
    text=once(text,policy_old,policy_new)
    text=once(text,"    rows=obj.get(key) if isinstance(obj.get(key),dict) else {}\n    return bool(rows.get(str(imdb),True))", "    if key=='movies' and watched_download_blocked(imdb,obj):\n        return False\n    rows=obj.get(key) if isinstance(obj.get(key),dict) else {}\n    return bool(rows.get(str(imdb),True))")
    text=once(text,"        obj=auto_media_download_policy_read()\n        rows=obj.setdefault(key,{})", "        obj=auto_media_download_policy_read()\n        if key=='movies' and enabled and watched_download_blocked(imdb,obj):\n            raise HTTPException(409,'Already watched: automatic downloads are blocked')\n        rows=obj.setdefault(key,{})")
    text=once(text,"    browser_base=BROWSER_PUBLIC_BASE or base\n    return {\n        'name':f'AFZ Auto Download {mark}',", "    if media_type=='movie' and watched_download_blocked(imdb):\n        title='Already watched · automatic downloads blocked'\n    browser_base=BROWSER_PUBLIC_BASE or base\n    return {\n        'name':f'AFZ Auto Download {mark}',")
    text=once(text,"    state='Downloads enabled' if enabled else 'Do not download'", "    state='Downloads enabled' if enabled else 'Do not download'\n    if media_type=='movie' and watched_download_blocked(imdb):\n        state='Already watched · automatic downloads blocked'\n        checked='disabled'")
    text=once(text,"    threading.Thread(target=watchlist_auto_bg,daemon=True).start()", "    threading.Thread(target=watched_download_bg,name='afz-watched-download-guard',daemon=True).start()\n    threading.Thread(target=watchlist_auto_bg,daemon=True).start()")
    text=once(text,"        auto=bool(row.get('autoRequest'))\n\n        # Track", "        auto=bool(row.get('autoRequest'))\n        if watched_download_blocked(imdb):\n            if auto:\n                watchlist_set_auto(imdb,False)\n                changed=True\n            continue\n\n        # Track")
    text=once(text,"        if not auto:\n            continue\n\n        try:\n            tmdb=row.get('tmdbId')", "        if not auto or not auto_media_download_enabled('movie',imdb):\n            continue\n\n        try:\n            tmdb=row.get('tmdbId')")
    text=once(text,'    key=f"{int(row[\'profileId\'])}:{row[\'imdbId\']}"', '    if int(row[\'profileId\'])==NUVIO_PERSONALIZATION_PROFILE_ID and row[\'isCompleted\']:\n        watched_download_record(row[\'imdbId\'],row.get(\'title\') or row[\'imdbId\'],\'nuvio\')\n    key=f"{int(row[\'profileId\'])}:{row[\'imdbId\']}"')
    ast.parse(text)
    return text

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--core-root',type=Path,required=True)
    ap.add_argument('--guard-root',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args()
    paths={'core':args.core_root/'stremio_catalog.py',
           'launcher':args.core_root/'Start-AFZ-Stremio-H3-Core243.ps1',
           'guard':args.guard_root/'Guard-Source-Health-V3.ps1'}
    before={k:hashlib.sha256(p.read_bytes()).hexdigest() for k,p in paths.items()}
    if before!=EXPECTED:
        raise RuntimeError('Live source hashes changed; inspect before preparing')
    contents={k:p.read_text(encoding='utf-8-sig') for k,p in paths.items()}
    contents['core']=patch_core(contents['core'])
    contents['launcher']=once(contents['launcher'],"  $env:JELLYFIN_URL='http://100.71.26.69:8096'", "  $env:JELLYFIN_URL='http://100.71.26.69:8096'\n  $env:AFZ_WATCHED_JELLYFIN_USER='coolyo'")
    digest=hashlib.sha256(contents['core'].encode('utf-8')).hexdigest()
    contents['guard']=once(contents['guard'],EXPECTED['core'],digest)
    args.output.mkdir(parents=True,exist_ok=False)
    candidates={}
    after={}
    for name,content in contents.items():
        dest=args.output/paths[name].name
        dest.write_bytes(content.encode('utf-8'))
        candidates[name]=str(dest)
        after[name]=hashlib.sha256(dest.read_bytes()).hexdigest()
    receipt={'before':before,'after':after,'candidates':candidates,'liveFilesUnchanged':True}
    (args.output/'prepared.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    print(json.dumps(receipt,indent=2))

if __name__=='__main__': main()
