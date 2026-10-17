#!/usr/bin/env python3
"""Exercise the deployed add-on through public DNS and validated HTTPS."""
import argparse
import http.client
import ipaddress
import json
import socket
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT=Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument('--relay-fallback',action='store_true')
parser.add_argument('--config',default=str(ROOT/'gateway-private.json'))
args=parser.parse_args()
cfg=json.loads(Path(args.config).read_text())
u=urllib.parse.urlsplit(cfg['publicOrigin'])
with urllib.request.urlopen('https://dns.google/resolve?name='+u.hostname+'&type=A',timeout=15) as r:
    dns=json.load(r)
ips=[a['data'] for a in dns.get('Answer',[]) if a.get('type')==1 and ipaddress.ip_address(a['data']).is_global]
own_dns=bool(ips)
if not ips and args.relay_fallback:
    with urllib.request.urlopen('https://dns.google/resolve?name=desktop-h3r6cqn.tailc9bb62.ts.net&type=A',timeout=15) as r:
        fallback=json.load(r)
    ips=[a['data'] for a in fallback.get('Answer',[]) if a.get('type')==1 and ipaddress.ip_address(a['data']).is_global]
assert ips,'NO_PUBLIC_DNS_ADDRESS'
class PublicHTTPS(http.client.HTTPSConnection):
    def connect(self):
        self.sock=socket.create_connection((ips[0],u.port or 443),timeout=self.timeout)
        self.sock=self._context.wrap_socket(self.sock,server_hostname=self.host)
def request(path,method='GET',headers=None,limit=4*1024*1024):
    from gateway import public_url
    target=cfg['publicOrigin']+path
    for hop in range(5):
        dest=urllib.parse.urlsplit(target)
        if dest.hostname==u.hostname and dest.port==u.port:
            c=PublicHTTPS(u.hostname,u.port or 443,timeout=40,context=ssl.create_default_context())
        else:
            assert public_url(target),'UNSAFE_REDIRECT'
            c=http.client.HTTPSConnection(dest.hostname,dest.port or 443,timeout=40,context=ssl.create_default_context())
        try:
            request_path=dest.path+('?'+dest.query if dest.query else '')
            c.request(method,request_path,headers=headers or {})
            r=c.getresponse()
            response_headers=dict(r.getheaders())
            if r.status in (301,302,303,307,308):
                location=r.getheader('Location')
                assert location
                target=urllib.parse.urljoin(target,location)
                continue
            body=r.read(limit) if method!='HEAD' else b''
            return r.status,response_headers,body
        finally:c.close()
    raise RuntimeError('REDIRECT_LIMIT')
base='/'+cfg['token']
report={'publicDnsVerified':own_dns,'tlsVerified':True,'source':'public-relay','checks':[]}
def record(name,status,**kwargs):
    row={'check':name,'status':status,**kwargs};report['checks'].append(row)
    print(json.dumps(row),flush=True)
s,h,b=request(base+'/manifest.json');m=json.loads(b)
assert s==200 and m['id']=='com.afzengineering.releasecatalog.internet'
record('manifest',s,catalogs=len(m.get('catalogs',[])))
s,h,b=request('/manifest.json');assert s==404;record('anonymous denied',s)
s,h,b=request(base+'/manage');assert s==404;record('control route denied',s)
catalog=next(x for x in m['catalogs'] if x['id']=='netflix_top_movies_ca')
path='/catalog/'+catalog['type']+'/'+catalog['id']+'.json'
s,h,b=request(base+path);data=json.loads(b)
assert s==200 and data.get('metas');record('catalog',s,items=len(data['metas']))
s,h,b=request(base+'/meta/series/tt0098904.json');data=json.loads(b)
assert s==200 and data.get('meta');record('episode metadata',s)
poster=data['meta'].get('poster')
if poster:
    p=urllib.parse.urlsplit(poster)
    assert p.netloc==u.netloc
    s,h,b=request(p.path,limit=1000000)
    assert s==200 and len(b)>1000;record('artwork',s,bytes=len(b))
s,h,b=request(base+'/stream/series/tt0098904%3A3%3A11.json')
streams=json.loads(b).get('streams',[])
assert s==200 and streams
record('episode sources',s,sources=len(streams))
selected=next(x for x in streams if '1080p' in x.get('name','') and x.get('url'))
p=urllib.parse.urlsplit(selected['url']);assert p.netloc==u.netloc
(ROOT/'selected-internet-stream-private.json').write_text(json.dumps(selected))
for byte_range in ['bytes=0-4095','bytes=1048576-1052671']:
    started=time.monotonic()
    s,h,b=request(p.path,headers={'Range':byte_range},limit=4096)
    headers={k.lower():v for k,v in h.items()}
    assert s==206 and len(b)==4096
    if byte_range.startswith('bytes=0'):assert b.startswith(bytes.fromhex('1a45dfa3')) or b[4:8]==b'ftyp'
    record('media '+byte_range,s,contentRange=headers.get('content-range'),bytes=len(b),
           seconds=round(time.monotonic()-started,2))
s,h,b=request(p.path,method='HEAD')
assert s==200 and not b
record('media HEAD',s)
report['ok']=True
(ROOT/('public-verification.json' if own_dns else 'public-relay-verification.json')).write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps({'ok':True,'checks':len(report['checks'])}),flush=True)
