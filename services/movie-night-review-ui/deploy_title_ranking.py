"""One-file lookup repair using the tested idle-only backend release engine."""
from pathlib import Path
import hashlib, json, shutil, subprocess
import deploy_similar_search as engine
from deploy import Release, ROOT, LIVE, UNIT, atomic, digest

STAGE = ROOT / 'movie-night-title-ranking-20261024'
BASE = '5b6bbea9491a5968ac6d6e264e1dfd721de77eee'
FILES = ('similar_movies.py',)


def prepare(source):
    if not (source / 'ranking-target-unit-results.log').read_text().rstrip().endswith('OK'):
        raise RuntimeError('Target unit suite did not pass')
    if 'TITLE_POPUP_REAL_API_BROWSER_PASS_360_412_1280_NO_WRITES' not in (source / 'ranking-browser-results.log').read_text():
        raise RuntimeError('Title popup API/browser verification missing')
    tested = json.loads((source / 'qa/title-popup/tested-source.json').read_text())
    tested.update(json.loads((source / 'ranking-tested-source.json').read_text()))
    if any(digest(source / name) != sha for name, sha in tested.items()):
        raise RuntimeError('Qualified source changed')
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
    atomic(STAGE / 'qualified-source.json', json.dumps(tested, indent=2).encode())
    atomic(STAGE / 'live-baseline.json', json.dumps(before, indent=2).encode())
    for name in ('deploy_title_ranking.py', 'deploy_similar_search.py', 'deploy.py'):
        shutil.copyfile(source / name, STAGE / name)
    print('PREPARED one backend file; runtime and user state unchanged')


def main():
    engine.STAGE, engine.BASE, engine.FILES = STAGE, BASE, FILES
    engine.prepare = prepare
    engine.main()


if __name__ == '__main__':
    main()
