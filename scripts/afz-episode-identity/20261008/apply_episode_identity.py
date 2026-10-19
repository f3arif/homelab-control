"""Stage a guarded patch against the inspected live AFZ backend; never deploy."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import sys

BASE_SHA = '3a51419da35600ffa9668e3e60923a63459afb76e5e6325bf4fd1c0eed7a347f'
HELPERS = r'''
def _series_release_identity(imdb):
    # Cinemeta is keyed by IMDb, not a broad title search. Retain known identity
    # during a metadata outage, but do not accept anonymous provider releases.
    meta=_failover_series_meta(imdb) or {}
    if not meta:
        with _failover_series_meta_lock:
            meta=dict(_failover_series_meta_cache.get(str(imdb)) or {})
    title=str(meta.get('name') or meta.get('title') or '').strip()
    year=str(meta.get('releaseInfo') or meta.get('year') or '')[:4]
    return title,year if re.fullmatch(r'(?:19|20)\d{2}',year) else ''

def _series_release_matches(identity,season,episode,row):
    import unicodedata
    title,year=identity
    if not title or not isinstance(row,dict):
        return False
    # Filename is authoritative: a generic provider title must not override it.
    text=str(row.get('filename') or row.get('title') or '').strip()
    pattern=r'(?i)(?<![a-z0-9])(?:s(\d{1,2})[ ._-]*e(\d{1,3})|(\d{1,2})x(\d{1,3})|season[ ._-]*(\d{1,2})[ ._-]*episode[ ._-]*(\d{1,3}))(?!\d)'
    markers=list(re.finditer(pattern,text))
    if not markers:
        return False
    prefix=text[:markers[0].start()].strip(' ._-')
    # Scene/group tags may precede the title. Compare the whole title prefix,
    # never a substring or bag of words (Friends != Your Friends and Neighbors).
    variants={prefix,re.sub(r'^(?:\[[^\[\]]+\][ ._-]*)+','',prefix)}
    def key(value):
        value=unicodedata.normalize('NFKD',value.casefold())
        return ''.join(c for c in value if c.isalnum() and not unicodedata.combining(c))
    title_matches=False
    for candidate in variants:
        # A numeric series title (for example 1923) is not a release year.
        if key(candidate)==key(title):
            title_matches=True
            break
        dated=re.search(r'(?<!\d)((?:19|20)\d{2})[ ._\-\[\]()]*$',candidate)
        if dated:
            if not year or dated.group(1)!=year:
                continue
            candidate=candidate[:dated.start()].rstrip(' ._-([')
        if key(candidate)==key(title):
            title_matches=True
            break
    if not title_matches:
        return False
    for marker in markers:
        ss=int(marker.group(1) or marker.group(3) or marker.group(5))
        ee=int(marker.group(2) or marker.group(4) or marker.group(6))
        if ss!=int(season):
            continue
        if ee==int(episode):
            return True
        # Paired/cartoon episodes: S01E01-E02 and S01E01E02. A hyphen
        # represents a range; concatenated E markers represent explicit episodes.
        tail=text[marker.end():]
        previous=ee
        while True:
            extra=re.match(r'(?i)^[ ._]*(?:(-)[ ._]*e?|e)(\d{1,3})(?!\d)',tail)
            if not extra:
                break
            number=int(extra.group(2))
            if number==int(episode) or (extra.group(1) and previous<=int(episode)<=number):
                return True
            previous=number
            tail=tail[extra.end():]
    return False

def _filter_series_release_rows(rows,identity,season,episode,expected_title=''):
    return [x for x in (rows or [])
            if _series_release_matches(identity,season,episode,x)
            and (not expected_title or _episode_title_matches_release(expected_title,x))]

'''

def replace_function(text,name,transform):
    node=next(n for n in ast.parse(text).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name)
    lines=text.splitlines(keepends=True)
    original=''.join(lines[node.lineno-1:node.end_lineno])
    updated=transform(original)
    assert updated!=original, name
    return ''.join(lines[:node.lineno-1])+updated+''.join(lines[node.end_lineno:])

def once(text,old,new):
    assert text.count(old)==1, old
    return text.replace(old,new,1)

def patch_series(text):
    text=once(text,'    now=time.time()\n',"    identity=_series_release_identity(imdb)\n    _,match_season,match_episode=parse_series_video_id(provider_video_id)\n    def safe_rows(rows):\n        return _filter_series_release_rows(rows,identity,match_season,match_episode,expected_title)\n    now=time.time()\n")
    text=once(text,"        if expected_title:\n            cached_rows=[x for x in cached_rows if _episode_title_matches_release(expected_title,x)]",'        cached_rows=safe_rows(cached_rows)')
    text=once(text,"                return [dict(x) for x in ((external_source_cache.get('rows') or {}).get(video_id) or [])]","                return safe_rows([dict(x) for x in ((external_source_cache.get('rows') or {}).get(video_id) or [])])")
    text=once(text,'            if expected_title and not _episode_title_matches_release(expected_title,x):','            if not safe_rows([x]):')
    text=once(text,"        if expected_title:\n            fallback=[x for x in fallback if _episode_title_matches_release(expected_title,x)]\n        return fallback",'        return safe_rows(fallback)')
    return text

def patch_resolver(text):
    text=once(text,"    key=str(vid)+'|'+str(token)","    resolver_video_id=vid\n    if parse_series_video_id(vid):\n        row=next((x for x in series_external_source_rows(vid) if str(x.get('token') or '')==str(token)),None)\n        if row is None:\n            raise HTTPException(404,'Episode source does not match; refresh the stream list')\n        resolver_video_id=str(row.get('resolverVideoId') or vid)\n    key=str(vid)+'|'+str(token)")
    text=once(text,"    qimdb=requests.utils.quote(str(vid),safe='')","    qimdb=requests.utils.quote(str(resolver_video_id),safe='')")
    return text

def patch_choices(text):
    text=once(text,"        resolver_vid=str(x.get('resolverVideoId') or video_id)",'        resolver_vid=video_id')
    text=once(text,"        resolver_vid=str(best_row.get('resolverVideoId') or video_id)",'        resolver_vid=video_id')
    return text

def stage(source,directory):
    source=Path(source); directory=Path(directory)
    raw=source.read_bytes()
    assert hashlib.sha256(raw).hexdigest()==BASE_SHA, 'Live backend changed; inspect before staging'
    newline='\r\n' if b'\r\n' in raw else '\n'
    text=raw.decode('utf-8').replace('\r\n','\n')
    candidate=replace_function(text,'series_external_source_rows',patch_series)
    candidate=replace_function(candidate,'_external_resolved_url',patch_resolver)
    candidate=replace_function(candidate,'series_external_choice_streams',patch_choices)
    assert candidate.count('def series_external_source_rows(')==1
    candidate=candidate.replace('def series_external_source_rows(',HELPERS+'def series_external_source_rows(',1)
    ast.parse(candidate)
    before={n.name:ast.dump(n,include_attributes=False) for n in ast.parse(text).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
    after={n.name:ast.dump(n,include_attributes=False) for n in ast.parse(candidate).body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
    changed={k for k in before if before[k]!=after[k]}
    assert changed=={'series_external_source_rows','series_external_choice_streams','_external_resolved_url'}, changed
    directory.mkdir(parents=True,exist_ok=True)
    (directory/'baseline-stremio_catalog.py').write_bytes(raw)
    output=directory/'stremio_catalog.py'
    output.write_bytes(candidate.replace('\n',newline).encode('utf-8'))
    patch=''.join(difflib.unified_diff(text.splitlines(True),candidate.splitlines(True),fromfile='a/stremio_catalog.py',tofile='b/stremio_catalog.py'))
    (directory/'episode-identity.patch').write_text(patch,encoding='utf-8')
    report={'status':'staged','baseSha256':BASE_SHA,'candidateSha256':hashlib.sha256(output.read_bytes()).hexdigest(),'changedFunctions':sorted(changed),'addedFunctions':sorted(set(after)-set(before))}
    (directory/'stage-result.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report))

if __name__=='__main__':stage(*sys.argv[1:])
