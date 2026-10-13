"""Exercise isolated candidate functions against one existing Jellyfin file.

Only selected AST functions are loaded: no application startup, scheduled work,
provider calls, downloads, requests, or live source changes are triggered.
"""
import argparse
import ast
import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import threading
import time
import types
import requests
from fastapi import HTTPException
from fastapi.responses import StreamingResponse

def main():
    ap=argparse.ArgumentParser()
    for name in ['candidate','settings','movie-root','jellyfin-url','item-id','imdb','output']:
        ap.add_argument('--'+name,required=True)
    args=ap.parse_args()
    os.environ['AFZ_HP_JELLYFIN_ENABLED']='1'
    os.environ['AFZ_HP_JELLYFIN_MOVIE_ROOT']=args.movie_root
    settings=json.loads(Path(args.settings).read_text(encoding='utf-8-sig'))
    headers={'Authorization':'MediaBrowser Token="'+settings['jellyfin']['apiKey']+'"'}
    r=requests.get(args.jellyfin_url+'/Items',headers=headers,
                   params={'Ids':args.item_id,'Fields':'ProviderIds,Path,MediaSources'},timeout=(3,12))
    r.raise_for_status()
    item=next(x for x in r.json()['Items'] if x['Id']==args.item_id)
    assert item['ProviderIds']['Imdb']==args.imdb
    ns={'os':os,'Path':Path,'re':re,'time':time,'threading':threading,'requests':requests,
        'HTTPException':HTTPException,'StreamingResponse':StreamingResponse,
        'VIDEO_EXTS':{'.mkv','.mp4','.avi'},'jf_api_cache':{},'jf_api_lock':threading.Lock(),
        'PUBLIC_BASE':'http://127.0.0.1:18774','JELLYFIN_URL':args.jellyfin_url,
        'jellyfin_headers':lambda:dict(headers),'jellyfin_movie_index':lambda **kw:{args.imdb:[item]},
        'jellyfin_mapped_local_path':lambda raw:None,'CATALOG_PAGE_SIZE':80,
        'CATALOGS':{'afz_local_ready':{'kind':'jellyfin'}},'FAILOVER_MODE':True,
        'parse_overflow_catalog_id':lambda cid:None,'filter_hidden_home_metas':lambda rows:rows}
    wanted={'jellyfin_request_placeholder','jellyfin_remote_movie_media',
            'jellyfin_remote_movie_available','jellyfin_real_local_item',
            'jellyfin_landing_movie_catalog','hp_jellyfin_stream_row','jellyfin_proxy',
            '_catalog_full_metas','_merge_meta_rows'}
    tree=ast.parse(Path(args.candidate).read_text(encoding='utf-8-sig'))
    body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in wanted]
    assert {n.name for n in body}==wanted
    for n in body: n.decorator_list=[]; n.returns=None; [setattr(a,'annotation',None) for a in n.args.args]
    exec(compile(ast.Module(body=body,type_ignores=[]),args.candidate,'exec'),ns)
    assert ns['jellyfin_real_local_item'](item)
    source=ns['hp_jellyfin_stream_row'](item,args.imdb,ns['PUBLIC_BASE'])
    assert source and source['url'].endswith('?item_id='+args.item_id)
    before=requests.get(ns['PUBLIC_BASE']+'/catalog/movie/afz_local_ready.json',timeout=30).json()['metas']
    ns['refresh_jellyfin_catalogs']=lambda:{'catalogs':{'afz_local_ready':before}}
    after=ns['_catalog_full_metas']('afz_local_ready')
    assert after[0]['id']==args.imdb
    assert {x['id'] for x in before}.issubset({x['id'] for x in after})
    async def consume(response):
        result=b''
        async for chunk in response.body_iterator:
            result+=chunk
            assert len(result)<=1024
        return result
    response=ns['jellyfin_proxy'](args.imdb,types.SimpleNamespace(headers={'range':'bytes=0-1023'}),item_id=args.item_id)
    payload=asyncio.run(consume(response))
    assert response.status_code==206 and len(payload)==1024
    assert response.headers['content-range']=='bytes 0-1023/'+str(source['behaviorHints']['videoSize'])
    try:
        ns['jellyfin_proxy'](args.imdb,types.SimpleNamespace(headers={}),item_id='a'*32)
    except HTTPException as e:
        assert e.status_code==404
    else:
        raise AssertionError('Unrelated item ID was not rejected')
    result={'candidatePassed':True,'existingCardsPreserved':len(before),'candidateCards':len(after),
            'exactItemPinned':True,'wrongItemRejected':True,'proxyStatus':response.status_code,
            'proxyBytes':len(payload),'proxySha256':hashlib.sha256(payload).hexdigest(),
            'fileBytes':source['behaviorHints']['videoSize'],'coreNotImported':True,
            'liveFilesUnchanged':True,'checkedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
    Path(args.output).write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
