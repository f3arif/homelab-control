"""Idle-only ZBook release with guarded source rollback; never restore user data."""
from pathlib import Path
import argparse, fcntl, hashlib, http.client, json, os, shutil, socket, sqlite3, subprocess, time
from deploy import Release, ROOT, LIVE, UNIT, digest, atomic, healthy

STAGE = ROOT / 'movie-night-genre-variety-20261024'
BASE = 'def2b37b87640ddc182dc0b4e5616921aa4adc67'
FILES = ('feedback.py', 'movie_night.py', 'screen.js', 'screen.html')
ENV = dict(os.environ, XDG_RUNTIME_DIR='/run/user/1000', DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus')
STATE = ROOT / 'state/movie-night-review'


def service(action):
    subprocess.run(['systemctl', '--user', action, 'afz-movie-night-review.service'], env=ENV, check=True, timeout=45)


def connect(name):
    return sqlite3.connect((STATE / name).as_uri() + '?mode=ro', uri=True, timeout=10)


def idle():
    with connect('preferences.sqlite3') as db:
        if db.execute("SELECT count(*) FROM jobs WHERE state IN ('approved','downloading')").fetchone()[0]:
            raise RuntimeError('Active transfer; defer this release')
        if db.execute("SELECT count(*) FROM movie_download_queue WHERE state IN ('queued','checking')").fetchone()[0]:
            raise RuntimeError('Pending source check; defer this release')


def state_digest():
    result = {}
    for name in ('preferences.sqlite3', 'download-index.sqlite3'):
        with connect(name) as db:
            db.execute('BEGIN')
            result[name] = hashlib.sha256('\n'.join(db.iterdump()).encode()).hexdigest()
    return result


def backup(folder):
    for name in ('preferences.sqlite3', 'download-index.sqlite3'):
        with connect(name) as db, sqlite3.connect(folder / name) as target:
            db.backup(target)
        (folder / name).chmod(0o600)


def served(name):
    class UnixConnection(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.settimeout(5)
            self.sock.connect(str(STATE / 'run/review.sock'))
    c = UnixConnection('localhost', timeout=5)
    try:
        c.request('GET', '/movie-night/' + name, headers={'X-AFZ-Review-Principal': 'billing-owner'})
        r = c.getresponse()
        body = r.read()
        if r.status != 200:
            raise RuntimeError('Served page unavailable')
        return body
    finally:
        c.close()


def verify(rollback):
    data = healthy()
    if data.get('selectionLimits') != {'min': 3, 'max': 10, 'visible': 10} or data.get('autoDownloads') is not True:
        raise RuntimeError('Existing pick/download behavior changed')
    if not rollback:
        if any(row.get('similarToLiked') is not False for row in data['movies']):
            raise RuntimeError('Genre-only preference not active')
        if b'id="genre-guidance"' not in served(''):
            raise RuntimeError('New guidance missing')
    if hashlib.sha256(served('screen.js')).hexdigest() != digest(LIVE / 'screen.js'):
        raise RuntimeError('Served script does not match installed source')
    return {'suggestions': len(data['movies']), 'finalized': len(data.get('finalized', {}).get('ids', []))}


def prepare(source):
    if not (source / 'genre-target-unit-results.log').read_text().rstrip().endswith('OK'):
        raise RuntimeError('Target unit suite did not pass')
    if 'CARD_STATUS_BROWSER_PASS_360_412_1280_NO_WRITES' not in (source / 'genre-target-browser-results.log').read_text():
        raise RuntimeError('Target browser verification missing')
    tested = json.loads((source / 'genre-tested-source.json').read_text())
    for name, sha in tested.items():
        if digest(source / name) != sha:
            raise RuntimeError('Source changed since qualification')
    browser = json.loads((source / 'qa/card-status/tested-source.json').read_text())
    if any(digest(source / 'src' / n) != sha for n, sha in browser.items()):
        raise RuntimeError('Browser-tested source changed')
    before = {str(UNIT): digest(UNIT)}
    for p in (source / 'src').iterdir():
        if p.suffix not in ('.py', '.js', '.html', '.css'):
            continue
        old = subprocess.check_output(['git', '-C', str(source), 'show', BASE + ':services/movie-night-review-ui/src/' + p.name])
        if digest(LIVE / p.name) != hashlib.sha256(old).hexdigest():
            raise RuntimeError('Unexpected live source: ' + p.name)
        before[str(LIVE / p.name)] = digest(LIVE / p.name)
    idle()
    Release(STAGE, {str(LIVE / n): (source / 'src' / n).read_bytes() for n in FILES}).prepare()
    atomic(STAGE / 'qualified-source.json', json.dumps(tested, indent=2).encode())
    atomic(STAGE / 'live-baseline.json', json.dumps(before, indent=2).encode())
    for name in ('deploy_genre_variety.py', 'deploy.py'):
        shutil.copyfile(source / name, STAGE / name)
    print('PREPARED four files; runtime and user state unchanged')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'apply', 'rollback'])
    action = parser.parse_args().action
    if socket.gethostname() != 'afz-zbook':
        raise RuntimeError('This release belongs on ZBook')
    if action == 'prepare':
        return prepare(Path(__file__).resolve().parent)
    with (STAGE / '.deploy.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = json.loads((STAGE / 'manifest.json').read_text())
        if set(manifest) != {str(LIVE / n) for n in FILES}:
            raise RuntimeError('Unexpected release scope')
        rollback = action == 'rollback'
        expected = 'after' if rollback else 'before'
        for path, row in manifest.items():
            if Path(path).is_symlink() or digest(Path(path)) != row[expected]:
                raise RuntimeError('Live source drift; no changes')
            for version in ('before', 'after'):
                if digest(STAGE / f"{row['slot']}.{version}") != row[version]:
                    raise RuntimeError('Stage drift; no changes')
        for path, sha in json.loads((STAGE / 'live-baseline.json').read_text()).items():
            if path not in manifest and digest(Path(path)) != sha:
                raise RuntimeError('Unrelated runtime drift; no changes')
        idle()
        changed = False
        try:
            service('stop')
            idle()  # Recheck after requests and workers have stopped.
            folder = STAGE / (action + '-' + str(time.time_ns()))
            folder.mkdir(mode=0o700)
            backup(folder)
            before = state_digest()
            atomic(folder / 'before.json', json.dumps(before).encode())
            changed = True
            Release(STAGE, {}).swap(rollback)
            service('start')
            result = verify(rollback)
            after = state_digest()
            atomic(folder / 'receipt.json', json.dumps({'action': action, 'before': before, 'after': after, 'stateUnchanged': before == after, **result}, indent=2).encode())
            if before != after:
                raise RuntimeError('State changed during release; retain evidence for review')
            print('HEALTHY', action, json.dumps(result), 'STATE_UNCHANGED')
        except Exception:
            if changed:
                service('stop')
                # Recover even a partial file swap, but never overwrite outside drift.
                for path, row in manifest.items():
                    if digest(Path(path)) not in (row['before'], row['after']):
                        raise RuntimeError('Unexpected source drift; manual recovery required')
                for path, row in manifest.items():
                    atomic(Path(path), (STAGE / f"{row['slot']}.{expected}").read_bytes())
                atomic(STAGE / 'status.txt', ('recovered-' + action).encode())
            service('start')
            healthy()
            raise


if __name__ == '__main__':
    main()
