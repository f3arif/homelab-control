import concurrent.futures,json,time,urllib.request,urllib.error,pathlib,sys
ROOT=pathlib.Path(r"C:\AFZ\Stremio-Failover-H3")
OUT=pathlib.Path(r"C:\AFZ\Evidence\Nuvio-502-20261018")
OUT.mkdir(parents=True,exist_ok=True)
token=(ROOT/"state/public-transport-token.txt").read_text().strip()
links=json.loads(pathlib.Path(r"C:\Users\Faiz\AppData\Local\AFZ\ONN-Internet-20261017\installation-links-private.json").read_text(encoding="utf-8-sig"))
old="https://desktop-h3r6cqn.tailc9bb62.ts.net:10000/"+token
new=links["manifest"].removesuffix("/manifest.json")
def probe(item):
 name,base,path=item
 start=time.monotonic()
 result={"name":name}
 try:
  with urllib.request.urlopen(base+path,timeout=25) as r:
   data=r.read(16*1024*1024+1)
   result.update(status=r.status,bytes=len(data),contentType=r.headers.get("Content-Type",""))
   if "json" in result["contentType"]:
    j=json.loads(data)
    result.update({k:j[k] for k in ("id","version") if k in j})
    for k in ("streams","catalogs","metas"):
     if k in j: result[k]=len(j[k])
 except urllib.error.HTTPError as e: result.update(status=e.code)
 except Exception as e: result.update(error=type(e).__name__)
 result["seconds"]=round(time.monotonic()-start,2)
 return result
items=[]
for label,base in (("core","http://127.0.0.1:18774"),("original-public",old),("internet",new)):
 for kind,path in (("manifest","/manifest.json"),("sources","/stream/series/tt0098904:3:11.json")): items.append((label+"-"+kind,base,path))
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: report={"utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"results":list(pool.map(probe,items))}
(OUT/(sys.argv[1] if len(sys.argv)>1 else "before-route-check.json")).write_text(json.dumps(report,indent=2))
print(json.dumps(report))
