"""Guarded automatic-download release. Preferences and media are never restored."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,sqlite3,subprocess
from deploy import Release,ROOT,LIVE,UNIT,digest,healthy

STAGE=ROOT/'movie-night-auto-download-20261024'
BASE='d0f12b9974dd83110d52d5247127c61b6bfbaf1f'
FILES=('auto_downloads.py','cached_sources.py','movie_night.py','feedback.py','webapp.py','review_service.py','download_provider.py','worker_candidate.py','screen.js','screen.html')
NEW={'auto_downloads.py','cached_sources.py'}
ENV=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000')

def service(action):
    subprocess.run(['systemctl','--user',action,'afz-movie-night-review.service'],env=ENV,check=True,timeout=40)

def reload_units():
    subprocess.run(['systemctl','--user','daemon-reload'],env=ENV,check=True,timeout=20)

def snapshot():
    with sqlite3.connect('file:'+str(ROOT/'state/movie-night-review/preferences.sqlite3')+'?mode=ro',uri=True) as db:
        if db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:raise RuntimeError('Active download; defer restart')
        if db.execute("SELECT 1 FROM sqlite_master WHERE name='movie_download_queue'").fetchone():
            if db.execute("SELECT COUNT(*) FROM movie_download_queue WHERE state IN ('queued','checking')").fetchone()[0]:raise RuntimeError('Active source queue; defer restart')
        return {table:hashlib.sha256(json.dumps(db.execute('SELECT * FROM '+table+' ORDER BY rowid').fetchall()).encode()).hexdigest() for table in ('movie_feedback','movie_finalized','jobs','plans','cancellations')}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','apply','rollback']);args=parser.parse_args()
    source=Path(__file__).resolve().parent
    if args.action=='prepare':
        if not (source/'auto-unit-results.log').read_text().rstrip().endswith('OK'):raise RuntimeError('Unit verification did not pass')
        if 'AUTO_FINALIZE_CACHE_TRANSFER_RANGE_RELOAD_PASS_360_412_1280' not in (source/'auto-browser-results.log').read_text():raise RuntimeError('Automatic browser flow did not pass')
        tested=json.loads((source/'qa/auto/tested-source.json').read_text())
        for path,sha in tested.items():
            if digest(source/path)!=sha:raise RuntimeError('Source changed after QA')
        for name in FILES:
            previous=None if name in NEW else subprocess.check_output(['git','-C',str(source),'show',BASE+':services/movie-night-review-ui/src/'+name])
            if digest(LIVE/name)!=(hashlib.sha256(previous).hexdigest() if previous is not None else None):raise RuntimeError('Live source drift; no changes')
        unit=UNIT.read_text()
        lines=unit.splitlines();starts=[i for i,x in enumerate(lines) if x.startswith('ExecStart=')]
        if len(starts)!=1 or '--downloads' not in lines[starts[0]] or '--auto-downloads' in unit:raise RuntimeError('Unexpected service unit')
        lines[starts[0]]+=' --auto-downloads'
        files={str(LIVE/n):(source/'src'/n).read_bytes() for n in FILES};files[str(UNIT)]=('\n'.join(lines)+'\n').encode()
        snapshot();Release(STAGE,files).prepare()
        for name in ('deploy_auto_downloads.py','deploy.py'):shutil.copyfile(source/name,STAGE/name)
        db=sqlite3.connect('file:'+str(ROOT/'state/movie-night-review/preferences.sqlite3')+'?mode=ro',uri=True)
        with sqlite3.connect(STAGE/'preferences-before.sqlite3') as backup:db.backup(backup)
        db.close();(STAGE/'preferences-before.sqlite3').chmod(0o600)
        print('PREPARED automatic downloads; old picks will not enqueue');return
    rollback=args.action=='rollback';manifest=json.loads((STAGE/'manifest.json').read_text())
    if any(digest(Path(path))!=row['after' if rollback else 'before'] for path,row in manifest.items()):raise RuntimeError('Live drift; no changes')
    before=snapshot();release=Release(STAGE,{})
    service('stop')
    try:
        if snapshot()!=before:raise RuntimeError('State changed during stop; abort')
        release.swap(rollback);reload_units();service('start');data=healthy()
        if not rollback and (not data.get('autoDownloads') or not data.get('actionsEnabled')):raise RuntimeError('Automatic download activation failed')
        if snapshot()!=before:raise RuntimeError('Unexpected preference or job change')
        print('HEALTHY',args.action,'automatic',data.get('autoDownloads',False),'savedPicks',len(data['finalized']['ids']),'preferencesAndJobsPreserved',True)
    except Exception:
        if not rollback and (STAGE/'status.txt').exists() and (STAGE/'status.txt').read_text()=='applied':
            service('stop');release.swap(True);reload_units();service('start');healthy();print('RESTORED previous runtime')
        else:service('start')
        raise

if __name__=='__main__':main()
