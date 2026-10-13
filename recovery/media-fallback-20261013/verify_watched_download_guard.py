"""Seed the user-reported exclusion or verify deployed protection, without downloads."""
import argparse
import ast
from datetime import datetime,timezone
import json
from pathlib import Path
import re
import threading
import time
import requests
from fastapi import HTTPException

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--mode',choices=['seed','live'],required=True)
    ap.add_argument('--core-root',type=Path,required=True)
    ap.add_argument('--candidate-dir',type=Path,required=True)
    ap.add_argument('--imdb',required=True)
    ap.add_argument('--title',required=True)
    ap.add_argument('--movie-id',type=int,required=True)
    args=ap.parse_args()
    policy_path=args.core_root/'state/auto-media-download-policy.json'
    if args.mode=='seed':
        wanted={'watched_download_record','auto_media_download_policy_read'}
        tree=ast.parse((args.core_root/'stremio_catalog.py').read_text(encoding='utf-8-sig'))
        body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in wanted]
        assert {n.name for n in body}==wanted
        ns={'json':json,'re':re,'datetime':datetime,'timezone':timezone,'HTTPException':HTTPException,
            'AUTO_MEDIA_DOWNLOAD_POLICY_FILE':policy_path,'auto_media_policy_lock':threading.Lock(),
            'watched_download_wake':threading.Event()}
        exec(compile(ast.Module(body=body,type_ignores=[]),'watched-seed','exec'),ns)
        ns['watched_download_record'](args.imdb,args.title,'user-reported')
        print('USER_REPORTED_WATCHED_EXCLUSION_SAVED')
        return
    base='http://127.0.0.1:18774'
    deadline=time.monotonic()+50
    status=None
    while time.monotonic()<deadline:
        try:
            r=requests.get(base+'/auto-media/watched-guard.json',timeout=(2,4))
            if r.status_code==200:
                status=r.json()
                if status.get('checkedAt') and status.get('radarrChecked'): break
        except requests.RequestException: pass
        time.sleep(1)
    assert status and status.get('radarrChecked'), 'Watched worker did not complete a Radarr check'
    assert args.imdb in status['watchedMovies']
    policy=json.loads(policy_path.read_text())
    assert policy['movies'][args.imdb] is False
    assert policy['movies']['tt27548557'] is False, 'Existing exclusion changed'
    before=policy_path.read_bytes()
    response=requests.post(base+'/auto-media/download-toggle',json={
        'mediaType':'movie','imdbId':args.imdb,'enabled':True,'title':args.title},timeout=15)
    assert response.status_code==409, 'Watched title could be enabled'
    assert policy_path.read_bytes()==before, 'Rejected toggle changed the policy'
    cfg=json.loads((args.core_root/'state/media-requests-connection.json').read_text())['radarr']
    hdr={'X-Api-Key':cfg['apiKey']}
    r=requests.get(cfg['url'].rstrip('/')+'/movie/'+str(args.movie_id),headers=hdr,timeout=15)
    r.raise_for_status(); movie=r.json()
    assert movie['imdbId']==args.imdb and movie['monitored'] is False and movie['hasFile'] is True
    original=json.loads((args.candidate_dir.parent/'oak-before-unmonitor.json').read_text(encoding='utf-8-sig'))
    assert movie['movieFile']['id']==original['movieFile']['id']
    assert movie['movieFile']['size']==original['movieFile']['size']>0
    page=requests.get(base+'/auto-media/title/movie/'+args.imdb,timeout=15)
    assert page.status_code==200 and 'Already watched' in page.text
    result={'verifiedAt':datetime.now(timezone.utc).isoformat(),'success':True,
        'watchedExcluded':True,'radarrUnmonitored':True,'existingFilePreserved':True,
        'allowRejected':response.status_code,'existingPolicyPreserved':True,
        'watchedStatus':status,'note':'Empty Nuvio history still requires device sync; no history was invented.'}
    (args.candidate_dir/'live-verification.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
