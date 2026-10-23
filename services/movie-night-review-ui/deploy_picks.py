"""Guarded four-file pick-limit upgrade; never restore preferences or media."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,sqlite3,subprocess
from deploy import Release, ROOT, LIVE, digest, healthy

STAGE=ROOT/'movie-night-more-picks-20261023'
BASE='80c326981a8e0a2154c95700a012f41d3bc9c168'
FILES=('feedback.py','webapp.py','screen.js','screen.html')
ENV=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000')


def service(action):
    subprocess.run(['systemctl','--user',action,'afz-movie-night-review.service'],env=ENV,check=True,timeout=40)


def idle():
    db=sqlite3.connect('file:'+str(ROOT/'state/movie-night-review/preferences.sqlite3')+'?mode=ro',uri=True)
    try:
        if db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:
            raise RuntimeError('Active download; defer backend restart until it finishes')
    finally:db.close()


def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','apply','rollback']);args=parser.parse_args()
    source=Path(__file__).resolve().parent
    if args.action=='prepare':
        if not (source/'picks-unit-results.log').read_text().rstrip().endswith('OK'):
            raise RuntimeError('Unit verification did not pass')
        if 'STANDALONE_IDENTITY_FULL_UI_TRANSFER_PASS_360_412_1280' not in (source/'picks-browser-results.log').read_text():
            raise RuntimeError('Browser flow did not pass')
        tested=json.loads((source/'qa/access/tested-source.json').read_text())
        for name in FILES:
            if digest(source/'src'/name)!=tested['src/'+name]:raise RuntimeError('Source changed after QA')
            previous=subprocess.check_output(['git','-C',str(source),'show',BASE+':services/movie-night-review-ui/src/'+name])
            if digest(LIVE/name)!=hashlib.sha256(previous).hexdigest():raise RuntimeError('Unexpected live source; no changes')
        idle()
        Release(STAGE,{str(LIVE/n):(source/'src'/n).read_bytes() for n in FILES}).prepare()
        for name in ('deploy_picks.py','deploy.py'):shutil.copyfile(source/name,STAGE/name)
        db=sqlite3.connect('file:'+str(ROOT/'state/movie-night-review/preferences.sqlite3')+'?mode=ro',uri=True)
        with sqlite3.connect(STAGE/'preferences-before.sqlite3') as backup:db.backup(backup)
        db.close();(STAGE/'preferences-before.sqlite3').chmod(0o600)
        print('PREPARED four files; preferences are backup evidence only');return
    manifest=json.loads((STAGE/'manifest.json').read_text());rollback=args.action=='rollback'
    expected='after' if rollback else 'before'
    for path,row in manifest.items():
        if digest(Path(path))!=row[expected]:raise RuntimeError('Live drift; no files changed')
    idle();release=Release(STAGE,{})
    service('stop')
    try:
        release.swap(rollback);service('start');data=healthy()
        if not rollback and data.get('selectionLimits')!={'min':3,'max':10,'visible':10}:
            raise RuntimeError('Pick-limit acceptance failed')
        print('HEALTHY',args.action,'cards',len(data['movies']),'limits',data.get('selectionLimits'))
    except Exception:
        if not rollback:
            release.swap(True);service('start');healthy();print('RESTORED previous runtime')
        else:service('start')
        raise


if __name__=='__main__':main()
