"""HP worker and catalog adapters. Import never reads credentials or runs jobs."""
from dataclasses import asdict, replace
from pathlib import Path
import hashlib
import json
import math
import os
import sqlite3
import stat
import subprocess
import time
from movie_night import Choice, ROOT, ApprovalStore
import worker_candidate as worker


class ProviderInventory:
    def __init__(self, provider): self.provider = provider

    def verify(self, choice):
        data = self.provider._api('mylist', {'id': choice.torrent_id}, True)
        rows = data if isinstance(data, list) else [data]
        rows = [x for x in rows if isinstance(x,dict) and x.get('id') == choice.torrent_id]
        if len(rows)!=1 or rows[0].get('download_finished') is not True or rows[0].get('download_present') is not True:
            raise ValueError('provider file is not completed and present')
        files = [x for x in rows[0].get('files',[]) if x.get('id') == choice.file_id]
        if len(files)!=1 or files[0].get('infected') is not False or files[0].get('zipped') is not False:
            raise ValueError('provider file safety unavailable')
        file = files[0]
        return replace(choice, size=file.get('size'), provider_name=file.get('name')).validate()


def ffprobe(path):
    result = subprocess.run(['ffprobe','-v','error','-show_entries','format=duration:stream=codec_type,codec_name,width,height',
                             '-of','json',str(path)], capture_output=True, timeout=30, check=True)
    if len(result.stdout)>128000: raise ValueError('probe output limit')
    return json.loads(result.stdout)


def validate_file(path, choice, probe=ffprobe):
    """Validate completed bytes before publication, without modifying the file."""
    worker.safe_directory(path.parent)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size!=choice.size: raise ValueError('file size/type mismatch')
        digest=hashlib.sha256()
        while chunk:=os.read(fd,1024*1024): digest.update(chunk)
        data=probe(path)
        duration=float(data.get('format',{}).get('duration',0))
        if not math.isfinite(duration) or duration<=0: raise ValueError('invalid media duration')
        videos=[x for x in data.get('streams',[]) if x.get('codec_type')=='video']
        codec={'HEVC':'hevc','H.265':'hevc','AVC':'h264','H.264':'h264','AV1':'av1'}.get(choice.codec.upper())
        video=videos[0] if len(videos)==1 else {}
        width,height=video.get('width',0),video.get('height',0)
        full_hd=(type(width) is int and type(height) is int and 0<width<=1920 and 0<height<=1080 and (width==1920 or height==1080))
        if len(videos)!=1 or not codec or video.get('codec_name')!=codec or not full_hd:
            raise ValueError('confirmed quality/codec mismatch')
        after=os.stat(path,follow_symlinks=False)
        if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):
            raise ValueError('file changed during validation')
        return {'actualSize':choice.size,'sha256':digest.hexdigest(),'mediaProbePassed':True,'destination':choice.destination}
    finally: os.close(fd)


class MediaIndex:
    """Isolated index served through the existing catalog host, no library migration."""
    def __init__(self, db, root, storage_guard=None):
        self.db=Path(db);self.root=Path(root);self.storage_guard=storage_guard
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE IF NOT EXISTS media (id TEXT PRIMARY KEY, filename TEXT UNIQUE, metadata TEXT, size INTEGER, sha TEXT, visible INTEGER NOT NULL DEFAULT 0)')
            if 'visible' not in {x[1] for x in c.execute('PRAGMA table_info(media)')}:
                raise ValueError('Preserve old index; select a new isolated index path')

    def removed_ids(self):
        # Read tombstones even with destructive endpoints disabled.
        with sqlite3.connect(f"file:{self.db}?mode=ro", uri=True) as c:
            if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='removed_media'").fetchone():
                return set()
            return {row[0] for row in c.execute('SELECT id FROM removed_media')}

    def require_not_removed(self, imdb):
        if imdb in self.removed_ids():
            raise ValueError('Owner intentionally removed server copy; no automatic re-download')

    def register(self, choice, proof):
        if self.storage_guard:self.storage_guard()
        path=self.root/'Movies'/Path(choice.destination).name
        if path.is_symlink() or not path.is_file() or path.stat().st_size!=choice.size:
            raise ValueError('published file missing')
        worker.safe_directory(path.parent)
        with sqlite3.connect(self.db) as c:
            if c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='removed_media'").fetchone() and c.execute(
                'SELECT 1 FROM removed_media WHERE id=?',(choice.imdb,)).fetchone():
                raise ValueError('Owner intentionally removed server copy; no automatic re-download')
            existing=c.execute('SELECT filename,size,sha FROM media WHERE id=?',(choice.imdb,)).fetchone()
            expected=(path.name,choice.size,proof['sha256'])
            if existing and existing!=expected: raise ValueError('index conflict; preserve existing entry')
            c.execute('INSERT OR IGNORE INTO media VALUES (?,?,?,?,?,0)',(choice.imdb,path.name,json.dumps(asdict(choice)),choice.size,proof['sha256']))
        return {'catalogId':choice.imdb,'existingRouteVerified':False}

    def resolve(self, imdb, include_pending=False):
        if self.storage_guard:self.storage_guard()
        with sqlite3.connect(self.db) as c:
            row=c.execute('SELECT filename,size,visible FROM media WHERE id=?',(imdb,)).fetchone()
        if not row: return None
        if not row[2] and not include_pending:return None
        path=self.root/'Movies'/row[0]
        worker.safe_directory(path.parent)
        if path.is_symlink() or not path.is_file() or path.stat().st_size!=row[1]: return None
        return path

    def publish(self, imdb):
        if not self.resolve(imdb,include_pending=True):raise ValueError('Validated file unavailable')
        with sqlite3.connect(self.db) as c:c.execute('UPDATE media SET visible=1 WHERE id=?',(imdb,))

    def metas(self):
        with sqlite3.connect(self.db) as c: rows=c.execute('SELECT id,metadata FROM media ORDER BY rowid DESC').fetchall()
        return [{'id':i,'type':'movie','name':json.loads(m)['title'],'releaseInfo':str(json.loads(m)['year'])} for i,m in rows if self.resolve(i)]


class WorkerAdapter:
    def __init__(self, db, root, state, provider, index, *, enabled=False,
                 open_media=worker.https_get, free=None, probe=ffprobe, verify_route=None, storage_guard=None):
        self.db,self.root,self.state=Path(db),Path(root),Path(state)
        self.provider,self.index=provider,index
        self.enabled,self.open_media,self.free,self.probe=enabled,open_media,free,probe
        self.verify_route=verify_route;self.storage_guard=storage_guard

    def _store(self): return ApprovalStore(self.db)

    def run(self, pid):
        if not self.enabled: raise ValueError('download activation is disabled')
        store=self._store(); owned=False
        try:
            row=store.db.execute('SELECT payload,state FROM jobs WHERE id=?',(pid,)).fetchone()
            if not row or row[1]!='approved': raise ValueError('job is not newly approved')
            # Claim once under SQLite's writer lock. A second dispatcher cannot run it.
            with store.db:
                claimed=store.db.execute("UPDATE jobs SET state='downloading' WHERE id=? AND state='approved'",(pid,)).rowcount
            if claimed!=1: raise ValueError('job already claimed')
            owned=True
            choice=Choice(**json.loads(row[0])['choice']).validate()
            # Reject stale jobs before provider resolution or transfer.
            self.index.require_not_removed(choice.imdb)
            if self.storage_guard:self.storage_guard()
            def cancelled():
                return bool(store.db.execute('SELECT 1 FROM cancellations WHERE id=?',(pid,)).fetchone())
            proof={}
            def validate(destination,partial,entry):
                if self.storage_guard:self.storage_guard()
                proof.update(validate_file(partial,choice,self.probe))
            last=[0.0]
            def progress(count):
                now=time.monotonic()
                if now-last[0]>=1 or count==choice.size:
                    if self.storage_guard:self.storage_guard()
                    store.transition(pid,'downloading',bytes_received=count);last[0]=now
            manifest={'approved':True,'files':[{'canonicalId':choice.imdb,'torrentId':choice.torrent_id,'fileId':choice.file_id,
                      'providerName':choice.provider_name,'sizeBytes':choice.size,'editionConfirmed':True,
                      'destination':'Movies/'+Path(choice.destination).name}]}
            args={'open_media':self.open_media,'progress':progress,'cancelled':cancelled,'validate_complete':validate}
            if self.free: args['free']=self.free
            worker.run(manifest,self.root,self.state,self.provider,**args)
            store.transition(pid,'downloaded',bytes_received=choice.size,evidence=proof)
            self.index.register(choice,proof)
            # Actual route verification must succeed before reporting indexed.
            if self.verify_route and self.verify_route(choice.imdb,choice.size):
                self.index.publish(choice.imdb)
                store.transition(pid,'indexed',evidence={'catalogId':choice.imdb,'existingRouteVerified':True})
            return store.status(pid)
        except Exception:
            status=store.status(pid)
            if owned and status and status['state'] in {'approved','downloading'}:
                cancelled_flag=bool(store.db.execute('SELECT 1 FROM cancellations WHERE id=?',(pid,)).fetchone())
                store.transition(pid,'cancelled' if cancelled_flag else 'failed')
            # No exception text: provider errors may include signed URLs.
            return store.status(pid) or {'state':'failed'}
        finally: store.db.close()
