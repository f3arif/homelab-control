"""Read-only discovery in the existing completed TorBox inventory.
No provider torrent creation, source replacement or media-link request at lookup time.
"""
from pathlib import Path
import re, threading, time, unicodedata
from movie_night import Choice, ROOT, CAP
from adapters import ProviderInventory
import worker_candidate as worker

def norm(value):
    return re.sub(r'[^a-z0-9]+',' ',unicodedata.normalize('NFKD',str(value)).encode('ascii','ignore').decode().lower()).strip()

class ConfiguredProvider:
    def __init__(self): self.instance=None; self.lock=threading.Lock()
    def get(self):
        with self.lock:
            if self.instance is None: self.instance=worker.Provider(worker.existing_key())
            return self.instance
    def _api(self,*a,**kw): return self.get()._api(*a,**kw)
    def add_cached(self,*a,**kw):return self.get().add_cached(*a,**kw)
    def resolve(self,*a,**kw): return self.get().resolve(*a,**kw)

class InventoryChoices:
    def __init__(self, provider, payload, clock=time.time):
        self.provider,self.payload,self.clock=provider,payload,clock
        self.lock=threading.Lock();self.rows=[];self.checked=0;self.complete=False
    def refresh(self):
        with self.lock:
            if self.clock()-self.checked<60: return self.rows,self.complete
            rows=[]; seen=set();complete=False
            for offset in range(0,2000,25):
                page=self.provider._api('mylist',{'limit':25,'offset':offset},True)
                if not isinstance(page,list): raise ValueError('Provider inventory unavailable')
                for row in page:
                    if not isinstance(row,dict) or type(row.get('id')) is not int or row['id'] in seen:continue
                    seen.add(row['id']);rows.append(row)
                if len(page)<25:complete=True;break
            self.rows,self.complete,self.checked=rows,complete,self.clock()
            return rows,complete
    def __call__(self,imdb):
        movies=[x for x in self.payload().get('movies',[]) if x.get('id')==imdb]
        if len(movies)!=1:return []
        m=movies[0];title=norm(m['name']);year=str(m['year'])
        rows,complete=self.refresh()
        return self.parse(m,rows,complete)

    @staticmethod
    def parse(m,rows,complete=True):
        imdb=m["id"];title=norm(m["name"]);year=str(m["year"]);result=[]
        for row in rows:
            if row.get('download_finished') is not True or row.get('download_present') is not True:continue
            for f in row.get('files',[]):
                name=f.get('name','');short=str(f.get('short_name') or name);package=str(row.get('name') or '')
                if not isinstance(name,str) or f.get('infected') is not False or f.get('zipped') is not False:continue
                suffix=Path(name).suffix.lower()
                if suffix not in ('.mkv','.mp4'):continue
                # Feature identity requires title then exact release year in the file itself.
                label=norm(Path(short).name)
                if not (label.startswith(title+' '+year+' ') or label==title+' '+year):continue
                text=short+' '+package
                if re.search(r'(?i)(?:sample|trailer|2160p|720p|remux|\bs\d{1,2}e\d{1,3}\b)',text):continue
                if not re.search(r'(?i)(?<!\d)1080p(?!\d)',text):continue
                size=f.get('size')
                if type(size) is not int or not 0<size<=CAP or (size>5_000_000_000 and not complete):continue
                codec=next((c for c,p in [('HEVC',r'(?i)(?:hevc|[xh][ .]?265)'),('AVC',r'(?i)(?:avc|[xh][ .]?264)'),('AV1',r'(?i)\bav0?1\b')] if re.search(p,text)),None)
                if not codec:continue
                flags=[word for word in ('extended','unrated','remastered','directors cut','theatrical') if word in norm(text)]
                edition=', '.join(flags) or 'Edition as named by provider'
                try:
                    result.append(Choice(imdb,m['name'],m['year'],edition,'torbox',row['id'],f['id'],name,'1080p',codec,size,ROOT+'/'+imdb+'.'+year+suffix).validate())
                except (ValueError,TypeError,KeyError):continue
        return result

