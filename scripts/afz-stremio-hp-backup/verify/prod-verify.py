# Healthy-primary gate: production HP backup must return 0 streams while H3 is up.
import json, urllib.request
with urllib.request.urlopen("http://127.0.0.1:18775/manifest.json", timeout=30) as r:
    m = json.load(r)
print("MANIFEST", m.get("id"), m.get("version"), m.get("name"))
with urllib.request.urlopen("http://127.0.0.1:18775/stream/movie/tt28014327.json", timeout=30) as r:
    n = len(json.load(r).get("streams") or [])
print("HEALTHY_GATE_STREAMS", n)
