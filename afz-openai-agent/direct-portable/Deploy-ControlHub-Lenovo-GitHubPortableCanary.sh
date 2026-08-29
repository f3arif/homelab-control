#!/bin/sh
set -eu
ROOT="$HOME/afz-control-hub"
MAIN="$ROOT/app/main.py"
GW="$ROOT/lenovo_direct_exec_gateway.py"
MAIN_SHA='b1b2c4e1299c2d90febc93e8aca84e6540fae3794e091d0748cd520d5ed935e5'
GW_SHA='32768b2795ff0a955ace008c006bd305da5587dd78661b09b972dba24fc273a6'
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$ROOT/backups/github-portable-canary-$STAMP"
mkdir -p "$BACKUP"
rollback(){
  echo 'ROLLBACK=START'
  [ -f "$BACKUP/main.py" ] && cp "$BACKUP/main.py" "$MAIN"
  [ -f "$BACKUP/lenovo_direct_exec_gateway.py" ] && cp "$BACKUP/lenovo_direct_exec_gateway.py" "$GW"
  (cd "$ROOT" && docker compose up -d --build api >/tmp/afz-portable-api-rollback.log 2>&1) || true
  systemctl --user restart afz-lenovo-direct-exec-gateway.service >/dev/null 2>&1 || true
  echo 'ROLLBACK=DONE'
}
trap 'rc=$?; if [ $rc -ne 0 ]; then rollback; fi; exit $rc' EXIT
actual_main="$(sha256sum "$MAIN" | awk '{print $1}')"; actual_gw="$(sha256sum "$GW" | awk '{print $1}')"
echo "MAIN_SHA_BEFORE=$actual_main"; echo "GATEWAY_SHA_BEFORE=$actual_gw"
[ "$actual_main" = "$MAIN_SHA" ] || { echo 'ERROR=main_sha_mismatch'; exit 20; }
[ "$actual_gw" = "$GW_SHA" ] || { echo 'ERROR=gateway_sha_mismatch'; exit 21; }
cp "$MAIN" "$BACKUP/main.py"; cp "$GW" "$BACKUP/lenovo_direct_exec_gateway.py"; echo "BACKUP=$BACKUP"
python3 - "$MAIN" "$GW" <<'PY'
import sys
from pathlib import Path
main=Path(sys.argv[1]); gw=Path(sys.argv[2]); t=main.read_text(encoding='utf-8')
if 'AFZ_GITHUB_PORTABLE_CANARY_V1' in t: raise SystemExit('main marker already present unexpectedly on guarded SHA')
t=t.replace('import asyncio, hmac, json, os, uuid','import asyncio, hmac, json, os, re, uuid',1)
old='READONLY_ACTIONS={"system-status","ops-health","lenovo-health","h3-health"}\napp=FastAPI(title="AFZ Control Hub",version="0.3.2-safe-readonly")'
new='''READONLY_ACTIONS={"system-status","ops-health","lenovo-health","h3-health"}\n# AFZ_GITHUB_PORTABLE_CANARY_V1\nPORTABLE_ACTION="portable-powershell-github"\nSAFE_TYPED_ACTIONS=READONLY_ACTIONS|{PORTABLE_ACTION}\nPORTABLE_REPO="f3arif/homelab-control"\nPORTABLE_PATH="afz-openai-agent/portable-jobs/lenovo-direct-canary-r1.ps1"\nPORTABLE_WORKER="lenovo-direct-1"\napp=FastAPI(title="AFZ Control Hub",version="0.3.3-safe-typed-canary")'''
if old not in t: raise SystemExit('main constants anchor missing')
t=t.replace(old,new,1)
t=t.replace('{"mode":MODE,"version":"0.3.2-safe-readonly"}','{"mode":MODE,"version":"0.3.3-safe-typed-canary"}',1)
t=t.replace('{"ok":True,"service":"afz-control-hub","version":"0.3.2-safe-readonly","mode":MODE','{"ok":True,"service":"afz-control-hub","version":"0.3.3-safe-typed-canary","mode":MODE',1)
anchor="@app.post('/api/jobs')\ndef create_job(j:JobCreate,request:Request):"
validator='''def validate_portable_job(j:JobCreate):\n    if j.action!=PORTABLE_ACTION: return\n    p=j.payload\n    if j.project!='AFZ-Direct-Canary': raise HTTPException(422,'portable canary project mismatch')\n    if j.preferred_worker!=PORTABLE_WORKER: raise HTTPException(422,'portable canary worker mismatch')\n    if set(j.required_capabilities)!={'windows','lenovo','github-portable-powershell'}: raise HTTPException(422,'portable canary capabilities mismatch')\n    if j.max_attempts!=1: raise HTTPException(422,'portable canary max_attempts must be 1')\n    if set(p)!={'repo','commit','path','sha256','timeout_seconds'}: raise HTTPException(422,'portable payload keys invalid')\n    if p.get('repo')!=PORTABLE_REPO: raise HTTPException(422,'portable repo not allowlisted')\n    if not isinstance(p.get('commit'),str) or not re.fullmatch(r'[0-9a-fA-F]{40}',p['commit']): raise HTTPException(422,'portable commit must be exact SHA')\n    if p.get('path')!=PORTABLE_PATH: raise HTTPException(422,'portable canary path mismatch')\n    if not isinstance(p.get('sha256'),str) or not re.fullmatch(r'[0-9a-fA-F]{64}',p['sha256']): raise HTTPException(422,'portable sha256 invalid')\n    timeout=p.get('timeout_seconds')\n    if isinstance(timeout,bool) or not isinstance(timeout,int) or timeout<5 or timeout>300: raise HTTPException(422,'portable timeout out of range')\n\n@app.post('/api/jobs')\ndef create_job(j:JobCreate,request:Request):'''
if anchor not in t: raise SystemExit('main create-job anchor missing')
t=t.replace(anchor,validator,1)
t=t.replace("if MODE=='safe-readonly' and j.action not in READONLY_ACTIONS: raise HTTPException(403,'action not allowlisted in safe-readonly mode')","if MODE=='safe-readonly' and j.action not in SAFE_TYPED_ACTIONS: raise HTTPException(403,'action not allowlisted in safe-readonly mode')\n    validate_portable_job(j)",1)
main.write_text(t,encoding='utf-8')
g=gw.read_text(encoding='utf-8')
if 'AFZ_GITHUB_PORTABLE_CANARY_V1' in g: raise SystemExit('gateway marker already present unexpectedly on guarded SHA')
old="ACTIONS={ACTION,'lenovo-sleep-if-idle'} # AFZ_LENOVO_SLEEP_SCOPE_V1"; new="ACTIONS={ACTION,'lenovo-sleep-if-idle','portable-powershell-github'} # AFZ_LENOVO_SLEEP_SCOPE_V1 # AFZ_GITHUB_PORTABLE_CANARY_V1"
if old not in g: raise SystemExit('gateway ACTIONS anchor missing')
g=g.replace(old,new,1).replace("VERSION='1.0'","VERSION='1.1-github-portable-canary'",1)
oldcaps="['windows','lenovo','direct-worker','allowlisted-lenovo-health','bounded-sleep-control']"; newcaps="['windows','lenovo','direct-worker','allowlisted-lenovo-health','bounded-sleep-control','github-portable-powershell-canary']"
if oldcaps not in g: raise SystemExit('gateway capabilities anchor missing')
g=g.replace(oldcaps,newcaps,1); gw.write_text(g,encoding='utf-8')
PY
python3 -m py_compile "$MAIN" "$GW"; echo 'PY_COMPILE=PASS'
(cd "$ROOT" && docker compose up -d --build api >/tmp/afz-portable-api-build.log 2>&1)
systemctl --user restart afz-lenovo-direct-exec-gateway.service
for i in $(seq 1 30); do if curl -fsS --max-time 2 http://100.71.26.69:8789/health >/tmp/afz-hub-health.json 2>/dev/null && curl -fsS --max-time 2 http://100.71.26.69:8795/health >/tmp/afz-gw-health.json 2>/dev/null; then break; fi; sleep 1; done
python3 - <<'PY'
import json
h=json.load(open('/tmp/afz-hub-health.json')); g=json.load(open('/tmp/afz-gw-health.json'))
assert h.get('ok') is True and h.get('version')=='0.3.3-safe-typed-canary' and h.get('mode')=='safe-readonly',h
assert set(g.get('execution_scope') or [])=={'lenovo-health','lenovo-sleep-if-idle','portable-powershell-github'},g
assert g.get('version')=='1.1-github-portable-canary' and g.get('job_create_exposed') is False and g.get('routing_authority') is False and g.get('project_execution') is False,g
print('HEALTH_VALIDATION=PASS')
PY
U="$(curl -sS -o /tmp/afz-unauth.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"action":"portable-powershell-github"}' http://100.71.26.69:8789/api/jobs || true)"
S="$(curl -sS -o /tmp/afz-srcdeny.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"ac_power_online":true,"worker_ready":true}' http://100.71.26.69:8795/claim || true)"
[ "$U" = '401' ] || { echo "ERROR=unauth_jobs_http_$U"; exit 30; }; [ "$S" = '403' ] || { echo "ERROR=hp_source_gateway_http_$S"; exit 31; }
python3 - <<'PY'
import json,urllib.request,urllib.error
from pathlib import Path
token=''
for line in (Path.home()/'afz-control-hub/.env').read_text(encoding='utf-8',errors='replace').splitlines():
    if line.startswith('AFZ_HUB_TOKEN='): token=line.split('=',1)[1].strip(); break
if not token: raise SystemExit('hub token missing')
body=json.dumps({'project':'AFZ-Direct-Canary','action':'portable-powershell-github','payload':{},'required_capabilities':['windows','lenovo','github-portable-powershell'],'preferred_worker':'lenovo-direct-1','max_attempts':1}).encode()
req=urllib.request.Request('http://100.71.26.69:8789/api/jobs',data=body,headers={'X-AFZ-Token':token,'Content-Type':'application/json'},method='POST')
try: urllib.request.urlopen(req,timeout=3); raise SystemExit('malformed portable job unexpectedly accepted')
except urllib.error.HTTPError as e:
    if e.code!=422: raise
print('AUTH_VALIDATION_REJECT=PASS')
PY
trap - EXIT
echo "MAIN_SHA_AFTER=$(sha256sum "$MAIN" | awk '{print $1}')"; echo "GATEWAY_SHA_AFTER=$(sha256sum "$GW" | awk '{print $1}')"
echo 'RESULT=PASS_CONTROLHUB_LENOVO_GITHUB_PORTABLE_CANARY_PATCH'
