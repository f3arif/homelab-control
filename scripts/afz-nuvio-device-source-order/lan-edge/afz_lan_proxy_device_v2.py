import os
import json
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import Response, StreamingResponse
import requests
import re
import ipaddress

STREAM_ORDER_UPSTREAM=os.getenv(
    'AFZ_LAN_MOVIE_ORDER_UPSTREAM','http://127.0.0.1:18792'
).rstrip('/')
MOVIE_LIST_RX=re.compile(r'^stream/movie/(?:tt\d+|afzlib:[^/]{1,100})\.json$',re.I)
LOCAL_CLIENT_NETS=(ipaddress.ip_network('192.168.50.0/24'),
                   ipaddress.ip_network('100.64.0.0/10'))

UPSTREAM=os.getenv('AFZ_LAN_UPSTREAM','http://127.0.0.1:18770').rstrip('/')
LAN_BASE=os.getenv('AFZ_LAN_PUBLIC_BASE','http://192.168.50.185:18772').rstrip('/')
SOURCE_BASE=os.getenv(
    'AFZ_SOURCE_PUBLIC_BASE',
    'https://desktop-h3r6cqn.tailc9bb62.ts.net:8445'
).rstrip('/')
SEPARATE_ID=str(os.getenv('AFZ_LAN_SEPARATE_ID','1')).strip().lower() in ('1','true','yes','on')

app=FastAPI(title='AFZ Stremio LAN Edge',docs_url=None,redoc_url=None)
session=requests.Session()

HOP={
    'connection','keep-alive','proxy-authenticate','proxy-authorization',
    'te','trailers','transfer-encoding','upgrade','host'
}
REWRITE_TYPES=('application/json','text/','application/javascript')

def _out_headers(headers):
    out={}
    for k,v in headers.items():
        if k.lower() in HOP:
            continue
        out[k]=v
    return out

@app.get('/__lan_health')
def lan_health():
    try:
        r=session.get(UPSTREAM+'/manifest.json',timeout=8)
        r.raise_for_status()
        version=str((r.json() or {}).get('version') or '')
        ok=bool(version)
    except Exception as exc:
        return {
            'ok':False,'lanBase':LAN_BASE,'upstream':UPSTREAM,
            'error':type(exc).__name__
        }
    return {
        'ok':ok,'lanBase':LAN_BASE,'upstream':UPSTREAM,
        'sourceBase':SOURCE_BASE,'addonVersion':version
    }

@app.api_route('/',methods=['GET','HEAD','POST','PUT','PATCH','DELETE','OPTIONS'])
@app.api_route('/{path:path}',methods=['GET','HEAD','POST','PUT','PATCH','DELETE','OPTIONS'])
async def proxy(path:str,request:Request):
    path=str(path or '')
    movie_list=bool(request.method in ('GET','HEAD') and MOVIE_LIST_RX.fullmatch(path))
    target=(STREAM_ORDER_UPSTREAM if movie_list else UPSTREAM)+'/'+path
    query=str(request.url.query or '')
    if query:
        target+='?'+query
    body=await request.body()
    headers={
        k:v for k,v in request.headers.items()
        if k.lower() not in HOP
    }
    if movie_list:
        # Ignore caller-supplied forwarding claims. The actual peer IP comes
        # from this LAN edge's TCP connection, never an untrusted header.
        headers={k:v for k,v in headers.items() if k.lower()!='x-forwarded-for'}
        try:
            client=ipaddress.ip_address(str(request.client.host or ''))
            if any(client in net for net in LOCAL_CLIENT_NETS):
                headers['X-Forwarded-For']=str(client)
        except (ValueError,AttributeError):
            pass
    try:
        r=session.request(
            request.method,target,headers=headers,data=body or None,
            stream=True,allow_redirects=False,timeout=(4,24) if movie_list else (10,300)
        )
        if movie_list and r.status_code in (502,503,504):
            # If the phone-preference sorter fails, preserve movie playback
            # choice availability by using the prior upstream JSON instead.
            r.close()
            r=session.request(
                request.method,UPSTREAM+'/'+path+('?' + query if query else ''),
                headers=headers,data=body or None,stream=True,
                allow_redirects=False,timeout=(3,15)
            )
    except requests.RequestException as exc:
        if not movie_list:
            raise HTTPException(502,'AFZ upstream unavailable') from exc
        try:
            r=session.request(
                request.method,UPSTREAM+'/'+path+('?' + query if query else ''),
                headers=headers,data=body or None,stream=True,
                allow_redirects=False,timeout=(3,15)
            )
        except requests.RequestException as fallback_exc:
            raise HTTPException(502,'AFZ movie sources unavailable') from fallback_exc

    out_headers=_out_headers(r.headers)
    location=out_headers.get('Location') or out_headers.get('location')
    if location and SOURCE_BASE in location:
        fixed=location.replace(SOURCE_BASE,LAN_BASE)
        out_headers['Location']=fixed
        out_headers.pop('location',None)

    ctype=str(r.headers.get('content-type') or '').lower()
    rewrite=any(ctype.startswith(x) for x in REWRITE_TYPES)
    if request.method=='HEAD':
        r.close()
        out_headers.pop('Content-Length',None)
        out_headers.pop('content-length',None)
        return Response(status_code=r.status_code,headers=out_headers)

    if rewrite:
        data=r.content
        r.close()
        data=data.replace(SOURCE_BASE.encode('utf-8'),LAN_BASE.encode('utf-8'))
        if SEPARATE_ID and str(path or '').strip('/')=='manifest.json':
            try:
                obj=json.loads(data.decode('utf-8'))
                base_id=str(obj.get('id') or 'com.afzengineering.releasecatalog')
                if not base_id.endswith('.lan'):
                    obj['id']=base_id+'.lan'
                obj['name']=str(obj.get('name') or 'AFZ Movies & TV')+' (LAN)'
                desc=str(obj.get('description') or '').strip()
                note='Local LAN transport for AFZ Movies & TV'
                obj['description']=' · '.join(x for x in (desc,note) if x)
                data=json.dumps(obj,ensure_ascii=False,separators=(',',':')).encode('utf-8')
            except Exception:
                pass
        out_headers.pop('Content-Length',None)
        out_headers.pop('content-length',None)
        return Response(content=data,status_code=r.status_code,headers=out_headers)

    def chunks():
        try:
            for chunk in r.iter_content(chunk_size=1024*1024):
                if chunk:
                    yield chunk
        finally:
            r.close()

    return StreamingResponse(
        chunks(),status_code=r.status_code,
        media_type=r.headers.get('content-type'),
        headers=out_headers
    )
