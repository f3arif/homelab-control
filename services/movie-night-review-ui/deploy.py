"""Reversible guarded source deployment; never restores or edits preference/media data."""
from pathlib import Path
import hashlib,json,os,tempfile,shutil,subprocess,time,argparse
HOME=Path('/home/coolyo')
ROOT=HOME/'afz-stremio-secondhost-20260918'
LIVE=ROOT/'movie-night-review-service/src'
STAGE=ROOT/'movie-night-downloads-20261023'
UNIT=HOME/'.config/systemd/user/afz-movie-night-review.service'
GATEWAY=HOME/'afz-billing/src/movie_gateway.py'

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
def atomic(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.movie-night-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as h:h.write(data);h.flush();os.fsync(h.fileno())
        os.chmod(tmp,0o600);os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

class Release:
    def __init__(self,stage,files):self.stage=Path(stage);self.files={str(Path(k)):v for k,v in files.items()}
    def prepare(self):
        self.stage.mkdir(mode=0o700,parents=True,exist_ok=False);manifest={}
        for n,(path,data) in enumerate(self.files.items()):
            p=Path(path)
            if p.is_symlink():raise RuntimeError('Symlink deployment refused')
            before=p.read_bytes() if p.exists() else None
            if before is not None:atomic(self.stage/f'{n}.before',before)
            atomic(self.stage/f'{n}.after',data)
            manifest[path]={'slot':n,'before':hashlib.sha256(before).hexdigest() if before is not None else None,'after':hashlib.sha256(data).hexdigest()}
        atomic(self.stage/'manifest.json',json.dumps(manifest,indent=2).encode())
    def swap(self,rollback=False):
        m=json.loads((self.stage/'manifest.json').read_text())
        expected='after' if rollback else 'before';target='before' if rollback else 'after'
        for path,r in m.items():
            p=Path(path)
            if p.is_symlink() or digest(p)!=r[expected]:raise RuntimeError('Live source drift; no files changed')
            if r[target] is not None and digest(self.stage/f"{r['slot']}.{target}")!=r[target]:raise RuntimeError('Stage hash mismatch')
        for path,r in m.items():
            if r[target] is None:Path(path).unlink()
            else:atomic(Path(path),(self.stage/f"{r['slot']}.{target}").read_bytes())
        atomic(self.stage/'status.txt',('rolled-back' if rollback else 'applied').encode())

def service(action):
    env=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000')
    subprocess.run(['systemctl','--user',action,'afz-movie-night-review.service','afz-billing.service'],env=env,check=True,timeout=40)
def reload_units():
    subprocess.run(['systemctl','--user','daemon-reload'],env=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000'),check=True,timeout=20)
def healthy():
    import http.client,socket
    class UnixConnection(http.client.HTTPConnection):
        def __init__(self,path):super().__init__('localhost',timeout=2);self.path=str(path)
        def connect(self):
            self.sock=socket.socket(socket.AF_UNIX);self.sock.settimeout(2);self.sock.connect(self.path)
    for attempt in range(80):
        c=UnixConnection(ROOT/'state/movie-night-review/run/review.sock')
        try:
            c.request('GET','/movie-night/api/shortlist',headers={'X-AFZ-Review-Principal':'billing-owner'})
            r=c.getresponse();data=json.loads(r.read())
            if r.status==200 and isinstance(data.get('movies'),list):return data
            time.sleep(.25)
        except Exception:time.sleep(.25)
        finally:c.close()
    raise RuntimeError('Backend readiness failed')

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare','apply','rollback']);args=p.parse_args()
    source=Path(__file__).resolve().parent
    if args.action=='prepare':
        for proof in [source/'unit-results.log',source/'gateway-results.log']:
            if not proof.exists():raise RuntimeError('Validation evidence missing')
        if not (source/'unit-results.log').read_text().rstrip().endswith('OK'):raise RuntimeError('Unit tests failed')
        if 'AUTH_HOST_ORIGIN_CSRF_EXACT_ROUTES_AND_FIXTURE_TRANSFER_PASS' not in (source/'gateway-results.log').read_text():raise RuntimeError('Gateway validation failed')
        tested=json.loads((source/'qa/tested-source.json').read_text())
        for name,sha in tested.items():
            if digest(source/name)!=sha:raise RuntimeError('Source changed after gateway QA')
        files={str(LIVE/f.name):f.read_bytes() for f in (source/'src').iterdir() if f.suffix in ('.py','.css','.js','.html')}
        files[str(GATEWAY)]=(source/'gateway/movie_gateway.py').read_bytes()
        unit=UNIT.read_text().replace('private review only','private review and confirmed downloads')
        unit=unit.replace('--origin https://hpenvy.tailc9bb62.ts.net:8447','--origin https://hpenvy.tailc9bb62.ts.net:8447 --downloads')
        files[str(UNIT)]=unit.encode()
        release=Release(STAGE,files);release.prepare()
        shutil.copy2(__file__,STAGE/'deploy.py')
        print('PREPARED',len(files),'files; rollback preserves DB and media');return
    release=Release(STAGE,{})
    # Verify the whole transaction before stopping either service.
    m=json.loads((STAGE/'manifest.json').read_text());expected='after' if args.action=='rollback' else 'before'
    if any(digest(Path(path))!=r[expected] for path,r in m.items()):raise RuntimeError('Live drift; deployment refused')
    service('stop')
    try:
        release.swap(args.action=='rollback');reload_units();service('start');data=healthy()
        if args.action=='apply' and data.get('actionsEnabled') is not True:raise RuntimeError('Downloads not enabled')
        print('HEALTHY',args.action,'movies',len(data['movies']),'actionsEnabled',data['actionsEnabled'])
    except Exception:
        if args.action=='apply':
            release.swap(True);reload_units();service('start');healthy();print('ROLLED_BACK_AFTER_FAILED_DEPLOY')
        else:service('start')
        raise
if __name__=='__main__':main()
