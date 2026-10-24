"""Apply the new genre filters using the tested idle-only, data-preserving release."""
from pathlib import Path
import json, shutil
import deploy_genre_variety as release

release.STAGE=release.ROOT/'movie-night-genre-exclusions-20261024'
release.BASE='8e485681bf7ce4d26b28411b68a979df42937d1a'
release.FILES=('discovery_policy.py','movie_night.py','webapp.py','publish_reviewed.py',
               'reviewed_refill.py','discovery_refill.py','screen.js','screen.html')
original_prepare,original_verify=release.prepare,release.verify


def prepare(source):
    if 'GENRE_EXCLUSIONS_BROWSER_PASS_360_412_1280_NO_WRITES' not in (source/'genre-exclusions-browser-results.log').read_text():
        raise RuntimeError('Exclusion browser verification missing')
    tested=json.loads((source/'qa/genre-exclusions/tested-source.json').read_text())
    if any(release.digest(source/'src'/n)!=sha for n,sha in tested.items()):
        raise RuntimeError('Exclusion browser-tested source changed')
    original_prepare(source)
    shutil.copyfile(source/'deploy_genre_exclusions.py',release.STAGE/'deploy_genre_exclusions.py')


def verify(rollback):
    result=original_verify(rollback)
    if not rollback:
        from discovery_policy import EXCLUDED_GENRES,excluded_genres
        data=release.healthy()
        if data.get('excludedGenres')!=list(EXCLUDED_GENRES) or any(excluded_genres(r) for r in data['movies']):
            raise RuntimeError('New genre exclusions not active')
        if b'No Animation' not in release.served('') or b'No Drama' not in release.served(''):
            raise RuntimeError('New filter labels missing')
        result['excludedSaved']=len(data.get('finalized',{}).get('excludedIds',[]))
    return result


release.prepare,release.verify=prepare,verify
if __name__=='__main__':release.main()
