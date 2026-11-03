#!/usr/bin/env python3
"""Pinned idle-only source rollout; rollback never restores user databases."""
from contextlib import ExitStack, closing
from pathlib import Path
import argparse
import fcntl
import hashlib
import http.client
import json
import os
import socket
import sqlite3
import stat
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
QA = Path('/home/coolyo/AFZ/QA/MovieNight/20261103-mobile-selection')
STATE = Path('/home/coolyo/afz-stremio-secondhost-20260918/state/movie-night-review')
ENV = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000', DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')
UNIT = 'afz-movie-night-review.service'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None

def atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        os.chmod(f.name, mode); f.write(data); f.flush(); os.fsync(f.fileno())
        name = f.name
    os.replace(name, path)

def connect(name):
    return sqlite3.connect((STATE / name).as_uri() + '?mode=ro', uri=True, timeout=10)

def idle():
    with connect('preferences.sqlite3') as db:
        if db.execute("SELECT count(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:
            raise RuntimeError('Active server transfer; defer release')
        if db.execute("SELECT count(*) FROM movie_download_queue WHERE state IN ('queued','checking')").fetchone()[0]:
            raise RuntimeError('Pending source request; defer release')

def state_digest():
    result = {}
    for name in ('preferences.sqlite3', 'download-index.sqlite3'):
        with connect(name) as db:
            db.execute('BEGIN')
            tables = {}
            for table, schema in db.execute("SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall():
                if not table.replace('_', '').isalnum(): raise RuntimeError('Unexpected table name')
                rows = db.execute('SELECT * FROM "' + table + '" ORDER BY rowid').fetchall()
                data = json.dumps([schema, rows], separators=(',', ':'), default=lambda x: x.hex() if isinstance(x, bytes) else str(x))
                tables[table] = {'rows':len(rows), 'sha256':hashlib.sha256(data.encode()).hexdigest()}
            result[name] = tables
    for name in ('genre-settings.json', 'similar-suggestions.json', 'reviewed-shortlist.json'):
        result[name] = digest(STATE / name)
    return result

def unchanged(before, after):
    for name, content in before.items():
        if isinstance(content, dict):
            if any(after[name].get(table) != value for table, value in content.items()): return False
            added = set(after[name]) - set(content)
            if added - {'movie_mobile_selections'}: return False
            if 'movie_mobile_selections' in added and after[name]['movie_mobile_selections']['rows'] != 0: return False
        elif after[name] != content: return False
    return True

def backup_state(folder):
    folder.mkdir(mode=0o700)
    for name in ('preferences.sqlite3', 'download-index.sqlite3'):
        with connect(name) as source, sqlite3.connect(folder / name) as target: source.backup(target)
        (folder / name).chmod(0o600)
    for name in ('genre-settings.json', 'similar-suggestions.json', 'reviewed-shortlist.json'):
        if (STATE / name).exists(): atomic(folder / name, (STATE / name).read_bytes())

def service(action):
    subprocess.run(['systemctl', '--user', action, UNIT], env=ENV, check=True, timeout=45, capture_output=True)

class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5); self.sock.connect(str(STATE / 'run/review.sock'))

def health(rollback):
    service('is-active')
    for _ in range(30):
        connection = UnixConnection('localhost', timeout=5)
        try:
            connection.request('GET', '/movie-night/api/add-session', headers={'X-AFZ-Review-Principal':'billing-owner'})
            r = connection.getresponse(); payload = json.loads(r.read())
            if r.status != 200 or payload.get('addEnabled') is not True: raise RuntimeError('Review API unhealthy')
            if not rollback and payload.get('selectionDownloadEnabled') is not True: raise RuntimeError('Selection download not active')
            return
        except (OSError, ConnectionError): time.sleep(.1)
        finally: connection.close()
    raise RuntimeError('Review socket unavailable')

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('action', choices=['prepare','apply','rollback'])
    parser.add_argument('--manifest', type=Path, default=HERE / 'selection-release.json')
    args = parser.parse_args()
    release = json.loads(args.manifest.read_text())
    if socket.gethostname().lower() != release['hostname']: raise RuntimeError('Wrong release host')
    live, candidate = Path(release['live']), Path(release['candidate'])
    stage = QA / ('release-' + release['releaseId']); stage.mkdir(exist_ok=True, mode=0o700)
    with ExitStack() as stack:
        lock = stack.enter_context((stage / '.source-release.lock').open('a'))
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'prepare':
            if (stage / 'manifest.json').exists(): raise RuntimeError('Already prepared; inspect before continuing')
            for name, expected in release['baseline'].items():
                if (live / name).is_symlink() or digest(live / name) != expected: raise RuntimeError('Live source drift: ' + name)
            manifest = {}
            for name, expected in release['after'].items():
                if (candidate / name).is_symlink() or digest(candidate / name) != expected: raise RuntimeError('Candidate differs: ' + name)
                mode = stat.S_IMODE((live / name).stat().st_mode) if (live / name).exists() else 0o644
                if (live / name).exists(): atomic(stage / (name + '.before'), (live / name).read_bytes())
                atomic(stage / (name + '.after'), (candidate / name).read_bytes())
                manifest[name] = {'before':release['baseline'][name], 'after':expected, 'mode':mode}
            atomic(stage / 'manifest.json', json.dumps(manifest, indent=2).encode())
            print('PREPARED', len(manifest), 'FILES_RUNTIME_UNCHANGED'); return
        manifest = json.loads((stage / 'manifest.json').read_text())
        if set(manifest) != set(release['after']): raise RuntimeError('Release scope differs')
        rollback = args.action == 'rollback'; expected = 'after' if rollback else 'before'
        for name, baseline in release['baseline'].items():
            wanted = manifest[name][expected] if name in manifest else baseline
            if (live / name).is_symlink() or digest(live / name) != wanted: raise RuntimeError('Runtime drift: ' + name)
        for name, row in manifest.items():
            for version in ('before','after'):
                if digest(stage / (name + '.' + version)) != row[version]: raise RuntimeError('Staged source drift')
        idle()
        for name in ('.discovery.lock','.publisher.lock'):
            f = stack.enter_context((STATE / name).open('rb')); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        stopped = changed = False
        try:
            service('stop'); stopped = True; idle()
            before = state_digest()
            folder = stage / (args.action + '-' + str(time.time_ns())); backup_state(folder)
            changed = True
            for name, row in manifest.items():
                source = stage / (name + ('.before' if rollback else '.after'))
                if source.exists(): atomic(live / name, source.read_bytes(), row['mode'])
                else: (live / name).unlink()
            service('start'); stopped = False; health(rollback)
            after = state_digest(); preserved = unchanged(before, after)
            atomic(folder / 'receipt.json', json.dumps({'sourceCommit':release['sourceCommit'], 'action':args.action,
                   'before':before,'after':after,'existingUserStateUnchanged':preserved,
                   'installed':{name:digest(live/name) for name in manifest},
                   'checkedUtc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}, indent=2).encode())
            if not preserved: raise RuntimeError('State changed during release; preserve user data and inspect')
            atomic(QA / 'deployment-receipt.json', (folder / 'receipt.json').read_bytes())
            print('HEALTHY_SELECTION_DOWNLOAD_' + args.action.upper() + '_EXISTING_USER_STATE_PRESERVED')
        except Exception:
            if changed:
                idle()  # never interrupt a newly started transfer to roll back code
                service('stop'); stopped = True
                for name, row in manifest.items():
                    source = stage / (name + ('.after' if rollback else '.before'))
                    if source.exists(): atomic(live / name, source.read_bytes(), row['mode'])
                    elif (live / name).exists(): (live / name).unlink()
            if stopped: service('start')
            raise

if __name__ == '__main__': main()

