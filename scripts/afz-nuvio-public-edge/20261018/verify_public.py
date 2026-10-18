#!/usr/bin/env python3
"""Check the original AFZ Nuvio route using public DNS, TLS, and bounded media ranges."""
import http.client,ipaddress,json,socket,ssl,time,urllib.parse,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parent
HOST="desktop-h3r6cqn.tailc9bb62.ts.net"
PORT=10000
token=(ROOT/"public-transport-token-private.txt").read_text().strip()
with urllib.request.urlopen("https://dns.google/resolve?name="+HOST+"&type=A",timeout=15) as r:
 dns=json.load(r)
ips=[a["data"] for a in dns.get("Answer",[]) if a.get("type")==1 and ipaddress.ip_address(a["data"]).is_global]
assert ips,"PUBLIC_DNS_UNAVAILABLE"
class PublicHTTPS(http.client.HTTPSConnection):
 def connect(self):
  self.sock=socket.create_connection((ips[0],PORT),timeout=self.timeout)
  self.sock=self._context.wrap_socket(self.sock,server_hostname=HOST)
def safe_redirect(p):
 if p.scheme!="https" or not p.hostname or p.username or p.password: return False
 if p.port not in (None,443): return False
 host=p.hostname.lower()
 if host in ("localhost",) or host.endswith((".local",".localhost",".ts.net")): return False
 try:return ipaddress.ip_address(host).is_global
 except ValueError:return "." in host
def request(path,method="GET",headers=None,limit=4*1024*1024):
 target="https://"+HOST+":"+str(PORT)+path
 for _ in range(5):
  p=urllib.parse.urlsplit(target)
  own=p.hostname==HOST and p.port==PORT
  assert own or safe_redirect(p),"UNEXPECTED_REDIRECT"
  c=(PublicHTTPS if own else http.client.HTTPSConnection)(p.hostname,p.port or 443,timeout=40,context=ssl.create_default_context())
  try:
   c.request(method,p.path+("?"+p.query if p.query else ""),headers=headers or {})
   r=c.getresponse()
   if r.status in (301,302,303,307,308):
    location=r.getheader("Location")
    assert location,"REDIRECT_WITHOUT_LOCATION"
    target=urllib.parse.urljoin(target,location)
    continue
   return r.status,{k.lower():v for k,v in r.getheaders()},r.read(limit) if method!="HEAD" else b""
  finally:c.close()
 raise RuntimeError("REDIRECT_LIMIT")
base="/"+token
report={"utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"publicDnsVerified":True,"tlsVerified":True,"checks":[]}
def record(name,status,**detail):
 row={"check":name,"status":status,**detail}
 report["checks"].append(row)
 print(json.dumps(row),flush=True)
try:
 s,h,b=request(base+"/manifest.json")
 m=json.loads(b)
 assert s==200 and m["id"]=="com.afzengineering.releasecatalog"
 record("original manifest",s,catalogs=len(m["catalogs"]))
 s,h,b=request("/manifest.json")
 assert s==404
 record("anonymous denied",s)
 cat=next(x for x in m["catalogs"] if x["id"]=="netflix_top_movies_ca")
 s,h,b=request(base+"/catalog/"+cat["type"]+"/"+cat["id"]+".json")
 j=json.loads(b)
 assert s==200 and j.get("metas")
 record("movie catalog",s,items=len(j["metas"]))
 s,h,b=request(base+"/meta/series/tt0098904.json")
 j=json.loads(b)
 assert s==200 and j.get("meta")
 record("series metadata",s)
 poster=urllib.parse.urlsplit(j["meta"]["poster"])
 assert poster.hostname==HOST and poster.port==PORT
 s,h,b=request(poster.path+("?"+poster.query if poster.query else ""),limit=1000000)
 assert s==200 and len(b)>1000
 record("artwork",s,bytes=len(b))
 s,h,b=request(base+"/stream/series/tt0098904%3A3%3A11.json")
 streams=json.loads(b).get("streams",[])
 assert s==200 and streams
 record("episode sources",s,sources=len(streams))
 selected=next(x for x in streams if "1080p" in x.get("name","") and x.get("url"))
 media=urllib.parse.urlsplit(selected["url"])
 assert media.hostname==HOST and media.port==PORT
 for a,z in ((0,4095),(1048576,1052671)):
  started=time.monotonic()
  s,h,b=request(media.path,headers={"Range":f"bytes={a}-{z}"},limit=z-a+1)
  assert s==206 and len(b)==z-a+1 and h.get("content-range","").startswith(f"bytes {a}-{z}/")
  if a==0:assert b.startswith(bytes.fromhex("1a45dfa3")) or b[4:8]==b"ftyp"
  record("media start" if a==0 else "media seek",s,bytes=len(b),contentRange=h.get("content-range"),seconds=round(time.monotonic()-started,2))
 s,h,b=request(media.path,method="HEAD")
 assert s==200 and not b
 record("media HEAD",s)
 report["ok"]=True
except Exception as e:
 report["ok"]=False
 report["errorType"]=type(e).__name__
 raise
finally:
 (ROOT/"public-verification.json").write_text(json.dumps(report,indent=2))
