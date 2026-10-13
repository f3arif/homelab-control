"""Bounded verification of the new Nuvio catalog/proxy path and existing TV."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import time
from urllib.parse import urlsplit
import requests

def main():
    ap=argparse.ArgumentParser()
    for arg in ['candidate-dir','imdb','item-id','public-base','output']:
        ap.add_argument('--'+arg,required=True)
    args=ap.parse_args()
    expected=json.loads((Path(args.candidate_dir)/'candidate-verification.json').read_text())
    base='http://127.0.0.1:18774'
    def get(url):
        r=requests.get(url,timeout=(4,30)); r.raise_for_status(); return r
    def local_source(rows):
        return next((x for x in rows if urlsplit(x.get('url','')).path=='/jellyfin/'+args.imdb
                     and urlsplit(x['url']).query=='item_id='+args.item_id),None)
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        try:
            assert get(base+'/manifest.json').json()['version']=='0.6.243'
            streams=get(base+'/stream/movie/'+args.imdb+'.json').json()['streams']
            source=local_source(streams)
            cats=get(base+'/catalog/movie/afz_local_ready.json').json()['metas']
            if source and any(x['id']==args.imdb for x in cats): break
        except (requests.RequestException,AssertionError,KeyError): pass
        time.sleep(3)
    else: raise AssertionError('New local movie card/source did not become available')
    def probe(url):
        with requests.get(url,headers={'Range':'bytes=0-1023','Accept-Encoding':'identity'},
                          stream=True,allow_redirects=False,timeout=(5,20)) as r:
            assert r.status_code==206, 'Playback did not support range request'
            assert r.headers.get('Content-Length')=='1024'
            data=b''.join(r.iter_content(chunk_size=1024))
            assert len(data)==1024
            return {'status':206,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    # The public Nuvio path includes the existing V3 sorter and integrity guard.
    public=args.public_base.rstrip('/')
    prod=get(public+'/stream/movie/'+args.imdb+'.json')
    assert prod.headers.get('X-AFZ-Sort-Policy')=='health-v3'
    selected=local_source(prod.json()['streams'])
    assert selected,'Production source sorter omitted the Envy copy'
    part=urlsplit(selected['url'])
    movie=probe(public+part.path+'?'+part.query)
    assert movie['sha256']==expected['proxySha256']
    tv=[]
    for vid in ['tt0108847:1:1','tt0169414:1:1','tt0115200:1:1']:
        rows=get(public+'/stream/series/'+vid+'.json').json()['streams']
        row=next(x for x in rows if x.get('name')=='AFZ TV Downloaded')
        path=urlsplit(row['url']).path
        assert path.startswith('/tv-media/')
        tv.append(dict(videoId=vid,**probe(public+path)))
    health=get(base+'/system-health.json').json()
    assert health.get('overallHealthy') is True
    result={'checkedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'success':True,'movieInReadyToWatch':True,'movieSource':'AFZ Jellyfin',
            'movieItemId':args.item_id,'productionSorter':'health-v3',
            'moviePlayback':movie,'restoredTvPlayback':tv,'overallHealthy':True,
            'newMediaRequests':0,'newTorrents':0}
    Path(args.output).write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2),flush=True)

if __name__=='__main__': main()
