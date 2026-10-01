#!/usr/bin/env bash
# Starts an isolated failover canary on 127.0.0.1:18776 whose primary health URL is
# unreachable, so it behaves as if H3 were down. Production (18775) is untouched.
set -euo pipefail
BASE=/home/coolyo/afz-stremio-secondhost-20260918
MIR=/home/coolyo/afz-stremio-hotmirror
PID=$MIR/state/canary.pid
LOG=$MIR/logs/canary.log
mkdir -p "$MIR/state" "$MIR/logs"
if [ -f "$PID" ]; then
  old="$(cat "$PID" 2>/dev/null || true)"
  if [ -n "$old" ]; then kill "$old" 2>/dev/null || true; fi
fi
cd "$BASE"
nohup env \
  PYTHONUNBUFFERED=1 \
  AFZ_STREMIO_FAILOVER_MODE=1 \
  AFZ_BACKUP_STANDBY_MODE=1 \
  AFZ_PRIMARY_HEALTH_URL=http://127.0.0.1:9/manifest.json \
  STREMIO_PUBLIC_BASE_URL=http://127.0.0.1:18776 \
  STREMIO_MEDIA_ROOT="$MIR" \
  STREMIO_MEDIA_STORAGE_ROOT="$MIR/Movies" \
  STREMIO_TV_ROOT="$MIR/TV" \
  STREMIO_TV_STORAGE_ROOT="$MIR/TV" \
  STREMIO_JELLYFIN_ROOT="$BASE/jellyfin" \
  AFZ_STATE_FILE="$MIR/state/canary-stremio-state.json" \
  STREMIO_BADGE_POSTER_DIR="$MIR/state/canary-posters" \
  STREMIO_KIDS_MODE_FILE="$MIR/state/canary-kids.json" \
  STREMIO_KIDS_CURATED_CACHE_FILE="$MIR/state/canary-kids-curated.json" \
  AFZ_HIDDEN_HOME_FILE="$MIR/state/canary-hidden.json" \
  JELLYFIN_URL=http://127.0.0.1:8096 \
  JELLYFIN_WEB_BASE=https://hpenvy.tailc9bb62.ts.net:8097 \
  AFZ_HP_JELLYFIN_ENABLED=0 \
  JELLYFIN_DB="$MIR/state/missing-jellyfin.db" \
  JELLYSEERR_SETTINGS="$MIR/state/missing-jellyseerr.json" \
  SEERR_URL=http://127.0.0.1:9/api/v1 \
  SEERR_API_KEY= \
  RADARR_URL=http://127.0.0.1:9/api/v3 \
  RADARR_API_KEY= \
  SONARR_URL=http://127.0.0.1:9/api/v3 \
  RDT_TORBOX_DB="$MIR/state/missing-rdt-torbox.db" \
  RDT_RD_DB="$MIR/state/missing-rdt-rd.db" \
  NTFY_URL=http://127.0.0.1:9 \
  STREMIO_CONTROL_BRIDGE_URL=http://127.0.0.1:18768 \
  FFPROBE_BIN=/usr/bin/ffprobe \
  "$BASE/.venv/bin/python" -m uvicorn stremio_catalog:app --host 127.0.0.1 --port 18776 --log-level warning \
  >"$LOG" 2>&1 &
echo $! >"$PID"
for i in $(seq 1 45); do
  if curl -fsS --max-time 2 http://127.0.0.1:18776/manifest.json >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
echo "CANARY_PID=$(cat "$PID")"
curl -fsS --max-time 10 http://127.0.0.1:18776/manifest.json
echo
python3 "$(dirname "$0")/test-canary.py"
kill "$(cat "$PID")" 2>/dev/null || true
rm -f "$PID"
