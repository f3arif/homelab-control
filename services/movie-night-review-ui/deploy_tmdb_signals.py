"""TMDB 'Find movies like' release: two source files + one EnvironmentFile= drop-in.

prepare: stage only. apply / rollback: idle-only stop, swap, daemon-reload, start, verify.
Rollback removes tmdb_signals.py and the drop-in and restores similar_movies.py.
The key file itself is never read, staged or printed here.
"""
from pathlib import Path
import argparse, fcntl, hashlib, json, os, socket, subprocess, time
import deploy_similar_search as engine
from deploy import Release, ROOT, LIVE, UNIT, atomic, digest

STAGE = ROOT / 'movie-night-tmdb-signals-20261104'
BASE = 'd0a954b4adc7f4b643d489284a7b98b636dac7ed'  # PR #340, live since 2026-11-04
FILES = ('similar_movies.py', 'tmdb_signals.py')
KEY = ROOT / 'private/tmdb.env'
DROPIN = UNIT.parent / (UNIT.name + '.d') / 'tmdb.conf'
DROPIN_TEXT = ('[Service]\nEnvironmentFile=%s\n' % KEY).encode()


def targets():
    return {str(LIVE / n) for n in FILES} | {str(DROPIN)}


def reload_units():
    subprocess.run(['systemctl', '--user', 'daemon-reload'], env=engine.ENV, check=True, timeout=30)


def prepare(source):
    if not (source / 'tmdb-signals-unit-results.log').read_text().rstrip().endswith('OK'):
        raise RuntimeError('Target unit suite did not pass')
    st = KEY.stat()
    if st.st_mode & 0o077 or st.st_uid != os.getuid() or (KEY.parent.stat().st_mode & 0o077):
        raise RuntimeError('Key file must be mode 600 in a 700 directory')
    if DROPIN.exists() or DROPIN.parent.exists() and any(DROPIN.parent.iterdir()):
        raise RuntimeError('Unexpected existing drop-in')
    before = {str(UNIT): digest(UNIT)}
    for p in (source / 'src').iterdir():
        if p.suffix not in ('.py', '.js', '.html', '.css'):
            continue
        try:
            old = subprocess.check_output(['git', '-C', str(source), 'show', BASE + ':services/movie-night-review-ui/src/' + p.name], stderr=subprocess.DEVNULL)
            old_hash = hashlib.sha256(old).hexdigest()
        except subprocess.CalledProcessError:
            old_hash = None  # new in this release
        if (LIVE / p.name).is_symlink() or digest(LIVE / p.name) != old_hash:
            raise RuntimeError('Unexpected live source: ' + p.name)
        before[str(LIVE / p.name)] = digest(LIVE / p.name)
    engine.idle()
    files = {str(LIVE / n): (source / 'src' / n).read_bytes() for n in FILES}
    files[str(DROPIN)] = DROPIN_TEXT
    Release(STAGE, files).prepare()
    atomic(STAGE / 'live-baseline.json', json.dumps(before, indent=2).encode())
    for name in ('deploy_tmdb_signals.py', 'deploy_similar_search.py', 'deploy.py'):
        (STAGE / name).write_bytes((source / name).read_bytes())
    print('PREPARED 2 source files + drop-in; runtime and user state unchanged')


def run(action):
    with (STAGE / '.deploy.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = json.loads((STAGE / 'manifest.json').read_text())
        if set(manifest) != targets():
            raise RuntimeError('Unexpected release scope')
        rollback = action == 'rollback'
        expected = 'after' if rollback else 'before'
        for path, row in manifest.items():
            if Path(path).is_symlink() or digest(Path(path)) != row[expected]:
                raise RuntimeError('Live drift; no changes')
        for path, sha in json.loads((STAGE / 'live-baseline.json').read_text()).items():
            if path not in manifest and digest(Path(path)) != sha:
                raise RuntimeError('Unrelated runtime drift; no changes')
        engine.idle()
        changed = False
        try:
            engine.service('stop')
            engine.idle()
            folder = STAGE / (action + '-' + str(time.time_ns()))
            folder.mkdir(mode=0o700)
            engine.backup(folder)
            before = engine.state_digest()
            changed = True
            if not rollback:
                DROPIN.parent.mkdir(mode=0o700, exist_ok=True)
            Release(STAGE, {}).swap(rollback)
            if rollback and DROPIN.parent.exists() and not any(DROPIN.parent.iterdir()):
                DROPIN.parent.rmdir()
            reload_units()
            engine.service('start')
            result = engine.verify(rollback)
            files = subprocess.check_output(['systemctl', '--user', 'show', '-p', 'EnvironmentFiles', 'afz-movie-night-review.service'],
                                            env=engine.ENV, text=True, timeout=30)
            if (str(KEY) in files) == rollback:
                raise RuntimeError('EnvironmentFile state does not match release')
            after = engine.state_digest()
            atomic(folder / 'receipt.json', json.dumps({'action': action, 'before': before, 'after': after,
                                                        'stateUnchanged': before == after, **result}, indent=2).encode())
            if before != after:
                raise RuntimeError('State changed during release; retain evidence for review')
            print('HEALTHY', action, json.dumps(result), 'STATE_UNCHANGED')
        except Exception:
            if changed:
                engine.service('stop')
                for path, row in manifest.items():
                    if digest(Path(path)) not in (row['before'], row['after']):
                        raise RuntimeError('Unexpected drift; manual recovery required')
                for path, row in manifest.items():
                    if row[expected] is None:
                        Path(path).unlink(missing_ok=True)
                    else:
                        atomic(Path(path), (STAGE / f"{row['slot']}.{expected}").read_bytes())
                reload_units()
                atomic(STAGE / 'status.txt', ('recovered-' + action).encode())
            engine.service('start')
            engine.healthy()
            raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'apply', 'rollback'])
    action = parser.parse_args().action
    if socket.gethostname() != 'afz-zbook':
        raise RuntimeError('This release belongs on ZBook')
    if action == 'prepare':
        return prepare(Path(__file__).resolve().parent)
    return run(action)


if __name__ == '__main__':
    main()
