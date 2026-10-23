"""Single-flight discovery and atomic inventory; isolated from media acquisition."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import fcntl,hashlib,json,os,sqlite3,tempfile,threading,time
from pathlib import Path
from reviewed_refill import ReviewedRefill
from publish_reviewed import read_json,validate_rows,inspect_state
from feedback import FeedbackStore,rank_reviewed
from seen_policy import KNOWN_SEEN_IDS
from metadata_discovery import DiscoveryUnavailable
from movie_night import shortlist

def atomic_json(path,data):
    encoded=(json.dumps(data,ensure_ascii=False,indent=2)+'\n').encode()
    if len(encoded)>262144:raise ValueError('Inventory too large')
    fd,name=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(encoded);f.flush();os.fsync(f.fileno())
        os.replace(name,path)
        fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if os.path.exists(name):os.unlink(name)

class DiscoveryRefill(ReviewedRefill):
    automatic=True
    def __init__(self,state,discoverer):
        super().__init__(state);self.discoverer=discoverer;self.lock=threading.RLock()
        self.pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix='movie-metadata');self.future=None
        self.path=self.state/'discovery-status.json'
    def close(self):self.pool.shutdown(wait=True)
    def saved_status(self):
        try:return read_json(self.path)[1]
        except (OSError,ValueError):return {}
    def status(self):
        with self.lock:
            saved=self.saved_status();running=bool(self.future and not self.future.done())
            result=super().status();result.update(discoveryEnabled=True,running=running,
                outcome='searching' if running else ('interrupted' if saved.get('outcome')=='searching' else saved.get('outcome','ready')),
                retryAfter=max(0,int(saved.get('retryAt',0)-time.time())),added=saved.get('added',0),scanned=saved.get('scanned',0))
            return result
    LOW=15 # start a background search when fewer fresh titles than this are buffered
    def visible_count(self):
        _,current=read_json(self.state/'reviewed-shortlist.json');snap=inspect_state(self.state)
        blocked={r['id'] for r in snap['ratings'] if r['value'] in ('dislike','seen')}|set(snap['knownSeenIds'])
        return len({r['id'] for r in shortlist(current,int(time.time()),limit=None)}-blocked)
    def maintain(self):
        """Keep five cards from the local bank at once; top up the bank in the background when low."""
        with self.lock:
            if self.future and not self.future.done():return
            saved=self.saved_status()
            try:
                if self.visible_count()<5:
                    result=super().fulfill()
                    if result.get('fulfilled'):saved.update(outcome='refilled',added=result['added'],retryAt=0);atomic_json(self.path,saved)
                available=super().status().get('available',0)
            except (OSError,ValueError,KeyError,sqlite3.Error):available=0
            if available<self.LOW and saved.get('retryAt',0)<=time.time():
                saved.update(outcome='searching',attemptedEpoch=time.time());atomic_json(self.path,saved)
                self.future=self.pool.submit(self._discover)
    def duplicate(self,request_id):
        with self.lock:return bool(request_id and request_id in self.saved_status().get('requestIds',[]))
    def request(self,request_id=None):
        with self.lock:
            saved=self.saved_status()
            if self.duplicate(request_id) or self.future and not self.future.done():return
            if saved.get('retryAt',0)>time.time():return
            if request_id:saved['requestIds']=(saved.get('requestIds',[])+[request_id])[-64:]
            # Existing bank remains the fastest path; network discovery follows exhaustion.
            result=super().fulfill()
            if result.get('fulfilled'):
                saved.update(outcome='refilled',added=result['added'],retryAt=0);atomic_json(self.path,saved);return
            saved.update(outcome='searching',attemptedEpoch=time.time());atomic_json(self.path,saved)
            self.future=self.pool.submit(self._discover)
    def _discover(self):
        try:
            with (self.state/'.discovery.lock').open('a') as flight:
                fcntl.flock(flight,fcntl.LOCK_EX|fcntl.LOCK_NB)
                self._run()
        except Exception:
            # Provider details and exception strings stay out of the owner UI.
            with self.lock:
                saved=self.saved_status();saved.update(outcome='provider-unavailable',retryAt=time.time()+60);atomic_json(self.path,saved)
    def _run(self):
        raw,current=read_json(self.state/'reviewed-shortlist.json');expected=hashlib.sha256(raw).hexdigest()
        snapshot=inspect_state(self.state)
        blocked=set(current.get('publishedHistoryIds',[])) | {r['id'] for r in current.get('movies',[])} | set(snapshot['knownSeenIds']) | set(KNOWN_SEEN_IDS)
        blocked.update(r['id'] for r in snapshot['ratings'] if r['value'] in ('dislike','seen'))
        ratings={r['id']:{'value':r['value'],'metadata':r['metadata']} for r in snapshot['ratings']}
        saved=self.saved_status();result=self.discoverer.discover(blocked,ratings,saved.get('cursor',0))
        now=int(time.time());rows=result['movies']
        if rows:validate_rows({'generatedEpoch':now,'movies':rows},now,minimum=1)
        with self.lock:
            # Publication must never overwrite a newer weekly/manual update.
            if hashlib.sha256((self.state/'reviewed-shortlist.json').read_bytes()).hexdigest()!=expected:
                saved=self.saved_status();saved.update(outcome='state-changed',retryAt=0);atomic_json(self.path,saved);return
            if not rows:
                saved=self.saved_status();saved.update(outcome='no-match',cursor=result['cursor'],scanned=result['scanned'],added=0,retryAt=time.time()+60);atomic_json(self.path,saved);return
            self._publish_bank(rows,now,expected)
            receipt=super().fulfill(expected_hash=expected) if self.visible_count()<5 else {'fulfilled':False,'added':0,'buffered':len(rows)}
            saved=self.saved_status();saved.update(outcome='refilled' if receipt.get('fulfilled') else ('ready' if 'buffered' in receipt else 'state-changed'),
                cursor=result['cursor'],scanned=result['scanned'],added=receipt.get('added',0),retryAt=0)
            atomic_json(self.path,saved)
    def _publish_bank(self,rows,now,expected):
        target=self.state/'reviewed-refill-bank.json'
        with (self.state/'.publisher.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if hashlib.sha256((self.state/'reviewed-shortlist.json').read_bytes()).hexdigest()!=expected:raise ValueError('Concurrent shortlist change')
            current=inspect_state(self.state);blocked=set(current['knownSeenIds']) | {r['id'] for r in current['ratings'] if r['value'] in ('dislike','seen')}
            oldraw=None;old={};keep=[]
            if target.exists():
                if target.is_symlink():raise ValueError('Symlink bank rejected')
                oldraw,old=read_json(target)
                try:validate_rows(old,now,minimum=1,max_age=7*86400);keep=old['movies']
                except ValueError:pass
            merged={r['id']:r for r in keep+rows if r['id'] not in blocked}
            # Preserve already published IDs in shortlist history; they need not occupy bank space.
            payload=read_json(self.state/'reviewed-shortlist.json')[1]
            used=set(payload.get('publishedHistoryIds',[])) | {r['id'] for r in payload.get('movies',[])}
            merged=[r for i,r in merged.items() if i not in used][:100]
            bank={'generatedEpoch':min(now,old['generatedEpoch']) if keep else now,'knownSeenIds':sorted(set(current['knownSeenIds'])|set(old.get('knownSeenIds',[]))),'movies':merged}
            validate_rows(bank,now,minimum=1,max_age=7*86400)
            if oldraw:
                backups=self.state/'publication-backups';backups.mkdir(mode=0o700,exist_ok=True)
                backup=backups/('bank-'+hashlib.sha256(oldraw).hexdigest()+'.json')
                if not backup.exists():
                    with backup.open('xb') as f:os.chmod(backup,0o600);f.write(oldraw)
            atomic_json(target,bank)
