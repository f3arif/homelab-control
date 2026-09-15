#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---audit}"
case "$MODE" in
  --audit|--apply) ;;
  *) echo "usage: $0 [--audit|--apply]" >&2; exit 2 ;;
esac

EXPECTED_USER="coolyo"
EXPECTED_TS_IP="100.71.26.69"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_BRIDGE="$SOURCE_DIR/afz_commander_recovery_mcp.py"
TARGET_DIR="$HERMES_HOME/afz-commander-recovery"
TARGET_BRIDGE="$TARGET_DIR/afz_commander_recovery_mcp.py"
CONFIG="$HERMES_HOME/config.yaml"
STATE="$TARGET_DIR/install-state.json"
SERVER_NAME="afz-commander-recovery"

fail(){ echo "AFZ Commander recovery MCP: $*" >&2; exit 1; }

[ "$(id -un)" = "$EXPECTED_USER" ] || fail "wrong user: $(id -un)"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[ "$TS_IP" = "$EXPECTED_TS_IP" ] || fail "HP Envy Tailscale identity mismatch: $TS_IP"
[ -f "$SOURCE_BRIDGE" ] || fail "recovery bridge source missing: $SOURCE_BRIDGE"
[ -f "$CONFIG" ] || fail "Hermes config missing: $CONFIG"

HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
if [ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ]; then HERMES_BIN="$HOME/.local/bin/hermes"; fi
[ -n "$HERMES_BIN" ] && [ -x "$HERMES_BIN" ] || fail "Hermes launcher not found"

HERMES_PY=""
for p in   "$HERMES_HOME/hermes-agent/venv/bin/python"   "$HERMES_HOME/hermes-agent/.venv/bin/python"   "$HERMES_HOME/venv/bin/python"; do
  if [ -x "$p" ]; then HERMES_PY="$p"; break; fi
done
[ -n "$HERMES_PY" ] || fail "Hermes Python runtime not found"
"$HERMES_PY" -c 'import mcp, yaml; import hermes_cli.mcp_config' >/dev/null 2>&1 || fail "Hermes MCP/config Python modules unavailable"

SELFTEST="$("$HERMES_PY" "$SOURCE_BRIDGE" --self-test)"
"$HERMES_PY" - "$SELFTEST" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert d.get('ok') is True
assert d.get('tools') == ['afz_commander_pair_active_request']
assert d.get('arbitraryShell') is False
assert d.get('credentialAccess') is False
assert d.get('deviceCodeReturned') is False
PY

CURRENT_ENTRY="$("$HERMES_PY" - "$SERVER_NAME" <<'PY'
import json,sys
from hermes_cli.config import load_config
name=sys.argv[1]
print(json.dumps((load_config().get('mcp_servers') or {}).get(name),separators=(',',':')))
PY
)"

REACHABLE=false
HEALTH_JSON=""
if HEALTH_JSON="$("$HERMES_PY" - "$SOURCE_BRIDGE" <<'PY'
import importlib.util,json,sys
p=sys.argv[1]
s=importlib.util.spec_from_file_location('afz_commander_recovery_probe',p)
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
r=m._http_json('GET','/health',timeout=6)
print(json.dumps(r,separators=(',',':')))
raise SystemExit(0 if r.get('ok') else 4)
PY
)"; then REACHABLE=true; fi

if [ "$MODE" = "--audit" ]; then
  "$HERMES_PY" - "$TS_IP" "$TARGET_BRIDGE" "$CURRENT_ENTRY" "$SELFTEST" "$REACHABLE" "$HEALTH_JSON" <<'PY'
import json,os,sys
ts,target,entry,selftest,reachable,health=sys.argv[1:]
try:e=json.loads(entry)
except Exception:e=None
try:h=json.loads(health) if health else {}
except Exception:h={'ok':False,'error':'invalid-health-json'}
print(json.dumps({
 'schema':1,
 'ok':True,
 'classification':'AFZ_HERMES_COMMANDER_RECOVERY_AUDIT',
 'host':'hpenvy',
 'tailscaleIp':ts,
 'configured':isinstance(e,dict),
 'entry':e,
 'targetBridgePresent':os.path.isfile(target),
 'selfTest':json.loads(selftest),
 'windowsMainControlReachable':reachable.lower()=='true',
 'controlHealth':h,
 'pairingInvoked':False,
 'arbitraryShell':False,
},separators=(',',':')))
PY
  exit 0
fi

mkdir -p "$TARGET_DIR"
chmod 700 "$TARGET_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONFIG_BACKUP="$CONFIG.afz-commander-recovery-$STAMP.bak"
BRIDGE_BACKUP=""
cp -a "$CONFIG" "$CONFIG_BACKUP"
chmod 600 "$CONFIG_BACKUP" || true
if [ -f "$TARGET_BRIDGE" ]; then
  BRIDGE_BACKUP="$TARGET_BRIDGE.$STAMP.bak"
  cp -a "$TARGET_BRIDGE" "$BRIDGE_BACKUP"
fi

rollback(){
  rc=$?
  if [ "$rc" -ne 0 ]; then
    cp -a "$CONFIG_BACKUP" "$CONFIG" || true
    if [ -n "$BRIDGE_BACKUP" ] && [ -f "$BRIDGE_BACKUP" ]; then cp -a "$BRIDGE_BACKUP" "$TARGET_BRIDGE" || true; fi
  fi
  exit "$rc"
}
trap rollback EXIT

install -m 700 "$SOURCE_BRIDGE" "$TARGET_BRIDGE"

"$HERMES_PY" - "$HERMES_PY" "$TARGET_BRIDGE" "$SERVER_NAME" <<'PY'
import sys
from hermes_cli.mcp_config import _save_mcp_server
py,bridge,name=sys.argv[1:]
entry={
 'command':py,
 'args':[bridge],
 'enabled':True,
 'timeout':60,
 'connect_timeout':15,
 'supports_parallel_tool_calls':False,
 'tools':{'include':['afz_commander_pair_active_request']},
}
if not _save_mcp_server(name,entry):
    raise SystemExit('Hermes rejected Commander recovery MCP configuration')
PY

MCP_TEST="$("$HERMES_BIN" mcp test "$SERVER_NAME" 2>&1)" || { echo "$MCP_TEST" >&2; fail "Hermes MCP discovery failed"; }

FINAL_ENTRY="$("$HERMES_PY" - "$SERVER_NAME" <<'PY'
import json,sys
from hermes_cli.config import load_config
print(json.dumps((load_config().get('mcp_servers') or {}).get(sys.argv[1]),separators=(',',':')))
PY
)"

"$HERMES_PY" - "$STATE" "$TS_IP" "$CONFIG_BACKUP" "$BRIDGE_BACKUP" "$SELFTEST" "$FINAL_ENTRY" "$REACHABLE" "$HEALTH_JSON" <<'PY'
import json,os,sys,time
state,ts,cfg_bak,bridge_bak,selftest,entry,reachable,health=sys.argv[1:]
try:h=json.loads(health) if health else {}
except Exception:h={'ok':False,'error':'invalid-health-json'}
obj={
 'schema':1,'ok':True,'status':'ready',
 'classification':'AFZ_HERMES_COMMANDER_RECOVERY_READY',
 'host':'hpenvy','tailscaleIp':ts,
 'configBackup':cfg_bak,'bridgeBackup':bridge_bak or None,
 'selfTest':json.loads(selftest),'entry':json.loads(entry),
 'windowsMainControlReachableAtInstall':reachable.lower()=='true',
 'controlHealthAtInstall':h,
 'tools':['afz_commander_pair_active_request'],
 'pairingInvoked':False,
 'supportsParallelToolCalls':False,
 'arbitraryShell':False,'arbitraryUrl':False,
 'finishedAt':time.strftime('%Y-%m-%dT%H:%M:%S%z')
}
with open(state,'w',encoding='utf-8') as f: json.dump(obj,f,separators=(',',':'))
os.chmod(state,0o600)
print(json.dumps(obj,separators=(',',':')))
PY

trap - EXIT
exit 0
