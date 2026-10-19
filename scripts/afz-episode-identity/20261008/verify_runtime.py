"""Bounded list/resolver checks; never select or queue a media download."""
import datetime
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse,unquote
import requests
from test_episode_identity import load

ROOT=Path(__file__).parent
BASE='http://127.0.0.1:18774'
VID='tt0108778:1:1'
matches=load(ROOT/'stremio_catalog.py')['_series_release_matches']
def get(path):
    r=requests.get(BASE+path,timeout=35);r.raise_for_status();return r.json()

if len(sys.argv)>1 and sys.argv[1]=='baseline':
    obj=get('/stream/series/'+VID+'.json')
    # Provider responses change over time. Preserve an actual currently
    # excluded file token, rather than assuming the old wrong Auto remains.
    wrong=next((x for x in obj['streams'] if x.get('url') and '/external-stream/' in x['url'] and not matches(('Friends','1994'),1,1,{'filename':(x.get('behaviorHints') or {}).get('filename')})),None)
    if wrong is None:
        # A follow-up revision can start from the already-filtered deployment.
        # Keep its earlier excluded token for the same post-deploy resolver check.
        old=json.loads((ROOT/'old-excluded-token.json').read_text())
        assert old['videoId']==VID and re.fullmatch('[a-f0-9]{20,64}',old['token'])
        assert any(x.get('url') and '/external-stream/' in x['url'] for x in obj['streams'])
        print(json.dumps({'status':'already-filtered-baseline','excludedTokenPreserved':True}))
        sys.exit(0)
    token=unquote(urlparse(wrong['url']).path.split('/')[-1])
    assert re.fullmatch('[a-f0-9]{20,64}',token)
    (ROOT/'old-excluded-token.json').write_text(json.dumps({'videoId':VID,'token':token,'filename':wrong['behaviorHints']['filename']}),encoding='utf-8')
    print(json.dumps({'status':'baseline-excluded-file-recorded','excludedFilename':wrong['behaviorHints']['filename']}))
    sys.exit(0)

report={'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'cases':[],'mediaPlayed':False,'mediaDownloadQueued':False}
manifest=get('/manifest.json')
assert manifest['id']=='com.afzengineering.releasecatalog' and manifest['version']=='0.6.243'
report['manifestVersion']=manifest['version']
friends=get('/stream/series/'+VID+'.json')['streams']
playable=[x for x in friends if x.get('url') and '/external-stream/' in x['url']]
assert playable, 'No matching Friends file remains'
assert all(matches(('Friends','1994'),1,1,{'filename':(x.get('behaviorHints') or {}).get('filename')}) for x in playable), 'Unverified show remains'
auto=next(x for x in playable if x.get('name')=='AFZ TV Auto')
report['cases'].append({'videoId':VID,'canonicalTitle':'Friends','playableCount':len(playable),'autoFilename':auto['behaviorHints']['filename'],'wrongShowCount':0,'names':[x.get('name') for x in friends]})
arthur=get('/stream/series/tt0169414:1:1.json')['streams']
assert any(x.get('name')=='AFZ TV Downloaded' and "Arthur's Eyes" in x.get('title','') for x in arthur)
assert not any('Arthur (2015)' in x.get('title','') for x in arthur)
report['cases'].append({'videoId':'tt0169414:1:1','canonicalTitle':'Arthur','localFilePreserved':True,'wrongYearAbsent':True,'streams':[{'name':x.get('name'),'filename':(x.get('behaviorHints') or {}).get('filename')} for x in arthur]})
old=json.loads((ROOT/'old-excluded-token.json').read_text())
r=requests.head(BASE+'/external-stream/'+old['videoId']+'/'+old['token'],timeout=15,allow_redirects=False)
assert r.status_code==404, 'Previously excluded episode token still accepted'
report['oldExcludedResolverStatus']=r.status_code
report['excludedFilename']=old['filename']
report['passed']=True
(ROOT/'runtime-verification.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,indent=2))
