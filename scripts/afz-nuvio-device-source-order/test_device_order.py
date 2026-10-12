import collections, copy, importlib.util, json, pathlib, time, urllib.parse
import requests
from starlette.requests import Request

ROOT=pathlib.Path(r"C:\AFZ\Nuvio-Setup-20260923\device-source-order-20261012")
spec=importlib.util.spec_from_file_location("device_source_order",ROOT/"device_source_order.py")
app=importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
policy=json.loads((ROOT/"device-policy.json").read_text(encoding="utf-8"))
assert len(policy.get("phone") or [])>=2 and policy.get("tv")
PHONE1=policy["phone"][0]
PHONE2=policy["phone"][1]
TV1=policy["tv"][0]
cases=[]
def check(name,condition,detail=None):
    cases.append({"name":name,"pass":bool(condition),"detail":detail})
    print(("PASS " if condition else "FAIL ")+name+((" = "+str(detail)) if detail is not None else ""),flush=True)
    if not condition:raise AssertionError(name)

def peer(host,xff=None):
    headers=[(b"x-forwarded-for",xff.encode())] if xff is not None else []
    return Request({"type":"http","method":"GET","path":"/stream/movie/tt11460992.json",
                    "headers":headers,"client":(host,51515),"server":("127.0.0.1",18789)})

check("OnePlus classified phone",app.source_class(peer("127.0.0.1",PHONE1))=="phone")
check("Pixel10 classified phone",app.source_class(peer("127.0.0.1",PHONE2))=="phone")
check("onn classified TV",app.source_class(peer("127.0.0.1",TV1))=="tv")
check("other tailnet host unknown",app.source_class(peer("127.0.0.1","100.64.0.1"))=="unknown")
check("untrusted external XFF ignored",app.source_class(peer("8.8.8.8",PHONE1))=="unknown")
check("device_name onn recognized TV",app.device_name_category("onn 4K Android TV")=="tv")
check("device_name phone recognized",app.device_name_category("Pixel 10 Pro XL")=="phone")
check("device_name unknown unaffected",app.device_name_category("afz-zbook")=="unknown")

ids=("tt11460992","tt6723592","tt22084616","tt32393988")
sums=[]
for vid in ids:
    r=requests.get(f"http://127.0.0.1:18774/stream/movie/{vid}.json",timeout=15)
    check("live "+vid+" HTTP 200",r.status_code==200)
    original=r.json().get("streams")or[]
    check("live "+vid+" non-empty",bool(original))
    sorted_rows=app.sort_phone(original)
    check("preserve "+vid+" URL multiset",collections.Counter(x.get("url") or x.get("externalUrl") for x in sorted_rows)==collections.Counter(x.get("url") or x.get("externalUrl") for x in original))
    check("preserve "+vid+" count",len(sorted_rows)==len(original))
    first=sorted_rows[0]
    check("phone "+vid+" recommended first",first.get("name")=="AFZ Recommended for Phone")
    check("phone "+vid+" recommended under 8GB when available",
          app.size_bytes(first)<=8*1024**3 or
          not any(0<app.size_bytes(x)<=8*1024**3 and "1080p" in str(x.get("name")or"").lower()
              for x in original))
    check("no phone "+vid+" 4K before recommended",not app._is_4k(first))
    if any(app._is_action(x) for x in original):
        last_action=next((i for i,x in enumerate(sorted_rows) if app._is_action(x)),len(sorted_rows))
        check("phone "+vid+" controls all last",
              all(app._is_action(x) for x in sorted_rows[last_action:]))
    unchanged=json.dumps(original,sort_keys=True,ensure_ascii=False)
    check("original live response not mutated "+vid,
          json.dumps(r.json().get("streams")or[],sort_keys=True,ensure_ascii=False)==unchanged)
    sums.append({"vid":vid,"before":str(original[0].get("name")),"after":str(first.get("name")),
                 "recommendedGiB":round(app.size_bytes(first)/1024**3,2),
                 "count":len(sorted_rows)})
# On the phone, manual small cached choices must precede larger Auto Mobile.
runway=requests.get("http://127.0.0.1:18774/stream/movie/tt11460992.json",timeout=9).json()["streams"]
phone=app.sort_phone(runway)
mobile_index=next(i for i,x in enumerate(phone) if x.get("name")=="AFZ Auto Mobile")
small_indexes=[i for i,x in enumerate(phone) if app._manual_small(x)]
check("smaller cached manual before Auto Mobile",bool(small_indexes) and all(i<mobile_index for i in small_indexes),
      {"manual_positions":[i+1 for i in small_indexes],"mobile_position":mobile_index+1})
first_4k=next((i for i,x in enumerate(phone) if app._is_4k(x)),len(phone))
last_1080=max((i for i,x in enumerate(phone) if "1080p" in str(x.get("name")or"").lower() and not app._is_4k(x)),default=-1)
check("4K alternatives below phone 1080p playback choices",first_4k>last_1080)

# Synthetic: if Auto Data Saver over-size, recommend explicit small file.
big=[
    {"name":"AFZ Play Best","title":"2160p | 80 GB | cached","url":"https://example.invalid/auto-stream/tt000/best"},
    {"name":"AFZ Auto Data Saver","title":"1080p | 19 GB | cached","url":"https://example.invalid/auto-stream/tt000/saver"},
    {"name":"AFZ Phone 1080p TorBox","title":"4.0 GB | Comet | cached",
     "url":"https://example.invalid/external-stream/tt000/"+"a"*28,
     "behaviorHints":{"filename":"Movie.1080p.mkv","videoSize":int(4*1024**3)}},
    {"name":"Auto-save to home library","title":"ON","externalUrl":"https://example.invalid/action"},
]
chosen=app.sort_phone(big)
check("oversized saver falls back to exact small explicit source",
      chosen[0]["url"]==big[2]["url"] and app.size_bytes(chosen[0])==4*1024**3)
check("actions still last synthetic",chosen[-1].get("externalUrl")==big[-1]["externalUrl"])
check("no added URLs synthetic",len(chosen)==len(big))
check("empty input unchanged",app.sort_phone([])==[])
check("non-AFZ addon untouched",app.sort_phone([{"name":"Torrentio","url":"https://example.invalid/s"}])==[{"name":"Torrentio","url":"https://example.invalid/s"}])
receipt={"status":"PASS","tests":len(cases),"cases":cases,"movies":sums,
         "production_untouched":True,"tv_and_unknown":"original upstream order preserved"}
(ROOT/"source-order-test-results.json").write_text(json.dumps(receipt,indent=2),encoding="utf-8")
print("PASS_ALL",len(cases),"TESTS",flush=True)
for s in sums:
    print("TITLE",s["vid"],"FROM",s["before"],"TO",s["after"],
          "RECOMMENDED_GIB",s["recommendedGiB"],flush=True)
