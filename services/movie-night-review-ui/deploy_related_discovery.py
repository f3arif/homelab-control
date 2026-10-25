"""Unfiltered explicit discovery via the tested idle-only source release engine."""
from pathlib import Path
import hashlib,json,shutil,subprocess,sys
import deploy_similar_search as engine
from deploy import Release,ROOT,LIVE,UNIT,atomic,digest,healthy

STAGE=ROOT/'movie-night-related-discovery-20261025'
BASE='5ce966d3ce34bdbd6b579326877601ddf168c173'
FILES=('discovery_policy.py','movie_night.py','similar_movies.py','webapp.py','screen.js','screen.html')


def prepare(source):
    if not (source/'related-target-unit-results.log').read_text().rstrip().endswith('OK'):
        raise RuntimeError('Target unit suite did not pass')
    for name,marker in (
        ('related-browser-results.log','RELATED_SEARCH_REAL_API_BROWSER_PASS_360_412_1280_NO_MEDIA'),
        ('related-popup-results.log','TITLE_POPUP_REAL_API_BROWSER_PASS_360_412_1280_NO_WRITES')):
        if marker not in (source/name).read_text():raise RuntimeError('Required browser verification missing')
    tested=json.loads((source/'qa/related-search/tested-source.json').read_text())
    tested.update(json.loads((source/'qa/title-details/tested-source.json').read_text()))
    tested.update(json.loads((source/'related-tested-source.json').read_text()))
    if any(digest(source/name)!=sha for name,sha in tested.items()):raise RuntimeError('Qualified source changed')
    before={str(UNIT):digest(UNIT)}
    for p in (source/'src').iterdir():
        if p.suffix not in ('.py','.js','.html','.css'):continue
        old=subprocess.check_output(['git','-C',str(source),'show',BASE+':services/movie-night-review-ui/src/'+p.name])
        if (LIVE/p.name).is_symlink() or digest(LIVE/p.name)!=hashlib.sha256(old).hexdigest():
            raise RuntimeError('Unexpected live source: '+p.name)
        before[str(LIVE/p.name)]=digest(LIVE/p.name)
    engine.idle()
    Release(STAGE,{str(LIVE/n):(source/'src'/n).read_bytes() for n in FILES}).prepare()
    atomic(STAGE/'qualified-source.json',json.dumps(tested,indent=2).encode())
    atomic(STAGE/'live-baseline.json',json.dumps(before,indent=2).encode())
    for name in ('deploy_related_discovery.py','deploy_similar_search.py','deploy.py'):shutil.copyfile(source/name,STAGE/name)
    print('PREPARED six runtime files; runtime and user state unchanged')


def verify(rollback):
    # The older verifier assumes every displayed movie follows normal genres;
    # explicit Add now grants a validated per-row exception.
    data=healthy()
    if data.get('selectionLimits')!={'min':3,'max':10,'visible':10} or data.get('autoDownloads') is not True:
        raise RuntimeError('Existing pick/download behavior changed')
    if not rollback:
        sys.path.insert(0,str(LIVE))
        from genre_settings import GenreSettingsStore,GENRES,genre_match
        settings=GenreSettingsStore(engine.STATE).read()
        if data.get('genreSettings')!=dict(settings,options=list(GENRES)):
            raise RuntimeError('Saved genre settings changed')
        if any(not r.get('manualSuggestion') and not genre_match(r,settings) for r in data['movies']):
            raise RuntimeError('Normal shortlist filters changed')
        if data.get('similarSearchEnabled') is not True or b'Your shortlist filters do not limit this search.' not in engine.served(''):
            raise RuntimeError('Unfiltered reference discovery missing')
    if hashlib.sha256(engine.served('screen.js')).hexdigest()!=digest(LIVE/'screen.js'):
        raise RuntimeError('Served script differs from installed source')
    return {'suggestions':len(data['movies']),'finalized':len(data.get('finalized',{}).get('ids',[]))}


def main():
    engine.STAGE,engine.BASE,engine.FILES=STAGE,BASE,FILES
    engine.prepare,engine.verify=prepare,verify
    engine.main()

if __name__=='__main__':main()
