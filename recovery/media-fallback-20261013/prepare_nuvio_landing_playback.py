"""Prepare (never deploy) the paired Nuvio landing-folder/guard update.

The existing Jellyfin proxy remains the only playback transport. This adds an
explicitly configured remote movie root, authenticated one-byte availability
checks, and cards in the existing local catalog. No media is copied or changed.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path

EXPECTED_CORE = "d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
EXPECTED_LAUNCHER = "bffec35f5e14a7550b5417e17978b7697b7d4b18d9e1ba0537a1b543dd43d695"
EXPECTED_GUARD = "c2611ae2576809be3e4e23fc423683dab12ddb2b4eb73de978ec16902411d0ec"

HELPERS = r'''
# AFZ_HP_LANDING_MOVIES_V1: only the configured Envy movie landing directory.
def jellyfin_remote_movie_media(item):
    from pathlib import PurePosixPath
    if os.getenv('AFZ_HP_JELLYFIN_ENABLED') != '1' or not isinstance(item,dict):
        return None
    root_s=os.getenv('AFZ_HP_JELLYFIN_MOVIE_ROOT','').strip().rstrip('/')
    if not root_s.startswith('/') or len(PurePosixPath(root_s).parts)<3:
        return None
    if '..' in PurePosixPath(root_s).parts or '\\' in root_s:
        return None
    raw=str(item.get('Path') or '')
    p=PurePosixPath(raw)
    if not raw.startswith(root_s+'/') or '..' in p.parts or '\\' in raw:
        return None
    if item.get('Type')!='Movie' or p.suffix.lower() not in VIDEO_EXTS:
        return None
    item_id=str(item.get('Id') or '').replace('-','').lower()
    if not re.fullmatch(r'[0-9a-f]{32}',item_id):
        return None
    for src in item.get('MediaSources') or []:
        if not isinstance(src,dict) or src.get('Path')!=raw:
            continue
        if src.get('IsRemote') is not False or str(src.get('Protocol') or '').lower()!='file':
            continue
        if str(src.get('Container') or '').lower()=='strm':
            continue
        try:
            size=int(src.get('Size') or 0)
        except (TypeError,ValueError):
            continue
        if size>1024*1024:
            return {'id':item_id,'path':raw,'filename':p.name,'size':size}
    return None

def jellyfin_remote_movie_available(item):
    media=jellyfin_remote_movie_media(item)
    if not media:
        return False
    key=(media['id'],media['path'],media['size'])
    now=time.time()
    with jf_api_lock:
        probes=jf_api_cache.setdefault('landing_probes',{})
        hit=probes.get(key)
        if hit and now-hit['ts']<60:
            return bool(hit['ok'])
    headers=jellyfin_headers()
    if not headers:
        return False
    headers=dict(headers,Range='bytes=0-0')
    headers['Accept-Encoding']='identity'
    ok=False
    try:
        with requests.get(JELLYFIN_URL+'/Videos/'+media['id']+'/stream',
                          headers=headers,params={'static':'true'},stream=True,
                          allow_redirects=False,timeout=(2,4)) as upstream:
            expected='bytes 0-0/'+str(media['size'])
            if upstream.status_code==206 and upstream.headers.get('Content-Range')==expected:
                ok=len(next(upstream.iter_content(chunk_size=1),b''))==1
    except requests.RequestException:
        pass
    with jf_api_lock:
        probes=jf_api_cache.setdefault('landing_probes',{})
        for old,entry in list(probes.items()):
            if now-entry['ts']>=60:
                probes.pop(old,None)
        probes[key]={'ts':now,'ok':ok}
    return ok

def jellyfin_landing_movie_catalog():
    rows=[]
    for imdb,items in jellyfin_movie_index(blocking=False).items():
        for item in items:
            if not jellyfin_remote_movie_available(item):
                continue
            rows.append({'id':imdb,'type':'movie','name':item.get('Name') or imdb,
                         'releaseInfo':str(item.get('ProductionYear') or ''),
                         'poster':f'{PUBLIC_BASE}/art/poster/{imdb}.jpg?media=movie',
                         'posterShape':'poster',
                         'description':'Downloaded on HP Envy - Ready to Watch'})
            break
    return rows

'''

OLD_STREAM = '''    path = jellyfin_mapped_local_path(item.get('Path'))
    item_id = str(item.get('Id') or '').replace('-', '').lower()
    if not path or not re.fullmatch(r'[0-9a-f]{32}', item_id):
        return None
    try:
        return {
            'name': 'AFZ Jellyfin', 'title': 'Play through HP Envy',
            'url': f'{base}/jellyfin/{vid}?item_id={item_id}',
            'behaviorHints': {'filename': path.name, 'videoSize': path.stat().st_size},
        }
    except OSError:
        return None'''
NEW_STREAM = '''    remote = jellyfin_remote_movie_media(item)
    path = jellyfin_mapped_local_path(item.get('Path')) if not remote else None
    item_id = str(item.get('Id') or '').replace('-', '').lower()
    if (not path and not remote) or not re.fullmatch(r'[0-9a-f]{32}', item_id):
        return None
    try:
        filename = remote['filename'] if remote else path.name
        size = remote['size'] if remote else path.stat().st_size
        return {
            'name': 'AFZ Jellyfin', 'title': 'Play through HP Envy',
            'url': f'{base}/jellyfin/{vid}?item_id={item_id}',
            'behaviorHints': {'filename': filename, 'videoSize': size},
        }
    except OSError:
        return None'''
OLD_REAL = '''    if not isinstance(item,dict) or jellyfin_request_placeholder(item):
        return False
    paths=[item.get('Path')]'''
NEW_REAL = '''    if not isinstance(item,dict) or jellyfin_request_placeholder(item):
        return False
    if jellyfin_remote_movie_available(item):
        return True
    paths=[item.get('Path')]'''
OLD_CATALOG = '''    if cfg.get('kind')=='jellyfin':
        d=refresh_jellyfin_catalogs()
        return filter_hidden_home_metas(list(d['catalogs'].get(cid,[])))'''
NEW_CATALOG = '''    if cfg.get('kind')=='jellyfin':
        d=refresh_jellyfin_catalogs()
        metas=list(d['catalogs'].get(cid,[]))
        if cid=='afz_local_ready':
            metas=_merge_meta_rows([jellyfin_landing_movie_catalog(),metas],limit=250)
        return filter_hidden_home_metas(metas)'''

def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('Source anchor changed or duplicated')
    return source.replace(old, new, 1)

def patch_core(source):
    source = replace_once(source, 'def jellyfin_real_local_item(item):', HELPERS+'def jellyfin_real_local_item(item):')
    source = replace_once(source, OLD_REAL, NEW_REAL)
    source = replace_once(source, OLD_STREAM, NEW_STREAM)
    source = replace_once(source, OLD_CATALOG, NEW_CATALOG)
    ast.parse(source)
    return source

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--core-root',type=Path,required=True)
    ap.add_argument('--guard-root',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--movie-root',required=True)
    args=ap.parse_args()
    if "'" in args.movie_root or '\n' in args.movie_root or '\r' in args.movie_root:
        raise ValueError('Invalid root')
    specs=[('core',args.core_root/'stremio_catalog.py',EXPECTED_CORE),
           ('launcher',args.core_root/'Start-AFZ-Stremio-H3-Core243.ps1',EXPECTED_LAUNCHER),
           ('guard',args.guard_root/'Guard-Source-Health-V3.ps1',EXPECTED_GUARD)]
    before={}
    for name,path,expected in specs:
        data=path.read_bytes()
        if sha(data)!=expected:
            raise ValueError(name+' changed since inspection')
        before[name]=data.decode('utf-8-sig').replace('\r\n','\n')
    core=patch_core(before['core'])
    core_hash=sha(core.encode())
    launcher=replace_once(before['launcher'],"  $env:AFZ_HP_JELLYFIN_ENABLED='1'",
        "  $env:AFZ_HP_JELLYFIN_ENABLED='1'\n  $env:AFZ_HP_JELLYFIN_MOVIE_ROOT='"+args.movie_root+"'")
    guard=replace_once(before['guard'],EXPECTED_CORE,core_hash)
    args.output.mkdir(parents=True,exist_ok=True)
    receipt={'before':{},'after':{},'candidates':{},'activeFilesUnchanged':True}
    for name,path,expected in specs:
        candidate=args.output/(path.name+'.candidate')
        if candidate.exists():
            raise FileExistsError(candidate)
        data={'core':core,'launcher':launcher,'guard':guard}[name].encode()
        candidate.write_bytes(data)
        receipt['before'][name]=expected
        receipt['after'][name]=sha(data)
        receipt['candidates'][name]=str(candidate)
    (args.output/'prepared.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
    print(json.dumps(receipt,indent=2))

if __name__=='__main__':
    main()
