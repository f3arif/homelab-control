#!/usr/bin/env bash
set -euo pipefail
BASE="/home/coolyo/afz-stremio-secondhost-20260918"
KEY="/home/coolyo/.ssh/afz-nextcloud-h3"
REMOTE="Faiz@100.106.186.118"
STATUS="$BASE/state/hp-backup-sync-status.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SRC_CHANGED=0
ADDONS_CHANGED=0

scp -q -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE:C:/AFZ/Stremio-Failover-H3/stremio_catalog.py" "$WORK/stremio_catalog.h3.py"
python3 "$BASE/apply-hp-standby.py" "$WORK/stremio_catalog.h3.py" "$WORK/stremio_catalog.hp.py" >/dev/null
"$BASE/.venv/bin/python" -m py_compile "$WORK/stremio_catalog.hp.py"

if ! cmp -s "$WORK/stremio_catalog.hp.py" "$BASE/stremio_catalog.py"; then
  cp "$BASE/stremio_catalog.py" "$BASE/stremio_catalog.py.before-sync-$STAMP.bak"
  install -m 0644 "$WORK/stremio_catalog.hp.py" "$BASE/stremio_catalog.py"
  SRC_CHANGED=1
fi

if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'node C:\AFZ\Nuvio-Setup-20260923\hp-failover-export\export-addon-collection.mjs' >/dev/null 2>&1; then
  if scp -q -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE:C:/AFZ/Nuvio-Setup-20260923/hp-failover-export/addon-collection-private.json" "$WORK/addons.json"; then
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'cmd /c del /q C:\AFZ\Nuvio-Setup-20260923\hp-failover-export\addon-collection-private.json' >/dev/null 2>&1 || true
    python3 - "$WORK/addons.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
a=d.get('addons') or []
if len(a)<3:
    raise SystemExit('ADDON_COLLECTION_TOO_SMALL')
ids=[str((x.get('manifest') or {}).get('id') or '') for x in a if isinstance(x,dict)]
if not any(('torrentio' in x.lower() or 'debridio' in x.lower() or 'comet' in x.lower()) for x in ids):
    raise SystemExit('NO_EXTERNAL_PROVIDER_ADDON')
with open(p,'w',encoding='utf-8') as f:
    json.dump({'addons':a},f,ensure_ascii=False,sort_keys=True,separators=(',',':'))
    f.write('\n')
PY
    if ! cmp -s "$WORK/addons.json" "$BASE/private/addon-collection-private.json"; then
      install -m 0600 "$WORK/addons.json" "$BASE/private/addon-collection-private.json"
      ADDONS_CHANGED=1
    fi
  fi
fi

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
if [ "$ADDONS_CHANGED" -eq 1 ]; then
  systemctl --user restart afz-stremio-provider-bridge.service
fi
if [ "$SRC_CHANGED" -eq 1 ]; then
  systemctl --user restart afz-stremio-backup.service
fi

# A restarted backend needs several seconds to import; wait for it before probing.
for _ in $(seq 1 45); do
  curl -fsS --max-time 2 http://127.0.0.1:18775/manifest.json >/dev/null 2>&1 && break
  sleep 1
done
MANIFEST_ID="$(curl -fsS --max-time 10 http://127.0.0.1:18775/manifest.json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
BRIDGE_OK="$(curl -fsS --max-time 10 'http://127.0.0.1:18768/external-streams?imdb=tt36958312' | python3 -c 'import json,sys; d=json.load(sys.stdin); print("true" if d.get("ok") and int(d.get("sourceCount") or 0)>0 else "false")')"
SRC_HASH="$(sha256sum "$BASE/stremio_catalog.py" | awk '{print $1}')"
RAW_HASH="$(sha256sum "$WORK/stremio_catalog.h3.py" | awk '{print $1}')"
python3 - "$STATUS" "$STAMP" "$SRC_CHANGED" "$ADDONS_CHANGED" "$MANIFEST_ID" "$BRIDGE_OK" "$SRC_HASH" "$RAW_HASH" <<'PY'
import json,sys
p,stamp,src,addons,mid,bok,sh,rh=sys.argv[1:]
json.dump({
  "status":"ok","atUtc":stamp,"sourceChanged":src=="1","addonsChanged":addons=="1",
  "manifestId":mid,"providerBridgeOk":bok=="true","hpPatchedSourceSha256":sh,"h3RawSourceSha256":rh
},open(p,"w",encoding="utf-8"),indent=2)
PY
echo "AFZ_HP_BACKUP_SYNC_OK sourceChanged=$SRC_CHANGED addonsChanged=$ADDONS_CHANGED bridgeOk=$BRIDGE_OK"
