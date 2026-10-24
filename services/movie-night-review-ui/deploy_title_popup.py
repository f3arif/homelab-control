"""Guarded static-only title-popup release. No restart or saved-state writes."""
from pathlib import Path
import argparse,fcntl,hashlib,json,os,shutil,socket,subprocess,time
from deploy import Release,ROOT,LIVE,UNIT,digest,atomic,healthy
from deploy_similar_search import served,state_digest

BASE='4bc219bddcaed0c3d3c12724ebeef84754b248a0'
STAGE=ROOT/'movie-night-title-popup-20261024'
FILES=('screen.js','screen.html','screen.css')
ENV=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000',DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')

def pid():
    value=subprocess.check_output(['systemctl','--user','show','afz-movie-night-review.service','-p','MainPID','--value'],env=ENV,text=True).strip()
    if not value.isdigit() or int(value)<=0:raise RuntimeError('Review backend is not running')
    return int(value)

def verify(rollback):
    data=healthy()
    if data.get('similarSearchEnabled') is not True or data.get('selectionLimits')!={'min':3,'max':10,'visible':10}:raise RuntimeError('Search/pick contract changed')
    for name in ('screen.js','screen.css'):
        if hashlib.sha256(served(name)).hexdigest()!=digest(LIVE/name):raise RuntimeError('Served file differs from runtime')
    if (b'id="title-popup"' in served(''))==rollback:raise RuntimeError('Wrong popup page served')
    return {'suggestions':len(data['movies']),'finalized':len(data['finalized']['ids'])}

def prepare(source):
    for name,marker in [('popup-target-unit-results.log','\nOK'),('popup-browser-results.log','TITLE_POPUP_REAL_API_BROWSER_PASS_360_412_1280_NO_WRITES'),('popup-search-regression.log','SIMILAR_SEARCH_REAL_API_BROWSER_PASS_360_412_1280_NO_MEDIA'),('popup-card-regression.log','CARD_STATUS_BROWSER_PASS_360_412_1280_NO_WRITES')]:
        if marker not in (source/name).read_text():raise RuntimeError('Qualification missing: '+name)
    for proof in ('qa/title-popup/tested-source.json','qa/similar-search/tested-source.json'):
        for name,sha in json.loads((source/proof).read_text()).items():
            if digest(source/name)!=sha:raise RuntimeError('Tested source drift: '+name)
    baseline={str(UNIT):digest(UNIT)}
    for p in (source/'src').iterdir():
        if p.suffix not in ('.py','.js','.html','.css'):continue
        old=subprocess.check_output(['git','-C',str(source),'show',BASE+':services/movie-night-review-ui/src/'+p.name])
        sha=hashlib.sha256(old).hexdigest()
        if (LIVE/p.name).is_symlink() or digest(LIVE/p.name)!=sha:raise RuntimeError('Unexpected live source: '+p.name)
        baseline[str(LIVE/p.name)]=sha
    Release(STAGE,{str(LIVE/n):(source/'src'/n).read_bytes() for n in FILES}).prepare()
    atomic(STAGE/'live-baseline.json',json.dumps(baseline,indent=2).encode())
    for name in ('deploy_title_popup.py','deploy.py','deploy_similar_search.py'):shutil.copyfile(source/name,STAGE/name)
    print('PREPARED 3 static files; no runtime changes')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','apply','rollback']);action=parser.parse_args().action
    if socket.gethostname()!='afz-zbook':raise RuntimeError('ZBook release only')
    if action=='prepare':return prepare(Path(__file__).resolve().parent)
    with (STAGE/'.deploy.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest=json.loads((STAGE/'manifest.json').read_text());rollback=action=='rollback';expected='after' if rollback else 'before'
        if set(manifest)!={str(LIVE/n) for n in FILES}:raise RuntimeError('Unexpected release scope')
        for path,row in manifest.items():
            if Path(path).is_symlink() or digest(Path(path))!=row[expected]:raise RuntimeError('Live drift; no changes')
            for version in ('before','after'):
                if digest(STAGE/f"{row['slot']}.{version}")!=row[version]:raise RuntimeError('Stage drift; no changes')
        for path,sha in json.loads((STAGE/'live-baseline.json').read_text()).items():
            if path not in manifest and digest(Path(path))!=sha:raise RuntimeError('Unrelated source drift; no changes')
        before_pid=pid();before=state_digest()
        try:
            Release(STAGE,{}).swap(rollback);result=verify(rollback);after_pid=pid();after=state_digest()
            receipt={'action':action,'beforePID':before_pid,'afterPID':after_pid,'before':before,'after':after,'stateUnchanged':before==after,**result}
            atomic(STAGE/(action+'-'+str(time.time_ns())+'.json'),json.dumps(receipt,indent=2).encode())
            if before_pid!=after_pid:raise RuntimeError('Backend PID changed during static release')
            print('HEALTHY',action,json.dumps(result),'NO_RESTART','STATE_UNCHANGED' if before==after else 'CONCURRENT_STATE_CHANGE_RECORDED')
        except Exception:
            # Restore this page version only; no database or media rollback.
            if any(digest(Path(p)) not in (r['before'],r['after']) for p,r in manifest.items()):raise RuntimeError('Outside source drift; manual recovery required')
            for path,row in manifest.items():atomic(Path(path),(STAGE/f"{row['slot']}.{expected}").read_bytes())
            atomic(STAGE/'status.txt',('recovered-'+action).encode());raise

if __name__=='__main__':main()
