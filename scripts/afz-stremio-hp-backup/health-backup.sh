#!/usr/bin/env bash
set -u
BASE=/home/coolyo/afz-stremio-secondhost-20260918
STATE="$BASE/state"
STATUS="$STATE/hp-backup-health.json"
PRIMARY=http://100.106.186.118:18777/manifest.json
PRIMARY_HOST=desktop-h3r6cqn.tailc9bb62.ts.net:18777
MIRROR_STATUS=/home/coolyo/afz-stremio-hotmirror/state/status.json
mkdir -p "$STATE"
# Expected version follows the deployed (H3-synced) source so H3 upgrades do not
# turn into a restart loop here.
EXPECTED_VERSION="$(sed -n "s/^APP_VERSION='\\([^']*\\)'.*/\\1/p" "$BASE/stremio_catalog.py" | head -1)"
actions=""
local_ok=false
bridge_ok=false
route_ok=false
public_route_ok=false
primary_ok=false

check_local() {
  curl --connect-timeout 2 --max-time 8 -fsS http://127.0.0.1:18775/manifest.json 2>/dev/null |
    python3 -c "import json,sys;m=json.load(sys.stdin);v=sys.argv[1];assert m.get('id')=='com.afzengineering.releasecatalog.hpbackup' and (not v or m.get('version')==v)" "$EXPECTED_VERSION" >/dev/null 2>&1
}
check_bridge() {
  curl --connect-timeout 2 --max-time 6 -fsS http://127.0.0.1:18768/health 2>/dev/null |
    python3 -c "import json,sys;d=json.load(sys.stdin);assert d.get('ok') is True" >/dev/null 2>&1
}
if check_bridge; then
  bridge_ok=true
else
  systemctl --user restart afz-stremio-provider-bridge.service >/dev/null 2>&1 || true
  actions="restart-provider-bridge"
  sleep 2
  check_bridge && bridge_ok=true
fi
if check_local; then
  local_ok=true
else
  systemctl --user restart afz-stremio-backup.service >/dev/null 2>&1 || true
  if [ -n "$actions" ]; then actions="$actions,restart-backup"; else actions="restart-backup"; fi
  sleep 4
  check_local && local_ok=true
fi

serve="$(tailscale serve status 2>/dev/null || true)"
if printf '%s' "$serve" | grep -Fq 'hpenvy.tailc9bb62.ts.net:8445' &&
   printf '%s' "$serve" | grep -Fq 'proxy http://127.0.0.1:18775'; then
  route_ok=true
fi
token="$(cat "$BASE/private/public-transport-token.txt" 2>/dev/null || true)"
if [ -n "$token" ] && printf '%s' "$serve" | grep -Fq "/$token" &&
   printf '%s' "$serve" | grep -Fq 'proxy http://127.0.0.1:18775'; then
  public_route_ok=true
fi
if curl --connect-timeout 2 --max-time 6 -fsS -H "Host: $PRIMARY_HOST" "$PRIMARY" 2>/dev/null |
   python3 -c "import json,sys;m=json.load(sys.stdin);assert m.get('id')=='com.afzengineering.releasecatalog'" >/dev/null 2>&1; then
  primary_ok=true
fi

python3 - "$STATUS" "$local_ok" "$bridge_ok" "$route_ok" "$public_route_ok" "$primary_ok" "$actions" "$EXPECTED_VERSION" "$MIRROR_STATUS" <<'PY'
import json,sys,datetime
p,local,bridge,route,pub,primary,actions,version,mirror_path=sys.argv[1:]
now=datetime.datetime.now(datetime.timezone.utc)
# Hot-mirror problems are reported as warnings; "status" stays about serving.
warnings=[]
mirror={"ok":False}
try:
  m=json.load(open(mirror_path,encoding="utf-8"))
  age=(now-datetime.datetime.fromisoformat(m["updatedUtc"])).total_seconds()/3600
  prune=str((m.get("prune") or {}).get("result") or "")
  free=m.get("freeBytes")
  mirror={"status":m.get("status"),"detail":m.get("detail"),"updatedUtc":m.get("updatedUtc"),
          "ageHours":round(age,1),"prune":prune,"freeGiB":round(free/2**30,1) if free else None}
  if m.get("status") not in ("completed","running"):
    warnings.append("hotmirror:"+str(m.get("status"))+(":"+str(m.get("detail")) if m.get("detail") else ""))
  if age>13:
    warnings.append("hotmirror:stale:%.1fh"%age)
  if prune.startswith(("aborted","error")):
    warnings.append("hotmirror:prune:"+prune)
  if free is not None and free<40*2**30:
    warnings.append("hotmirror:below-reserve")
  mirror["ok"]=not warnings
except Exception as e:
  warnings.append("hotmirror:status-unreadable:"+type(e).__name__)
json.dump({
  "status":"ok" if all(x=="true" for x in (local,bridge,route,pub)) else "degraded",
  "checkedUtc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "localBackupOk":local=="true",
  "providerBridgeOk":bridge=="true",
  "tailscale8445RouteOk":route=="true",
  "publicTokenRouteOk":pub=="true",
  "h3PrimaryOk":primary=="true",
  "expectedVersion":version,
  "actions":[x for x in actions.split(",") if x],
  "hotMirror":mirror,
  "warnings":warnings,
},open(p,"w",encoding="utf-8"),indent=2)
PY
