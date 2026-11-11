"""Reversible R55-only repair for the Movie Night server deletion preview."""
from contextlib import ExitStack
from pathlib import Path
import argparse
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import socket
import stat
import subprocess
import sys
import time

RECOVERY = Path('/home/coolyo/AFZ/Recovery/movie-night-delete-resident-20261111')
CANDIDATE = RECOVERY / 'work/services/movie-night-review-ui'
sys.path.insert(0, str(CANDIDATE))
from deploy import Release, atomic, digest
from deploy_mobile_selection import backup_state, idle, state_digest, service, UnixConnection

ROOT = Path('/home/coolyo/afz-stremio-secondhost-20260918')
LIVE = ROOT / 'movie-night-review-service/src'
STATE = ROOT / 'state/movie-night-review'
UNIT = Path('/home/coolyo/.config/systemd/user/afz-movie-night-review.service')
DROPIN = UNIT.parent / (UNIT.name + '.d') / '90-server-delete.conf'
STAGE = RECOVERY / 'release'
ENV = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000',
           DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')
COMMIT = 'ab832895d553d5b0ec8839681b3a5a152333107c'
TARGET = Path('/srv/afzmedia/Media/MovieNight/Movies/tt35538033.2026.mkv')
EXPECTED = {
    'adapters.py': (
        'e01d65da19d1ed8c2e467b0200f78b45861d8a85ff5fbca6cc66cd4e1e6c161e',
        '91cc23b360e38922c7cf369a77ced657e20c733382cfd3b406dd18f3c5585717'),
    'auto_downloads.py': (
        '8727f084a220e4a6553227294cc60c8b5907eabf4d4940be75f6059dfef96463',
        '69c0576957b23725c3a7a480c86d75c0f2592694a2312f869ad993a27d3ba11e'),
    'review_service.py': (
        '44411db96dc780bd4b8e630b80ca9b60f0153b638b0da534e683083f05fd33ac',
        '80593570beaedbe2a01928391df133a1eaf317567be2193f14892f5dad3b1441'),
    'server_file_delete.py': (
        None,
        'e4cf06bec65fb31806e6a35ec03cf54844834edd9d0c9091448e0eb6fbfebc53'),
    'webapp.py': (
        'c95a960060534c67d164dc3ed235e8b9195b6b5125d8ae84e255ec58fc61294a',
        '3a946333f734d1f7732f3610b5f8a72a63a73ecb5f623e88ab3d8720359f553a')
}

def save(path, payload):
    atomic(path, json.dumps(payload, indent=2).encode())

def target_stat():
    st = TARGET.stat(follow_symlinks=False)
    if not stat.S_ISREG(st.st_mode) or st.st_size != 5717315218:
        raise RuntimeError('Resident Evil file changed before release')
    return dict(size=st.st_size, device=st.st_dev, inode=st.st_ino, mtimeNs=st.st_mtime_ns)

def config_hashes():
    files = [UNIT] + sorted((UNIT.parent / (UNIT.name + '.d')).glob('*.conf'))
    return {str(p):digest(p) for p in files if p != DROPIN}

def current_argv():
    pid = subprocess.check_output(
        ['systemctl','--user','show',UNIT.name,'-p','MainPID','--value'],
        env=ENV, text=True).strip()
    return Path('/proc/' + pid + '/cmdline').read_bytes().decode().rstrip('\0').split('\0')

def reload_units():
    subprocess.run(['systemctl','--user','daemon-reload'],env=ENV,
                   check=True,timeout=20,capture_output=True)

def get_json(path):
    connection = UnixConnection('localhost', timeout=5)
    try:
        connection.request('GET', '/movie-night' + path,
                           headers={'X-AFZ-Review-Principal':'billing-owner'})
        response = connection.getresponse()
        payload = json.loads(response.read())
        if response.status != 200:
            raise RuntimeError('Read-only health endpoint failed: ' + str(response.status))
        return payload
    finally:
        connection.close()

def health(delete_enabled):
    service('is-active')
    last = None
    for _ in range(40):
        try:
            catalog = get_json('/catalog/movie/downloaded.json')
            ids = sorted(m['id'] for m in catalog['metas'])
            if not delete_enabled:
                return dict(readyIds=ids, deletionEnabled=False)
            if 'tt35538033' not in ids or len(ids) != 9:
                raise RuntimeError('Ready catalog differs from pre-release inventory')
            preview = get_json('/api/delete-server/tt35538033')
            assert preview['imdb'] == 'tt35538033'
            assert preview['title'] == 'Resident Evil'
            assert preview['sizeBytes'] == 5717315218
            assert preview['requiresExplicitConfirmation'] is True
            assert 0 < preview['expiresInSeconds'] <= 120
            for key in ('confirmationToken','csrfToken'):
                assert re.fullmatch(r'[A-Za-z0-9_-]{20,160}', preview[key])
            return dict(readyIds=ids, deletionEnabled=True,
                        previewImdb=preview['imdb'], previewTitle=preview['title'],
                        previewSizeBytes=preview['sizeBytes'],
                        requiresExplicitConfirmation=True, tokensValid=True)
        except (OSError, ConnectionError) as exc:
            last = type(exc).__name__
            time.sleep(.25)
    raise RuntimeError('Backend socket unavailable: ' + str(last))

def preserved(before, after):
    for name, content in before.items():
        if isinstance(content, dict):
            if any(after[name].get(table) != value for table,value in content.items()):
                return False
            added = set(after[name]) - set(content)
            if added - {'removed_media'}:
                return False
            if 'removed_media' in added and after[name]['removed_media']['rows'] != 0:
                return False
        elif after[name] != content:
            return False
    return True

def check_pins(plan, applied):
    for name, expected in plan['allSourceHashes'].items():
        wanted = EXPECTED[name][1] if applied and name in EXPECTED else expected
        if digest(LIVE / name) != wanted:
            raise RuntimeError('Live source drift: ' + name)
    if config_hashes() != plan['configHashes']:
        raise RuntimeError('Existing service configuration drift')
    if digest(DROPIN) != (plan['dropinSha256'] if applied else None):
        raise RuntimeError('Feature drop-in drift')

def tombstone_count():
    with sqlite3.connect((STATE / 'download-index.sqlite3').as_uri()+'?mode=ro',uri=True) as db:
        if db.execute("SELECT 1 FROM sqlite_master WHERE name='removed_media'").fetchone():
            return db.execute('SELECT count(*) FROM removed_media').fetchone()[0]
    return 0

def prepare():
    receipt = json.loads((RECOVERY / 'candidate-test-receipt.json').read_text())
    if receipt['exitCode'] != 0 or receipt['testsRun'] != 399 or receipt['sourceCommit'] != COMMIT:
        raise RuntimeError('Candidate test evidence differs')
    names = {p.name for p in LIVE.iterdir() if p.suffix in ('.py','.css','.js','.html')}
    baseline = {name:digest(LIVE/name) for name in names | set(EXPECTED)}
    for name, pair in EXPECTED.items():
        if baseline[name] != pair[0] or digest(CANDIDATE/'src'/name) != pair[1]:
            raise RuntimeError('Pinned source differs: ' + name)
    for name in names - set(EXPECTED):
        if digest(CANDIDATE/'src'/name) != baseline[name]:
            raise RuntimeError('Unexpected candidate delta: ' + name)
    argv = current_argv()
    if '--server-delete' in argv or not all(re.fullmatch(r'[A-Za-z0-9_./:=,-]+',arg) for arg in argv):
        raise RuntimeError('Unexpected existing service argv')
    if argv[:2] != ['/home/coolyo/afz-movie-night-runtime-312/bin/python',
                    str(LIVE/'review_service.py')]:
        raise RuntimeError('Unexpected service entry point')
    if DROPIN.exists():
        raise RuntimeError('Existing feature drop-in')
    idle()
    dropin = ('[Service]\nExecStart=\nExecStart='+' '.join(argv+['--server-delete'])+'\n').encode()
    files = {str(LIVE/name):(CANDIDATE/'src'/name).read_bytes() for name in EXPECTED}
    files[str(DROPIN)] = dropin
    release = Release(STAGE,files)
    release.prepare()
    plan = dict(sourceCommit=COMMIT, allSourceHashes=baseline,
                configHashes=config_hashes(), targetBefore=target_stat(),
                dropinSha256=hashlib.sha256(dropin).hexdigest(),
                modes={str(p):stat.S_IMODE(p.stat().st_mode) for p in
                       [LIVE/n for n in EXPECTED] if p.exists()})
    for i,path in enumerate(plan['configHashes']):
        atomic(STAGE/('config-'+str(i)+'.before'),Path(path).read_bytes())
    save(STAGE/'plan.json',plan)
    print('PREPARED_FIVE_BACKEND_MODULES_AND_FEATURE_DROPIN')

def install(manifest, rollback):
    revision = 'before' if rollback else 'after'
    for path, item in manifest.items():
        live = Path(path)
        if item[revision] is None:
            live.unlink(missing_ok=True)
        else:
            source = STAGE / (str(item['slot']) + '.' + revision)
            atomic(live,source.read_bytes())

def apply(rollback):
    plan = json.loads((STAGE/'plan.json').read_text())
    check_pins(plan, applied=rollback)
    if not rollback and target_stat() != plan['targetBefore']:
        raise RuntimeError('Target identity drift')
    manifest = json.loads((STAGE/'manifest.json').read_text())
    expected_paths = {str(LIVE/name) for name in EXPECTED} | {str(DROPIN)}
    if set(manifest) != expected_paths:
        raise RuntimeError('Unexpected release paths')
    for path, item in manifest.items():
        for revision in ('before','after'):
            staged = STAGE / (str(item['slot']) + '.' + revision)
            if digest(staged) != item[revision]:
                raise RuntimeError('Staged source drift')
        if Path(path).is_symlink():
            raise RuntimeError('Symlink deployment refused')
    with ExitStack() as stack:
        for name in ('.discovery.lock','.publisher.lock'):
            handle = stack.enter_context((STATE/name).open('rb'))
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        idle()
        stopped = changed = False
        folder = STAGE / (('rollback-' if rollback else 'apply-')+str(time.time_ns()))
        try:
            service('stop')
            stopped = True
            idle()
            before = state_digest()
            backup_state(folder)
            if rollback and tombstone_count():
                changed = True
                DROPIN.unlink()
                reload_units()
                service('start')
                stopped = False
                save(folder/'receipt.json',dict(action='disable-feature-retain-tombstone-guards',
                     sourceCommit=COMMIT, health=health(False),
                     stateUnchanged=preserved(before,state_digest())))
                print('DISABLED_DELETE_FEATURE_RETAINED_EXISTING_REMOVAL_GUARDS')
                return
            changed = True
            install(manifest, rollback)
            for path, mode in plan['modes'].items():
                if Path(path).exists():
                    os.chmod(path,mode)
            reload_units()
            service('start')
            stopped = False
            status = health(not rollback)
            after = state_digest()
            same = preserved(before,after)
            target_after = target_stat() if TARGET.exists() else None
            target_same = target_after == plan['targetBefore']
            receipt = dict(action='rollback' if rollback else 'apply',sourceCommit=COMMIT,
                health=status,before=before,after=after,
                existingUserStateUnchanged=same,targetFileUnchanged=target_same,
                targetAfter=target_after,checkedUtc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
            save(folder/'receipt.json',receipt)
            save(RECOVERY/'backend-deployment-receipt.json',receipt)
            if not same or (not rollback and not target_same):
                raise RuntimeError('Release state verification differs; preserve user data for inspection')
            print('HEALTHY_R55_'+receipt['action'].upper()+'_EXISTING_USER_STATE_PRESERVED')
            print(json.dumps(status,sort_keys=True))
        except Exception:
            if changed:
                idle()
                service('stop')
                stopped = True
                if not rollback and tombstone_count():
                    if DROPIN.exists():
                        DROPIN.unlink()
                else:
                    install(manifest, not rollback)
                for path, mode in plan['modes'].items():
                    if Path(path).exists():
                        os.chmod(path,mode)
                reload_units()
            if stopped:
                service('start')
            raise

parser=argparse.ArgumentParser()
parser.add_argument('action',choices=['prepare','apply','rollback'])
args=parser.parse_args()
if socket.gethostname().lower() != 'afz-zbook':
    raise RuntimeError('Wrong release host')
with (RECOVERY/'.source-release.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if args.action=='prepare':
        prepare()
    else:
        apply(args.action=='rollback')
