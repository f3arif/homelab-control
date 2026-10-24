"""Guarded two-host cutover. Invoke export, install, then connect via H3.

Never restore an old DB over current preferences. Emergency pause leaves the
authoritative state and media on ZBook and keeps the same owner-facing URL.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import time
from urllib.parse import urlsplit
from deploy import Release, ROOT, LIVE, UNIT, digest, atomic

SOURCE=Path(__file__).resolve().parent
STATE=ROOT/'state/movie-night-review'
STAGE=ROOT/'movie-night-8tb-5to15gb-20261024'
BASE='093643296b414fe78360358f2663fab01f0db2db'
ENV=dict(os.environ,XDG_RUNTIME_DIR='/run/user/1000',DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')
SECRET=ROOT/'private/movie-night-relay.key'
PYTHON=Path('/home/coolyo/afz-movie-night-runtime-312/bin/python')


def systemctl(*args):
    subprocess.run(['systemctl','--user',*args],env=ENV,check=True,timeout=45)


def snapshot(state=STATE):
    with sqlite3.connect('file:'+str(state/'preferences.sqlite3')+'?mode=ro',uri=True) as db:
        if db.execute("SELECT count(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:
            raise RuntimeError('Active transfer; defer cutover')
        if db.execute("SELECT count(*) FROM movie_download_queue WHERE state IN ('queued','checking')").fetchone()[0]:
            raise RuntimeError('Active source check; defer cutover')
        return {table:hashlib.sha256(json.dumps(db.execute('SELECT * FROM '+table+' ORDER BY rowid').fetchall()).encode()).hexdigest()
                for table in ('movie_feedback','movie_finalized')}


def tested():
    if not (SOURCE/'8tb-zbook-unit-results.log').read_text().rstrip().endswith('OK'):
        raise RuntimeError('ZBook tests missing or failed')
    log=(SOURCE/'8tb-browser-results.log').read_text()
    if 'PRIVATE_RELAY_PASS REAL_8TB_VOLUME' not in log:raise RuntimeError('Real-volume browser verification missing')
    for name,sha in json.loads((SOURCE/'qa/auto/tested-source.json').read_text()).items():
        if digest(SOURCE/name)!=sha:raise RuntimeError('Source changed since browser verification')


def verify_envy_source():
    for p in (SOURCE/'src').iterdir():
        if p.suffix not in ('.py','.js','.css','.html') or p.name in ('private_relay.py','storage_volume.py'):continue
        expected=subprocess.check_output(['git','-C',str(SOURCE),'show',BASE+':services/movie-night-review-ui/src/'+p.name])
        if digest(LIVE/p.name)!=hashlib.sha256(expected).hexdigest():raise RuntimeError('Envy source drift')


def export_envy():
    if socket.gethostname()!='hpenvy':raise RuntimeError('Envy only')
    verify_envy_source();before=snapshot()
    expected=(STAGE/'unit-before-pause.service').read_text().replace(' --downloads --auto-downloads','')
    if UNIT.read_text()!=expected:raise RuntimeError('Paused unit drift')
    export=STAGE/'export'
    if export.exists():raise RuntimeError('Export already exists; inspect first')
    systemctl('stop','afz-movie-night-review.service')
    if snapshot()!=before:raise RuntimeError('Preferences changed while stopping')
    export.mkdir(mode=0o700)
    state=export/'state/movie-night-review';state.mkdir(parents=True,mode=0o700)
    for path in STATE.rglob('*'):
        rel=path.relative_to(STATE)
        if rel.parts[0]=='run' or path.name.endswith(('-wal','-shm')) or path.name=='worker.lock':continue
        if path.is_symlink():raise RuntimeError('Unexpected state symlink')
        target=state/rel
        if path.is_dir():target.mkdir(mode=0o700,exist_ok=True)
        elif path.suffix=='.sqlite3':
            source=sqlite3.connect('file:'+str(path)+'?mode=ro',uri=True)
            with sqlite3.connect(target) as dest:source.backup(dest)
            source.close();target.chmod(0o600)
        elif path.is_file():shutil.copyfile(path,target);target.chmod(0o600)
    (state/'run').mkdir(mode=0o700)
    private=export/'private';private.mkdir(mode=0o700)
    raw=json.loads((ROOT/'private/addon-collection-private.json').read_text())
    addons=[{'transportUrl':a.get('transportUrl') or a.get('transportURL')} for a in raw.get('addons',[])
            if urlsplit(a.get('transportUrl') or a.get('transportURL') or '').hostname=='comet.elfhosted.com']
    if len(addons)!=1:raise RuntimeError('Configured source is ambiguous')
    atomic(private/'addon-collection-private.json',json.dumps({'addons':addons}).encode())
    if not SECRET.exists():atomic(SECRET,secrets.token_hex(32).encode())
    atomic(private/SECRET.name,SECRET.read_bytes())
    atomic(export/'preferences-snapshot.json',json.dumps(before).encode())
    atomic(export/'media-copy-receipt.json',(STAGE/'media-copy-receipt.json').read_bytes())
    archive=STAGE/'migration-private.tar.gz'
    with tarfile.open(archive,'w:gz') as t:
        for p in export.iterdir():t.add(p,arcname=p.name)
    archive.chmod(0o600)
    atomic(STAGE/'export-receipt.json',json.dumps({'archiveSha256':digest(archive),'snapshot':before,'unitSha256':digest(UNIT)}).encode())
    print('EXPORTED_STOPPED_STATE',archive.stat().st_size,digest(archive),flush=True)


def install_zbook(archive, expected_sha):
    if socket.gethostname()!='afz-zbook':raise RuntimeError('ZBook only')
    tested()
    if ROOT.exists() or UNIT.exists():raise RuntimeError('New backend destination already exists')
    archive=Path(archive)
    if digest(archive)!=expected_sha:raise RuntimeError('Migration archive hash mismatch')
    ROOT.mkdir(mode=0o700)
    with tarfile.open(archive,'r:gz') as t:
        for m in t.getmembers():
            p=Path(m.name)
            if p.is_absolute() or '..' in p.parts or m.issym() or m.islnk() or not(m.isfile() or m.isdir()):raise RuntimeError('Unsafe archive')
            if p.parts[0] not in ('state','private','preferences-snapshot.json','media-copy-receipt.json'):raise RuntimeError('Unexpected archive member')
        t.extractall(ROOT,filter='data')
    for p in ROOT.rglob('*'):p.chmod(0o700 if p.is_dir() else 0o600)
    if snapshot()!=json.loads((ROOT/'preferences-snapshot.json').read_text()):raise RuntimeError('Copied preferences mismatch')
    sys.path.insert(0,str(SOURCE/'src'))
    from storage_volume import MediaVolume
    from migrate_storage import migrate
    volume=MediaVolume();root=volume.ensure()
    receipt=json.loads((ROOT/'media-copy-receipt.json').read_text())
    # Copies land in a fresh incoming directory; verify before non-overwriting publication.
    from migrate_storage import file_hash
    for row in receipt:
        src=root/'Incoming-20261024'/Path(row['target']).name;dest=root/row['target']
        if not src.is_file() or src.is_symlink() or src.stat().st_size!=row['size'] or file_hash(src)!=row['sha256']:
            raise RuntimeError('Incoming media hash mismatch')
        if dest.exists() or dest.is_symlink():raise RuntimeError('Media destination already exists')
    for row in receipt:
        src=root/'Incoming-20261024'/Path(row['target']).name;dest=root/row['target']
        dest.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        os.link(src,dest,follow_symlinks=False) # fails instead of overwriting
    result=migrate(STATE,volume,receipt)
    if snapshot()!=json.loads((ROOT/'preferences-snapshot.json').read_text()):raise RuntimeError('Migration changed preferences')
    LIVE.mkdir(parents=True,mode=0o700)
    for p in (SOURCE/'src').iterdir():
        if p.suffix in ('.py','.js','.css','.html'):atomic(LIVE/p.name,p.read_bytes())
    unit=f'''[Unit]
Description=Movie Night 8 TB backend
After=network-online.target
[Service]
Type=simple
WorkingDirectory={LIVE}
Environment=PATH={PYTHON.parent}:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart={PYTHON} {LIVE}/review_service.py --state {STATE} --origin https://hpenvy.tailc9bb62.ts.net:8447 --downloads --auto-downloads --listen 100.77.196.70 --relay-secret {SECRET}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
[Install]
WantedBy=default.target
'''
    atomic(UNIT,unit.encode());systemctl('daemon-reload');systemctl('enable','--now','afz-movie-night-review.service')
    from deploy import healthy
    data=healthy()
    if not data.get('autoDownloads') or data.get('downloadPolicy',{}).get('maxBytes')!=15_000_000_000:raise RuntimeError('Backend activation mismatch')
    atomic(ROOT/'storage-migration-live.json',json.dumps({'source':subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'],text=True).strip(),**result,'snapshot':snapshot()}).encode())
    print('ZBOOK_BACKEND_READY',result,'savedPicks',len(data['finalized']['ids']),flush=True)


def connect_envy():
    if socket.gethostname()!='hpenvy':raise RuntimeError('Envy only')
    verify_envy_source();receipt=json.loads((STAGE/'export-receipt.json').read_text())
    if snapshot()!=receipt['snapshot'] or digest(UNIT)!=receipt['unitSha256']:raise RuntimeError('Envy changed after export')
    sys.path.insert(0,str(SOURCE/'src'))
    from private_relay import read_secret
    connection=http.client.HTTPConnection('100.77.196.70',8797,timeout=10)
    try:
        connection.request('GET','/movie-night/api/shortlist',headers={'X-AFZ-Review-Principal':'billing-owner','X-Movie-Night-Relay':read_secret(SECRET)})
        r=connection.getresponse();data=json.loads(r.read(1_000_001))
        if r.status!=200 or not data.get('autoDownloads') or data.get('downloadPolicy',{}).get('maxBytes')!=15_000_000_000:raise RuntimeError('Private backend unavailable')
    finally:connection.close()
    relay=ROOT/'movie-night-8tb-relay/private_relay.py'
    unit=UNIT.read_text().splitlines()
    unit=[f'ExecStart=/usr/bin/python3 {relay} --socket {STATE}/run/review.sock --secret {SECRET}' if x.startswith('ExecStart=') else x for x in unit]
    files={str(relay):(SOURCE/'src/private_relay.py').read_bytes(),str(UNIT):('\n'.join(unit)+'\n').encode()}
    gateways=[ROOT/'movie-night-access-service/movie_gateway.py',Path('/home/coolyo/afz-billing/src/movie_gateway.py')]
    for p in gateways:
        old=p.read_text()
        if old.count('length<=9_000_000_000')!=1:raise RuntimeError('Gateway size guard drift')
        files[str(p)]=old.replace('length<=9_000_000_000','length<=15_000_000_000').encode()
    release=Release(STAGE/'relay-release',files);release.prepare();release.swap()
    systemctl('daemon-reload');systemctl('start','afz-movie-night-review.service')
    from deploy import healthy
    data=healthy()
    if not data.get('autoDownloads'):raise RuntimeError('Relay health mismatch')
    systemctl('restart','afz-movie-night-access.service','afz-billing.service')
    atomic(STAGE/'connected.json',json.dumps({'source':subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'],text=True).strip(),'snapshot':snapshot()}).encode())
    print('ENVY_RELAY_CONNECTED','savedPicks',len(data['finalized']['ids']),data['downloadPolicy'],flush=True)


def pause_zbook():
    if socket.gethostname()!='afz-zbook':raise RuntimeError('ZBook only')
    # Explicit emergency stop; preserve all bytes, jobs and latest preferences.
    with sqlite3.connect(STATE/'preferences.sqlite3') as db:
        for pid, in db.execute("SELECT id FROM jobs WHERE state IN ('approved','downloading')").fetchall():
            db.execute('INSERT OR IGNORE INTO cancellations VALUES(?)',(pid,))
    old=UNIT.read_text()
    if '--listen 100.77.196.70' not in old:raise RuntimeError('Unexpected backend unit')
    atomic(UNIT,old.replace(' --downloads --auto-downloads','').encode())
    systemctl('daemon-reload');systemctl('restart','afz-movie-night-review.service')
    print('DOWNLOADS_PAUSED_ON_ZBOOK_STATE_AND_MEDIA_PRESERVED')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['export-envy','install-zbook','connect-envy','pause-zbook'])
    p.add_argument('--archive');p.add_argument('--sha256');a=p.parse_args()
    if a.action=='export-envy':export_envy()
    elif a.action=='install-zbook':install_zbook(a.archive,a.sha256)
    elif a.action=='connect-envy':connect_envy()
    else:pause_zbook()
