"""Two guarded static files on ZBook; no restart or state/media changes."""
from pathlib import Path
import argparse,fcntl,hashlib,json,shutil,socket,subprocess
from deploy import Release,ROOT,LIVE,digest,atomic
STAGE=ROOT/'movie-night-card-status-20261024'
BASE='3f32bb2c469c96abebbc63ef2b828b53f987817d'
FILES=('screen.js','screen.css')

def verify_served():
    import http.client
    class UnixConnection(http.client.HTTPConnection):
        def connect(self):
            self.sock=socket.socket(socket.AF_UNIX);self.sock.settimeout(5)
            self.sock.connect(str(ROOT/'state/movie-night-review/run/review.sock'))
    for name in FILES:
        c=UnixConnection('localhost',timeout=5)
        try:
            c.request('GET','/movie-night/'+name,headers={'X-AFZ-Review-Principal':'billing-owner'})
            r=c.getresponse();body=r.read()
            if r.status!=200 or hashlib.sha256(body).hexdigest()!=digest(LIVE/name):raise RuntimeError('Served source mismatch')
        finally:c.close()

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare','apply','rollback']);args=p.parse_args()
    if socket.gethostname()!='afz-zbook':raise RuntimeError('This static release belongs on ZBook')
    source=Path(__file__).resolve().parent
    if args.action=='prepare':
        for log,marker in [('card-status-results.log','CARD_STATUS_BROWSER_PASS_360_412_1280_NO_WRITES'),('card-status-flow-results.log','AUTO_FINALIZE_CACHE_TRANSFER_RANGE_RELOAD_PASS_360_412_1280')]:
            if marker not in (source/log).read_text():raise RuntimeError('Required verification missing')
        tested=json.loads((source/'qa/card-status/tested-source.json').read_text())
        flow=json.loads((source/'qa/auto/tested-source.json').read_text())
        for name in FILES:
            if digest(source/'src'/name)!=tested[name] or digest(source/'src'/name)!=flow['src/'+name]:raise RuntimeError('Tested source changed')
            old=subprocess.check_output(['git','-C',str(source),'show',BASE+':services/movie-night-review-ui/src/'+name])
            if digest(LIVE/name)!=hashlib.sha256(old).hexdigest():raise RuntimeError('Live source changed')
        Release(STAGE,{str(LIVE/n):(source/'src'/n).read_bytes() for n in FILES}).prepare()
        for name in ('deploy_card_status.py','deploy.py'):shutil.copyfile(source/name,STAGE/name)
        print('PREPARED two static files; no restart');return
    with (STAGE/'.deploy.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest=json.loads((STAGE/'manifest.json').read_text());rollback=args.action=='rollback'
        expected='after' if rollback else 'before'
        if any(digest(Path(path))!=row[expected] for path,row in manifest.items()):raise RuntimeError('Live drift; no changes')
        try:
            Release(STAGE,{}).swap(rollback);verify_served()
            print('HEALTHY',args.action,'two static files; no restart or data edits')
        except Exception:
            if not rollback:
                for path,row in manifest.items():
                    if digest(Path(path)) not in (row['before'],row['after']) or digest(STAGE/f"{row['slot']}.before")!=row['before']:raise RuntimeError('Unexpected drift; manual recovery required')
                for path,row in manifest.items():atomic(Path(path),(STAGE/f"{row['slot']}.before").read_bytes())
                atomic(STAGE/'status.txt',b'rolled-back')
            raise
if __name__=='__main__':main()
