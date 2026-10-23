"""Guarded static UI repair; no restart, preferences or media changes."""
from pathlib import Path
import argparse,fcntl,hashlib,json,shutil,subprocess
from deploy import Release,ROOT,LIVE,digest,atomic
STAGE=ROOT/'movie-night-source-feedback-20261023'
BASE='e44fbf401e627c80b2dac9bb9c97965f10f4d7bc'
FILES=('screen.js','screen.html','screen.css')

def verify_served():
    import http.client,socket
    class UnixConnection(http.client.HTTPConnection):
        def __init__(self,path):super().__init__('localhost',timeout=5);self.path=str(path)
        def connect(self):
            self.sock=socket.socket(socket.AF_UNIX);self.sock.settimeout(5);self.sock.connect(self.path)
    for name in FILES:
        c=UnixConnection(ROOT/'state/movie-night-review/run/review.sock')
        try:
            c.request('GET','/movie-night' if name=='screen.html' else '/movie-night/'+name,headers={'X-AFZ-Review-Principal':'billing-owner'})
            response=c.getresponse();body=response.read()
            if response.status!=200:raise RuntimeError('Asset unavailable')
            if name=='screen.html':
                if b'id="source-status"' not in body:raise RuntimeError('Dialog HTML unavailable')
            elif hashlib.sha256(body).hexdigest()!=digest(LIVE/name):raise RuntimeError('Served source mismatch')
        finally:c.close()

def restore_known(manifest):
    for path,row in manifest.items():
        if digest(Path(path)) not in (row['before'],row['after']):raise RuntimeError('Unexpected live drift; manual review required')
        if digest(STAGE/f"{row['slot']}.before")!=row['before']:raise RuntimeError('Backup hash mismatch')
    for path,row in manifest.items():atomic(Path(path),(STAGE/f"{row['slot']}.before").read_bytes())
    atomic(STAGE/'status.txt',b'rolled-back')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','apply','rollback']);args=parser.parse_args()
    source=Path(__file__).resolve().parent
    if args.action=='prepare':
        checks=[('source-feedback-results.log','SOURCE_FEEDBACK_BROWSER_PASS_360_412_1280_NO_APPROVALS'),('source-full-flow-results.log','STANDALONE_IDENTITY_FULL_UI_TRANSFER_PASS_360_412_1280')]
        for name,marker in checks:
            if marker not in (source/name).read_text():raise RuntimeError('Required browser verification missing')
        tested=json.loads((source/'qa/source-feedback/tested-source.json').read_text())
        for name in FILES:
            if digest(source/'src'/name)!=tested[name]:raise RuntimeError('Source changed after browser verification')
            previous=subprocess.check_output(['git','-C',str(source),'show',BASE+':services/movie-night-review-ui/src/'+name])
            if digest(LIVE/name)!=hashlib.sha256(previous).hexdigest():raise RuntimeError('Unexpected live source')
        Release(STAGE,{str(LIVE/n):(source/'src'/n).read_bytes() for n in FILES}).prepare()
        for name in ('deploy_source_feedback.py','deploy.py'):shutil.copyfile(source/name,STAGE/name)
        for name in ('source-feedback-results.log','source-full-flow-results.log'):shutil.copyfile(source/name,STAGE/name)
        print('PREPARED three static files; no restart');return
    with (STAGE/'.deploy.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest=json.loads((STAGE/'manifest.json').read_text())
        rollback=args.action=='rollback'
        expected='after' if rollback else 'before'
        if any(digest(Path(p))!=r[expected] for p,r in manifest.items()):raise RuntimeError('Live drift; no changes')
        try:
            Release(STAGE,{}).swap(rollback)
            if not rollback:verify_served()
            print('HEALTHY',args.action,'three static files; no restart or state edits')
        except Exception:
            if not rollback:restore_known(manifest)
            raise
if __name__=='__main__':main()
