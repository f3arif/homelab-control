# H3-unavailable canary: expects an "AFZ Local" stream served from the HP mirror.
import json, sys, urllib.request
BASE = "http://127.0.0.1:18776"
vid = sys.argv[1] if len(sys.argv) > 1 else "tt28014327"
with urllib.request.urlopen(f"{BASE}/stream/movie/{vid}.json", timeout=30) as r:
    d = json.load(r)
rows = d.get("streams") or []
print("COUNT", len(rows))
for i, x in enumerate(rows[:25]):
    print(i, x.get("name"), "|", x.get("title"))
local = next((x for x in rows if x.get("name") == "AFZ Local" and x.get("url")), None)
if not local:
    raise SystemExit("NO_AFZ_LOCAL")
req = urllib.request.Request(local["url"], headers={"Range": "bytes=0-1048575"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = r.read(1048576)
    print("LOCAL_FETCH_STATUS", r.status)
    print("LOCAL_FETCH_RANGE", r.headers.get("Content-Range"))
    print("LOCAL_FETCH_BYTES", len(data))
if r.status != 206 or len(data) != 1048576:
    raise SystemExit("LOCAL_FETCH_FAILED")
print("AFZ_HP_CANARY_OK")
