"""Bounded public metadata reads. No keys, accounts, streams or acquisition endpoints."""
import json,re,time
from discovery_policy import BASE,normalize
from feedback import rank_reviewed
from movie_presentation import normalize_info
class DiscoveryUnavailable(Exception):pass
class CinemetaDiscovery:
    def __init__(self,transport=None):self.transport=transport
    def get(self,path,deadline):
        if not re.fullmatch(r'/(?:catalog/movie/top/genre=(?:Thriller|Mystery|Action|Sci-Fi|Crime|Adventure|Horror)(?:&skip=\d{1,4})?|meta/movie/tt\d{5,12})\.json',path):raise DiscoveryUnavailable('Invalid metadata path')
        if self.transport:return self.transport(path)
        import requests
        remaining=deadline-time.monotonic()
        if remaining<=0:raise DiscoveryUnavailable('Metadata time budget reached')
        try:
            # Catalogs: request the pinned redirect target directly; the v3 host only issues a 307 and can stall.
            url='https://cinemeta-catalogs.strem.io/top'+path if path.startswith('/catalog/') else BASE+path
            r=requests.get(url,timeout=(min(3,remaining),min(10,remaining)),stream=True,allow_redirects=False)
            if r.status_code in (301,302,307,308) and path.startswith('/catalog/'):
                target='https://cinemeta-catalogs.strem.io/top'+path
                location=r.headers.get('Location');r.close()
                if location!=target:raise DiscoveryUnavailable('Unexpected metadata redirect')
                remaining=deadline-time.monotonic()
                if remaining<=0:raise DiscoveryUnavailable('Metadata time budget reached')
                r=requests.get(target,timeout=(min(3,remaining),min(10,remaining)),stream=True,allow_redirects=False)
            with r:
                if r.status_code!=200 or 'json' not in r.headers.get('Content-Type',''):raise DiscoveryUnavailable('Metadata provider unavailable')
                chunks=[];size=0
                for chunk in r.iter_content(16384):
                    size+=len(chunk)
                    if size>2_000_000 or time.monotonic()>deadline:raise DiscoveryUnavailable('Metadata response limit reached')
                    chunks.append(chunk)
                result=json.loads(b''.join(chunks))
                if not isinstance(result,dict):raise DiscoveryUnavailable('Invalid metadata response')
                return result
        except (requests.RequestException,ValueError) as exc:raise DiscoveryUnavailable('Metadata provider unavailable') from exc
    def discover(self,blocked,ratings,cursor=0):
        deadline=time.monotonic()+45;raw={};scanned=0
        for _ in range(4):
            genre=('Thriller','Horror','Action','Sci-Fi','Adventure','Mystery','Crime')[cursor%7];skip=(cursor//7%20)*50
            path='/catalog/movie/top/genre='+genre+('&skip='+str(skip) if skip else '')+'.json'
            data=self.get(path,deadline);metas=data.get('metas')
            if not isinstance(metas,list):raise DiscoveryUnavailable('Invalid catalog')
            cursor=(cursor+1)%140
            for m in metas[:100]:
                scanned+=1;row=normalize(m)
                if row and row['id'] not in blocked:raw[row['id']]=row
        ordered=rank_reviewed(list(raw.values()),ratings,limit=24);rows=[];verified=0;failed=0
        for candidate in ordered:
            if time.monotonic()>deadline:break
            imdb=candidate['id']
            try:data=self.get('/meta/movie/'+imdb+'.json',deadline)
            except DiscoveryUnavailable:
                failed+=1;continue # one slow/cold title must not sink the whole search
            verified+=1
            row=normalize(data.get('meta'))
            if row and row['id']==imdb and imdb not in blocked:
                # Catalog and detail are both evidence: conflicting excluded labels veto above.
                row['genres']=list(dict.fromkeys(candidate['genres']+row['genres']))
                row['discoveryEvidence']['genres']=row['genres']
                row=normalize(row['discoveryEvidence'],row['discoveryEvidence']['fetchedEpoch'])
                if row:
                    info=normalize_info(data.get('meta'),imdb)
                    if info:row['presentation']=info
                    rows.append(row)
            if len(rows)>=15:break
        if not rows and failed:raise DiscoveryUnavailable('Metadata provider unavailable')
        return {'movies':rows,'cursor':cursor,'scanned':scanned,'verified':verified,'failed':failed}
