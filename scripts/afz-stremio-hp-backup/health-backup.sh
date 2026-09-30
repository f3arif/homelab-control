#!/usr/bin/env bash
set -u
BASE=/home/coolyo/afz-stremio-secondhost-20260918
STATE="$BASE/state"
STATUS="$STATE/hp-backup-health.json"
PRIMARY=https://desktop-h3r6cqn.tailc9bb62.ts.net:8445/manifest.json
mkdir -p "$STATE"
actions=""
local_ok=false
bridge_ok=false
route_ok=false
public_route_ok=false
primary_ok=false

check_local() {
  curl --connect-timeout 2 --max-time 8 -fsS http://127.0.0.1:18775/manifest.json 2>/dev/null |
    python3 -c "import json,sys;m=json.load(sys.stdin);assert m.get('id')=='com.afzengineering.releasecatalog.hpbackup' and m.get('version')=='0.6.243'" >/dev/null 2>&1
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

if curl --connect-timeout 2 --max-time 6 -fsS "$PRIMARY" 2>/dev/null |
   python3 -c "import json,sys;m=json.load(sys.stdin);assert m.get('id')=='com.afzengineering.releasecatalog' and m.get('version')=='0.6.243'" >/dev/null 2>&1; then
  primary_ok=true
fi

python3 - "$STATUS" "$local_ok" "$bridge_ok" "$route_ok" "$public_route_ok" "$primary_ok" "$actions" <<'PY'
import json,sys,datetime
p,local,bridge,route,pub,primary,actions=sys.argv[1:]
json.dump({
  "status":"ok" if all(x=="true" for x in (local,bridge,route,pub)) else "degraded",
  "checkedUtc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "localBackupOk":local=="true",
  "providerBridgeOk":bridge=="true",
  "tailscale8445RouteOk":route=="true",
  "publicTokenRouteOk":pub=="true",
  "h3PrimaryOk":primary=="true",
  "actions":[x for x in actions.split(",") if x],
},open(p,"w",encoding="utf-8"),indent=2)
PY
