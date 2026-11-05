"""One-file 'Find movies like' relevance fix using the tested idle-only backend release engine.

prepare: stage only (no runtime change). apply / rollback: idle-only stop, swap similar_movies.py, start.
Requires the owner's explicit go before apply.
"""
from pathlib import Path
import hashlib, json, shutil, subprocess
import deploy_similar_search as engine
from deploy import Release, ROOT, LIVE, UNIT, atomic, digest

STAGE = ROOT / 'movie-night-similar-quality-20261104'
BASE = 'b45c1868b7f7e7460dab959a510950583858c993'  # PR #338 head, live on ZBook 2026-11-04
FILES = ('similar_movies.py',)


def prepare(source):
    if not (source / 'similar-quality-unit-results.log').read_text().rstrip().endswith('OK'):
        raise RuntimeError('Target unit suite did not pass')
    before = {str(UNIT): digest(UNIT)}
    for p in (source / 'src').iterdir():
        if p.suffix not in ('.py', '.js', '.html', '.css'):
            continue
        old = subprocess.check_output(['git', '-C', str(source), 'show', BASE + ':services/movie-night-review-ui/src/' + p.name])
        if (LIVE / p.name).is_symlink() or digest(LIVE / p.name) != hashlib.sha256(old).hexdigest():
            raise RuntimeError('Unexpected live source: ' + p.name)
        before[str(LIVE / p.name)] = digest(LIVE / p.name)
    engine.idle()
    Release(STAGE, {str(LIVE / n): (source / 'src' / n).read_bytes() for n in FILES}).prepare()
    atomic(STAGE / 'live-baseline.json', json.dumps(before, indent=2).encode())
    for name in ('deploy_similar_quality.py', 'deploy_similar_search.py', 'deploy.py'):
        shutil.copyfile(source / name, STAGE / name)
    print('PREPARED one backend file; runtime and user state unchanged')


def main():
    engine.STAGE, engine.BASE, engine.FILES = STAGE, BASE, FILES
    engine.prepare = prepare
    engine.main()


if __name__ == '__main__':
    main()
