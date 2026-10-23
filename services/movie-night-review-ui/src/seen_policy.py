"""Fresh, read-only seen exclusions. Restored from the recorded October 5 patch."""
import re
KNOWN_SEEN_IDS=frozenset({'tt28015403','tt26584495'})
KNOWN_SEEN_NAMES=frozenset({'heretic','companion'})
RECOMMENDATION_CATALOGS=frozenset({'afz_for_you','afz_movie_night','downloaded_unwatched','netflix_top_movies_ca','netflix_top_thrillers_ca','new_digital','action_thriller','scifi_fantasy','bluray_4k','hindi_bollywood','afz_hindi','afz_trending_movies','imdb_movies_status','popular_movies_status','einthusan_hindi_status'})
def canonical_id(row):
    for key in ('canonicalId','imdbId','imdb_id','id'):
        value=row.get(key)
        if isinstance(value,str):
            match=re.fullmatch(r'(?:imdb:)?(tt\d+)',value.strip())
            if match:return match[1]
    return None
class SeenPolicy:
    def __init__(self,snapshot=None):
        self.snapshot=snapshot or (lambda:{'states':{},'complete':False})
        self.complete=False;self.last_known=set()
    def filter(self,rows):
        rows=[r for r in rows if isinstance(r,dict)]
        try:
            state=self.snapshot();states=state.get('states',{})
            if not isinstance(states,dict):raise ValueError('invalid seen state')
            blocked={canonical_id({'id':k}) for k,v in states.items() if v is True}
            self.last_known=set(blocked);self.complete=state.get('complete') is True
        except (OSError,ValueError,TypeError,AttributeError):
            blocked=set(self.last_known);self.complete=False
        blocked.update(KNOWN_SEEN_IDS)
        blocked.update(canonical_id(r) for r in rows if r.get('seen') is True or str(r.get('name','')).strip().casefold() in KNOWN_SEEN_NAMES)
        blocked.discard(None);output=[];emitted=set()
        for row in rows:
            imdb=canonical_id(row)
            if row.get('seen') is True or str(row.get('name','')).strip().casefold() in KNOWN_SEEN_NAMES:continue
            if imdb in blocked or (imdb is not None and imdb in emitted):continue
            output.append(dict(row,id=imdb) if imdb else row)
            if imdb:emitted.add(imdb)
        return output
def attach_recommendation_filter(core,policy):
    if not hasattr(core,'_catalog_full_metas') or not hasattr(core,'_catalog_response'):return False
    original=core._catalog_full_metas;response=core._catalog_response
    def recommended(cid):
        if cid in RECOMMENDATION_CATALOGS:return True
        overflow=core.parse_overflow_catalog_id(cid) if hasattr(core,'parse_overflow_catalog_id') else None
        return bool(overflow and overflow[0] in RECOMMENDATION_CATALOGS)
    def full(cid):
        rows=original(cid)
        return policy.filter(rows) if recommended(cid) else rows
    def rendered(cid,target,skip=0):
        result=response(cid,target,skip)
        if recommended(cid):
            target.headers['Cache-Control']='private, no-store, max-age=0'
            for name in ('etag','last-modified','expires'):
                if name in target.headers:del target.headers[name]
        return result
    core._catalog_full_metas=full;core._catalog_response=rendered
    return True
