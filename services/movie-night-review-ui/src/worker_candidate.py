"""Reviewed one-shot acquisition candidate. Default CLI is offline validation.
Execution requires recorded owner authorization; credentials and signed URLs remain RAM-only.
"""
import argparse, base64, contextlib, fcntl, hashlib, http.client, ipaddress
import json, os, re, shutil, socket, ssl, time
from pathlib import Path
from urllib.parse import urlsplit, unquote, urlencode

MAX_BYTES = 100_000_000_000
RESERVE = 50 * 1024**3
CONFIG = Path('/home/coolyo/afz-stremio-secondhost-20260918/private/addon-collection-private.json')
class Rejected(Exception): pass

def validate_manifest(m):
    if m.get('approved') is not True: raise Rejected('manifest-not-approved')
    rows=m.get('files');seen=set();ids=set();provider_ids=set();cost=0
    if not isinstance(rows,list) or not 1<=len(rows)<=72: raise Rejected('empty-manifest')
    for row in rows:
        if any(type(row.get(k)) is not int or row[k]<0 for k in ('torrentId','fileId')): raise Rejected('missing-provider-identity')
        size=row.get('sizeBytes')
        if type(size) is not int or size<=0: raise Rejected('unknown-size')
        cid=row.get('canonicalId','')
        if not re.fullmatch(r'tt\d+(?::\d+:\d+)?',cid): raise Rejected('canonical-id')
        if ':' not in cid and size>9_000_000_000: raise Rejected('movie-over-nine-billion')
        rel=row.get('destination','');p=Path(rel)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0] not in ('Movies','TV') or '\\' in rel: raise Rejected('unsafe-destination')
        if p.parts[0]!=('TV' if ':' in cid else 'Movies'): raise Rejected('media-kind-destination')
        if p.suffix.lower() not in ('.mkv','.mp4','.m4v','.avi'): raise Rejected('non-media')
        identity=(row['torrentId'],row['fileId'])
        if rel.casefold() in seen or cid in ids or identity in provider_ids: raise Rejected('duplicate-target')
        seen.add(rel.casefold());ids.add(cid);provider_ids.add(identity)
        if not isinstance(row.get('providerName'),str) or not row['providerName']: raise Rejected('missing-filename')
        if row.get('editionConfirmed') is not True: raise Rejected('edition-unconfirmed')
        cost+=size+1 # reserve an EOF check byte; failed attempts are never retried
    if cost>MAX_BYTES: raise Rejected('batch-budget')
    return rows,cost

def existing_key(path=CONFIG):
    # Not invoked by dry-run, tests, installer or import.
    keys=set()
    for a in json.loads(path.read_text()).get('addons',[]):
        u=urlsplit(a.get('transportUrl') or a.get('transportURL') or '')
        if u.scheme!='https' or u.hostname!='comet.elfhosted.com': continue
        for p in u.path.split('/'):
            try:
                p=unquote(p);c=json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))
                if c.get('debridService')=='torbox' and isinstance(c.get('debridApiKey'),str) and c['debridApiKey']: keys.add(c['debridApiKey'])
            except (ValueError,TypeError,UnicodeError): pass
    if len(keys)!=1: raise Rejected('configured-credential-unavailable-or-ambiguous')
    return keys.pop()

@contextlib.contextmanager
def https_request(url,headers=None,allowed_statuses=(200,),method="GET",body=None):
    u=urlsplit(url)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.fragment or u.port not in (None,443): raise Rejected('unsafe-provider-url')
    addresses={x[4][0] for x in socket.getaddrinfo(u.hostname,443,type=socket.SOCK_STREAM)}
    if not addresses or any(not ipaddress.ip_address(a).is_global for a in addresses): raise Rejected('non-public-provider-target')
    # Pin the checked address; retain TLS hostname validation and SNI.
    conn=http.client.HTTPSConnection(u.hostname,443,timeout=15,context=ssl.create_default_context())
    raw=socket.create_connection((sorted(addresses)[0],443),timeout=15)
    try:
        conn.sock=conn._context.wrap_socket(raw,server_hostname=u.hostname)
        conn.request(method,u.path+('?' +u.query if u.query else ''),body=body,headers={'Accept-Encoding':'identity',**(headers or {})})
        response=conn.getresponse()
        if response.status not in allowed_statuses: raise Rejected('provider-http-status') # no redirects/retries
        yield response
    finally:
        conn.close();raw.close()

def https_get(url,headers=None,allowed_statuses=(200,)):
    return https_request(url,headers,allowed_statuses)

class Provider:
    def __init__(self,key): self.__key=key
    def _api(self,endpoint,query,bearer=False):
        headers={'Authorization':'Bearer '+self.__key} if bearer else {}
        with https_get('https://api.torbox.app/v1/api/torrents/'+endpoint+'?'+urlencode(query),headers) as response:
            data=response.read(2_000_001)
            if len(data)>2_000_000: raise Rejected('api-response-limit')
            obj=json.loads(data)
            if obj.get('success') is not True: raise Rejected('provider-api-failure')
            return obj.get('data')
    def add_cached(self,info_hash):
        if not isinstance(info_hash,str) or not re.fullmatch('[a-f0-9]{40}',info_hash):raise Rejected('invalid-source-hash')
        from uuid import uuid4
        boundary='afz-'+uuid4().hex
        fields={'magnet':'magnet:?xt=urn:btih:'+info_hash,'seed':'3','allow_zip':'false','add_only_if_cached':'true'}
        body=(''.join('--'+boundary+'\r\nContent-Disposition: form-data; name="'+k+'"\r\n\r\n'+v+'\r\n' for k,v in fields.items())+'--'+boundary+'--\r\n').encode()
        headers={'Authorization':'Bearer '+self.__key,'Content-Type':'multipart/form-data; boundary='+boundary}
        with https_request('https://api.torbox.app/v1/api/torrents/createtorrent',headers,method='POST',body=body) as response:
            raw=response.read(2_000_001)
            if len(raw)>2_000_000:raise Rejected('api-response-limit')
            result=json.loads(raw)
            if result.get('success') is not True:raise Rejected('cached-source-add-failed')
            data=result.get('data') or {};tid=data.get('torrent_id')
            if type(tid) is not int or tid<0:raise Rejected('provider-identity-missing')
            return tid
    def resolve(self,row):
        data=self._api('mylist',{'id':row['torrentId']},True)
        torrents=data if isinstance(data,list) else [data]
        torrents=[x for x in torrents if isinstance(x,dict) and x.get('id')==row['torrentId']]
        if len(torrents)!=1: raise Rejected('provider-identity-mismatch')
        t=torrents[0]
        if t.get('download_finished') is not True or t.get('download_present') is not True: raise Rejected('not-completed-present')
        matches=[f for f in t.get('files',[]) if f.get('id')==row['fileId']]
        if len(matches)!=1: raise Rejected('provider-file-mismatch')
        f=matches[0]
        if f.get('name')!=row['providerName'] or f.get('size')!=row['sizeBytes'] or f.get('infected') is not False or f.get('zipped') is not False: raise Rejected('provider-metadata-mismatch')
        url=self._api('requestdl',{'token':self.__key,'torrent_id':row['torrentId'],'file_id':row['fileId'],'redirect':'false'})
        if not isinstance(url,str): raise Rejected('missing-temporary-link')
        return url

def safe_directory(path,create=False):
    path=Path(path).absolute()
    for part in reversed([path,*path.parents]):
        if part.is_symlink(): raise Rejected('symlink-directory')
        if not part.exists():
            if not create: raise Rejected('directory-missing')
            part.mkdir(mode=0o700)
        if not part.is_dir(): raise Rejected('not-directory')
    return path

@contextlib.contextmanager
def job_lock(state):
    state=safe_directory(state)
    fd=os.open(state/'worker.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise Rejected('worker-already-running')
        yield
    finally: os.close(fd)

@contextlib.contextmanager
def parent_fd(root,relative):
    safe_directory(root)
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        for part in Path(relative).parts[:-1]:
            try:os.mkdir(part,mode=0o700,dir_fd=fd)
            except FileExistsError:pass
            child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=child
        yield fd,Path(relative).name
    except OSError:raise Rejected('unsafe-or-unavailable-parent') from None
    finally:os.close(fd)

def exists_at(fd,name):
    try:os.stat(name,dir_fd=fd,follow_symlinks=False);return True
    except FileNotFoundError:return False

def run(m,root,state,provider,open_media=https_get,free=lambda p:shutil.disk_usage(p).free, progress=None, cancelled=None, validate_complete=None):
    rows,cost=validate_manifest(m);root=safe_directory(root);state=safe_directory(state)
    receipt={'completed':[],'mediaBytes':0,'budgetBytes':cost,'status':'running'}
    batch_deadline=time.monotonic()+28800
    with job_lock(state):
        for row in rows:
            with parent_fd(root,row['destination']) as (directory,name):
                if exists_at(directory,name) or exists_at(directory,name+'.part'):raise Rejected('destination-exists')
        try:
            for row in rows:
                size=row['sizeBytes']
                if free(root)<RESERVE+size:raise Rejected('storage-reserve')
                with parent_fd(root,row['destination']) as (directory,name):
                    if exists_at(directory,name) or exists_at(directory,name+'.part'):raise Rejected('destination-exists')
                    if cancelled and cancelled(): raise Rejected('cancelled')
                    url=provider.resolve(row)
                    safe_directory((root/row['destination']).parent)
                    fd=os.open(name+'.part',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600,dir_fd=directory)
                    with os.fdopen(fd,'wb') as output,open_media(url) as response:
                        if str(response.headers.get('Content-Length',''))!=str(size) or response.headers.get('Content-Encoding','identity')!='identity':raise Rejected('media-length-or-encoding')
                        left=size;deadline=min(time.monotonic()+7200,batch_deadline)
                        while left:
                            if cancelled and cancelled(): raise Rejected('cancelled')
                            if time.monotonic()>deadline:raise Rejected('transfer-deadline')
                            chunk=response.read(min(65536,left));receipt['mediaBytes']+=len(chunk)
                            if not chunk or len(chunk)>left:raise Rejected('media-truncated-or-oversized')
                            output.write(chunk);left-=len(chunk)
                            if progress: progress(receipt['mediaBytes'])
                        extra=response.read(1);receipt['mediaBytes']+=len(extra)
                        if extra:raise Rejected('media-oversized')
                        output.flush();os.fsync(output.fileno())
                    if cancelled and cancelled(): raise Rejected('cancelled')
                    if validate_complete: validate_complete(root/row['destination'], root/str(row['destination']+'.part'), row)
                    os.link(name+'.part',name,src_dir_fd=directory,dst_dir_fd=directory,follow_symlinks=False)
                    os.unlink(name+'.part',dir_fd=directory);os.fsync(directory)
                    receipt['completed'].append({'canonicalId':row['canonicalId'],'destination':row['destination'],'bytes':size})
                    write_receipt(state,receipt)
        except Exception:
            receipt['status']='stopped';write_receipt(state,receipt);raise Rejected('transfer-stopped-partial-preserved') from None
        receipt['status']='completed';write_receipt(state,receipt)
    return receipt

def write_receipt(state,receipt):
    name='run-'+str(time.time_ns())+'.json'
    with (state/name).open('x') as f: json.dump(receipt,f,indent=2)

def main():
    p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--execute',action='store_true');p.add_argument('--root',type=Path,default=Path('/home/coolyo/afz-curated-media'));p.add_argument('--state',type=Path,default=Path('/home/coolyo/afz-curation/state'))
    a=p.parse_args()
    try:
        m=json.loads(a.manifest.read_text());rows,cost=validate_manifest(m)
        if not a.execute: print(json.dumps({'valid':True,'files':len(rows),'maximumMediaBytes':cost,'networkRequests':0}));return
        print(json.dumps(run(m,a.root,a.state,Provider(existing_key()))))
    except Exception as e:
        print(json.dumps({'ok':False,'code':str(e) if isinstance(e,Rejected) else 'sanitized-failure'}));raise SystemExit(1)
if __name__=='__main__': main()

