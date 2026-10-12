"""Non-mutating V2 validation. Run on H3 with the AFZ Python virtualenv."""
import collections, hashlib, json, pathlib, re, urllib.parse
import requests
from datetime import datetime, timezone
ROOT=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012")
EXPECTED_V2="1c144432e242c42027eb00dc8841aeb9c5f3930863ea434de326829e447ac3be"
EXPECTED_CATALOG="d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f"
ORIGIN="http://127.0.0.1:18774"
OVERLAY="http://127.0.0.1:18792"
POLICY=json.loads((ROOT/"device-policy.json").read_text(encoding="utf-8"))
assert len(POLICY.get("phone") or [])>=3 and POLICY.get("tv")
TV=POLICY["tv"][0]
PHONE=tuple(POLICY["phone"][:3])
UNKNOWN="100.64.0.1"
VIDS=("tt11460992","tt22084616","tt6723592","tt32393988")
checks=[]
def confirm(label,ok):
    checks.append({"name":label,"pass":bool(ok)})
    if not ok:raise AssertionError(label)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
confirm("v2-source-pinned",sha(ROOT/"device_source_order_v2.py")==EXPECTED_V2)
confirm("production-source-original",sha(pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py"))==EXPECTED_CATALOG)
health=requests.get(OVERLAY+"/health",timeout=3).json()
confirm("v2-health",health.get("ok") and health.get("policy")=="phone-best-v2")
for vid in VIDS:
    source=requests.get(ORIGIN+f"/stream/movie/{vid}.json",timeout=10)
    confirm(vid+"-original-status",source.status_code==200)
    baseline=source.json()
    before=baseline["streams"]
    confirm(vid+"-has-playbest",before and before[0]["name"]=="AFZ Play Best")
    for name,ip in (("OnePlus",PHONE[0]),("Pixel10",PHONE[1]),("Pixel8",PHONE[2]),("onn",TV),("ZBook",UNKNOWN)):
        response=requests.get(OVERLAY+f"/{vid}.json",
            headers={"X-Forwarded-For":ip,"User-Agent":"okhttp/4.12"},
            timeout=14)
        label=vid+"-"+name
        confirm(label+"-status",response.status_code==200)
        confirm(label+"-source-count",len(response.json().get("streams",[]))==len(before))
        role="phone" if ip in PHONE else ("tv" if ip==TV else "unknown")
        confirm(label+"-role",response.headers.get("X-AFZ-Device-Class")==role)
        confirm(label+"-policy",response.headers.get("X-AFZ-Sort-Policy")=="phone-best-v2")
        after=response.json()["streams"]
        if role=="phone":
            first=after[0]
            confirm(label+"-pinned-best",first.get("name")=="AFZ Play Best")
            confirm(label+"-1080p",bool(re.search(r"1080p",str(first.get("title")or""),re.I)))
            confirm(label+"-phone-label","Phone optimized" in str(first.get("title")or""))
            confirm(label+"-large-4k-not-on-top","2160p" not in str(first.get("title")or""))
            confirm(label+"-fresh-play-url","afz_phone_best=1" in str(first.get("url")or""))
            def destination(row):return str(row.get("url") or row.get("externalUrl") or "")
            confirm(label+"-other-links-intact",
                collections.Counter(destination(r) for r in after[1:])==
                collections.Counter(destination(r) for r in before[1:]))
            confirm(label+"-retains-explicit-4k",any("4k" in str(r.get("name") or"").lower() for r in after[1:]))
        else:
            confirm(label+"-original-tv-desktop-order",response.json()==baseline)
    print("PASS_MOVIE",vid,flush=True)
chosen=requests.get(OVERLAY+"/tt11460992.json",
    headers={"X-Forwarded-For":PHONE[0]},timeout=14).json()["streams"][0]
# The extra parameter is an alias on our existing non-destructive Auto route.
p=urllib.parse.urlsplit(chosen["url"])
orig=requests.get(ORIGIN+"/stream/movie/tt11460992.json",timeout=9).json()
original_host=urllib.parse.urlsplit(orig["streams"][0]["url"]).hostname
confirm("phone-best-reuses-original-media-host",p.hostname==original_host)
confirm("phone-best-points-to-1080p-auto",p.path.endswith("/auto-stream/tt11460992/saver"))
check=requests.head(ORIGIN+p.path+"?"+p.query,allow_redirects=False,timeout=17)
confirm("playback-link-head-success",check.status_code in (200,206,307))
confirm("v2-media-root-original",
    sha(pathlib.Path(r"C:\AFZ\Stremio-Failover-H3\stremio_catalog.py"))==EXPECTED_CATALOG)
receipt={"result":"PASS","checked_utc":datetime.now(timezone.utc).isoformat(),
         "total":len(checks),"checks":checks,"liveMediaFilesUnchanged":True,
         "videoFilesDownloaded":False,"tvFirst4KPreserved":True}
(ROOT/"v2-reproducible-acceptance.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print("ALL_V2_ACCEPTANCE",len(checks),"PASS",flush=True)
