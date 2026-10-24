"""Find a cached file through the owner's existing Comet/TorBox setup.

Only explicit queued finalization calls acquire(). Discovery never opens a
playback URL. Cache metadata is tentative until fresh account-file validation.
Credentials and returned addon URLs stay in memory.
"""
from pathlib import Path
from urllib.parse import urlsplit
import json
import re
import time
from download_provider import InventoryChoices
from movie_night import select_compact
import worker_candidate as worker


def configured_comet(path=worker.CONFIG):
    found=set()
    for addon in json.loads(Path(path).read_text()).get('addons',[]):
        value=addon.get('transportUrl') or addon.get('transportURL') or ''
        u=urlsplit(value)
        if (u.scheme=='https' and u.hostname=='comet.elfhosted.com' and u.port in (None,443)
                and not u.username and not u.password and not u.query and not u.fragment
                and u.path.endswith('/manifest.json')):
            found.add(value.removesuffix('/manifest.json'))
    if len(found)!=1:raise ValueError('configured source unavailable')
    return found.pop()


class CachedSources:
    def __init__(self,provider,payload,*,endpoint=configured_comet,opener=worker.https_get,sleep=time.sleep):
        self.provider,self.payload,self.endpoint,self.opener,self.sleep=provider,payload,endpoint,opener,sleep

    def candidates(self,imdb):
        movies=[m for m in self.payload().get('movies',[]) if m.get('id')==imdb]
        if len(movies)!=1 or not re.fullmatch(r'tt\d+',imdb):return []
        movie=movies[0]
        with self.opener(self.endpoint()+'/stream/movie/'+imdb+'.json') as response:
            raw=response.read(2_000_001)
            if len(raw)>2_000_000:raise ValueError('source response too large')
            streams=json.loads(raw).get('streams',[])
        if not isinstance(streams,list):raise ValueError('source response invalid')
        hashes=[]
        for stream in streams[:500]:
            if not isinstance(stream,dict):continue
            hint=stream.get('behaviorHints') or {}
            group=hint.get('bingeGroup','') if isinstance(hint,dict) else ''
            match=re.fullmatch(r'comet\|torbox\|([a-fA-F0-9]{40})',str(group))
            info_hash=match[1] if match else stream.get('infoHash','')
            if not isinstance(info_hash,str) or not re.fullmatch('[a-fA-F0-9]{40}',info_hash):continue
            if info_hash.lower() not in hashes:hashes.append(info_hash.lower())
        complete=len(hashes)<=200 and len(streams)<=500
        hashes=hashes[:200]
        if not hashes:return []
        cache={}
        for offset in range(0,len(hashes),100):
            page=self.provider._api('checkcached',{'hash':','.join(hashes[offset:offset+100]),'format':'object','list_files':'true'},True)
            if not isinstance(page,dict):raise ValueError('cache response invalid')
            cache.update(page)
        choices=[]
        for info_hash in hashes:
            cached=cache.get(info_hash)
            if not isinstance(cached,dict) or cached.get('hash')!=info_hash:continue
            # Cache files have no account IDs or safety fields. Synthetic IDs and
            # safety flags are used ONLY to apply the shared filename/size ranking.
            # They can never be returned to the download worker.
            files=[dict(f,id=n,infected=False,zipped=False) for n,f in enumerate(cached.get('files',[])) if isinstance(f,dict)]
            row=dict(id=0,name=cached.get('name',''),files=files,download_finished=True,download_present=True)
            for choice in InventoryChoices.parse(movie,[row],complete):choices.append((info_hash,choice))
        return choices

    def acquire(self,imdb,guard):
        candidates=self.candidates(imdb)
        best=select_compact([c for _,c in candidates])
        if best is None:return None
        info_hash=next(h for h,c in candidates if c==best)
        guard(best.size)
        # Provider itself enforces cached-only, closing a check/add cache race.
        # Never retry an ambiguous POST or open the addon's playback URL.
        torrent_id=self.provider.add_cached(info_hash)
        movie=next(m for m in self.payload().get('movies',[]) if m.get('id')==imdb)
        for attempt in range(8):
            guard(best.size)
            data=self.provider._api('mylist',{'id':torrent_id,'bypass_cache':'true'},True)
            rows=data if isinstance(data,list) else [data]
            rows=[r for r in rows if isinstance(r,dict) and r.get('id')==torrent_id and r.get('hash')==info_hash]
            for choice in InventoryChoices.parse(movie,rows):
                if (choice.provider_name,choice.size,choice.quality,choice.codec)==(best.provider_name,best.size,best.quality,best.codec):
                    return choice
            if rows and rows[0].get('download_finished') is True and rows[0].get('download_present') is True:
                raise ValueError('cached file changed')
            if attempt<7:self.sleep(1)
        raise ValueError('cached file not ready')
