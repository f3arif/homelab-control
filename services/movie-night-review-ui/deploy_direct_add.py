#!/usr/bin/env python3
"""Pinned, idle-only Add movie rollout. Rollback restores source, never user data."""
import argparse
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import stat
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = Path('/home/coolyo/afz-stremio-secondhost-20260918')
QA = Path('/home/coolyo/AFZ/QA/MovieNight/20261101-manual-add')
STATE = ROOT / 'state/movie-night-review'
ENV = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000', DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

def atomic(path, data, mode=0o600):
    temporary = path.with_name(path.name + '.r59-' + str(os.getpid()))
    with temporary.open('xb') as f:
        os.chmod(temporary, mode)
        f.write(data); f.flush(); os.fsync(f.fileno())
    os.replace(temporary, path)

def connect(name):
    return sqlite3.connect((STATE / name).as_uri() + '?mode=ro', uri=True, timeout=10)

def idle():
    with connect('preferences.sqlite3') as db:
        if db.execute("SELECT count(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:
            raise RuntimeError('Active server transfer; defer release')
        if db.execute("SELECT count(*) FROM movie_download_queue WHERE state IN ('queued','checking')").fetchone()[0]:
            raise RuntimeError('Pending media request; defer release')
    for name in ('.discovery.lock', '.publisher.lock'):
        with (STATE / name).open('rb') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)

def state_digest():
    result = {}
    for name in ('preferences.sqlite3', 'download-index.sqlite3'):
        with connect(name) as db:
            db.execute('BEGIN')
            result[name] = hashlib.sha256('\n'.join(db.iterdump()).encode()).hexdigest()
    for name in ('genre-settings.json', 'similar-suggestions.json'):
        result[name] = digest(STATE / name)
    return result

def backup_state(folder):
    for name in ('preferences.sqlite3', 'download-index.sqlite3'):
        with connect(name) as source, sqlite3.connect(folder / name) as target:
            source.backup(target)
        (folder / name).chmod(0o600)
    for name in ('genre-settings.json', 'similar-suggestions.json'):
        if (STATE / name).exists():
            atomic(folder / name, (STATE / name).read_bytes())

def service(role, action):
    unit = 'afz-movie-night-' + ('review' if role == 'backend' else 'access') + '.service'
    subprocess.run(['systemctl', '--user', action, unit], env=ENV, check=True, timeout=45)

def health(role, rollback):
    service(role, 'is-active')
    if role != 'backend':
        return
    class UnixConnection(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(5)
            self.sock.connect(str(STATE / 'run/review.sock'))
    for attempt in range(20):
        connection = UnixConnection('localhost', timeout=5)
        try:
            connection.request('GET', '/movie-night/api/shortlist', headers={'X-AFZ-Review-Principal': 'billing-owner'})
            response = connection.getresponse(); data = json.loads(response.read())
            if response.status != 200 or data.get('selectionLimits') != {'min': 3, 'max': 10, 'visible': 10}:
                raise RuntimeError('Existing review API unhealthy')
            if data.get('autoDownloads') is not True or (not rollback and data.get('directAddEnabled') is not True):
                raise RuntimeError('Qualified feature flags differ')
            return
        except (ConnectionError, OSError):
            if attempt == 19: raise
            time.sleep(0.25)
        finally:
            connection.close()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('role', choices=['backend', 'gateway'])
    parser.add_argument('action', choices=['prepare', 'apply', 'rollback'])
    args = parser.parse_args()
    release = json.loads((HERE / 'direct-add-release.json').read_text())
    config = release[args.role]
    if socket.gethostname().lower() != config['hostname']:
        raise RuntimeError('Wrong release host')
    live = Path(config['live']); stage = QA / ('release-' + args.role)
    stage.mkdir(parents=True, exist_ok=True, mode=0o700); stage.chmod(0o700)
    with (stage / '.release.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'prepare':
            if (stage / 'manifest.json').exists(): raise RuntimeError('Release already prepared; inspect it')
            for name, expected in config['baseline'].items():
                if (live / name).is_symlink() or digest(live / name) != expected:
                    raise RuntimeError('Live source drift: ' + name)
            manifest = {}
            for name, expected in config['after'].items():
                source = HERE / config['candidate'] / name
                if source.is_symlink() or digest(source) != expected: raise RuntimeError('Candidate differs: ' + name)
                mode = stat.S_IMODE((live / name).stat().st_mode)
                atomic(stage / (name + '.before'), (live / name).read_bytes())
                atomic(stage / (name + '.after'), source.read_bytes())
                manifest[name] = {'before': config['baseline'][name], 'after': expected, 'mode': mode}
            atomic(stage / 'manifest.json', json.dumps(manifest, indent=2).encode())
            print('PREPARED', args.role, len(manifest), 'source files; runtime unchanged')
            return
        manifest = json.loads((stage / 'manifest.json').read_text())
        if set(manifest) != set(config['after']): raise RuntimeError('Release scope differs')
        rollback = args.action == 'rollback'; expected = 'after' if rollback else 'before'
        for name, baseline in config['baseline'].items():
            wanted = manifest[name][expected] if name in manifest else baseline
            if (live / name).is_symlink() or digest(live / name) != wanted: raise RuntimeError('Runtime drift: ' + name)
        for name, row in manifest.items():
            for version in ('before', 'after'):
                if digest(stage / (name + '.' + version)) != row[version]: raise RuntimeError('Stage drift')
        if args.role == 'backend': idle()
        folder = stage / (args.action + '-' + str(time.time_ns()))
        folder.mkdir(mode=0o700)
        stopped = False; changed = False
        try:
            service(args.role, 'stop'); stopped = True
            if args.role == 'backend':
                idle(); backup_state(folder); before = state_digest()
            else: before = None
            changed = True
            for name, row in manifest.items():
                atomic(live / name, (stage / (name + ('.before' if rollback else '.after'))).read_bytes(), row['mode'])
            service(args.role, 'start'); stopped = False
            health(args.role, rollback)
            after = state_digest() if args.role == 'backend' else None
            atomic(folder / 'receipt.json', json.dumps({'sourceCommit': release['sourceCommit'], 'role': args.role,
                'action': args.action, 'before': before, 'after': after, 'stateUnchanged': before == after,
                'installed': {name: digest(live / name) for name in manifest}}, indent=2).encode())
            if before != after: raise RuntimeError('User state changed; preserve evidence for review')
            print('HEALTHY', args.role, args.action, 'STATE_UNCHANGED')
        except Exception:
            if changed:
                service(args.role, 'stop'); stopped = True
                for name, row in manifest.items():
                    atomic(live / name, (stage / (name + ('.after' if rollback else '.before'))).read_bytes(), row['mode'])
            if stopped: service(args.role, 'start')
            raise

if __name__ == '__main__':
    main()
