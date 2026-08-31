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
SOURCE_BRIDGE="$SOURCE_DIR/afz_hermes_mcp.py"
TARGET_DIR="$HERMES_HOME/afz-mcp"
TARGET_BRIDGE="$TARGET_DIR/afz_hermes_mcp.py"
CONFIG="$HERMES_HOME/config.yaml"
STATE="$TARGET_DIR/install-state.json"
TOOLS='["afz_control_health","afz_windows_wsl_memory_audit"]'

fail() { echo "AFZ Hermes MCP: $*" >&2; exit 1; }

[ "$(id -un)" = "$EXPECTED_USER" ] || fail "wrong user: $(id -un)"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[ "$TS_IP" = "$EXPECTED_TS_IP" ] || fail "HP Envy Tailscale identity mismatch: $TS_IP"
[ -f "$SOURCE_BRIDGE" ] || fail "bridge source missing: $SOURCE_BRIDGE"
[ -f "$CONFIG" ] || fail "Hermes config missing: $CONFIG"

HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
if [ -z "$HERMES_BIN" ] && [ -x "$HOME/.local/bin/hermes" ]; then HERMES_BIN="$HOME/.local/bin/hermes"; fi
[ -n "$HERMES_BIN" ] && [ -x "$HERMES_BIN" ] || fail "Hermes launcher not found"

HERMES_PY=""
for p in \
  "$HERMES_HOME/hermes-agent/venv/bin/python" \
  "$HERMES_HOME/hermes-agent/.venv/bin/python" \
  "$HERMES_HOME/venv/bin/python"; do
  if [ -x "$p" ]; then HERMES_PY="$p"; break; fi
done
[ -n "$HERMES_PY" ] || fail "Hermes Python runtime not found"
"$HERMES_PY" -c 'import mcp, yaml; import hermes_cli.mcp_config' >/dev/null 2>&1 || fail "Hermes MCP/config Python modules unavailable"

VERSION="$($HERMES_BIN --version 2>/dev/null | head -n1 || true)"
CURRENT_ENTRY="$($HERMES_PY - "$CONFIG" <<'PY'
import json, sys
from hermes_cli.config import load_config
cfg=load_config()
print(json.dumps((cfg.get('mcp_servers') or {}).get('afz-fabric'), separators=(',',':')))
PY
)"

# Real read-only acceptance gate before any file/config mutation. This imports
# the staged bridge directly, reads AFZ Control health, then invokes the
# existing typed read-only Windows/WSL audit. The latter proves HP Envy has the
# required Tailscale deploy authorization without running a model or shell tool.
PRECHECK=""
PRECHECK_OK=false
if PRECHECK="$($HERMES_PY - "$SOURCE_BRIDGE" <<'PY'
import importlib.util, json, sys
path=sys.argv[1]
spec=importlib.util.spec_from_file_location('afz_hermes_mcp_precheck', path)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
health=json.loads(mod.afz_control_health())
audit=json.loads(mod.afz_windows_wsl_memory_audit())
ok=bool(health.get('ok')) and bool(audit.get('ok'))
obj={
  'ok':ok,
  'classification':'AFZ_HERMES_MCP_PRECHECK_PASS' if ok else 'AFZ_HERMES_MCP_PRECHECK_BLOCKED',
  'controlHealth':health,
  'authorizationProbe':audit,
  'readOnly':True,
  'generationTestStarted':False,
  'ollamaExposureChanged':False,
}
print(json.dumps(obj,separators=(',',':')))
raise SystemExit(0 if ok else 4)
PY
)"; then
  PRECHECK_OK=true
fi

if [ "$MODE" = "--audit" ]; then
  "$HERMES_PY" - "$VERSION" "$TS_IP" "$HERMES_PY" "$TARGET_BRIDGE" "$CURRENT_ENTRY" "$PRECHECK" "$PRECHECK_OK" <<'PY'
import json, os, sys
version, ts_ip, py, target, entry, precheck, precheck_ok = sys.argv[1:]
try: parsed=json.loads(entry)
except Exception: parsed=None
try: pre=json.loads(precheck)
except Exception: pre={'ok':False,'error':'precheck-output-invalid'}
ok=precheck_ok.lower()=='true' and bool(pre.get('ok'))
print(json.dumps({
  'schema':1,'ok':ok,'readOnly':True,
  'classification':'AFZ_HERMES_MCP_AUDIT_READY' if ok else 'AFZ_HERMES_MCP_AUDIT_BLOCKED',
  'host':'hpenvy','tailscaleIp':ts_ip,'hermesVersion':version,'python':py,
  'targetBridge':target,'targetBridgePresent':os.path.isfile(target),
  'configured':isinstance(parsed,dict),'entry':parsed,'precheck':pre,
  'gatewayStarted':False,'generationTestStarted':False,'ollamaExposureChanged':False
}, separators=(',',':')))
PY
  exit 0
fi

[ "$PRECHECK_OK" = "true" ] || { echo "$PRECHECK" >&2; fail "typed AFZ precheck failed; refusing MCP activation"; }

mkdir -p "$TARGET_DIR"
chmod 700 "$TARGET_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONFIG_BACKUP="$CONFIG.afz-mcp-$STAMP.bak"
BRIDGE_BACKUP=""
cp -a "$CONFIG" "$CONFIG_BACKUP"
chmod 600 "$CONFIG_BACKUP" || true
if [ -f "$TARGET_BRIDGE" ]; then
  BRIDGE_BACKUP="$TARGET_BRIDGE.$STAMP.bak"
  cp -a "$TARGET_BRIDGE" "$BRIDGE_BACKUP"
fi

rollback() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    cp -a "$CONFIG_BACKUP" "$CONFIG" || true
    if [ -n "$BRIDGE_BACKUP" ] && [ -f "$BRIDGE_BACKUP" ]; then
      cp -a "$BRIDGE_BACKUP" "$TARGET_BRIDGE" || true
    fi
  fi
  exit "$rc"
}
trap rollback EXIT

install -m 700 "$SOURCE_BRIDGE" "$TARGET_BRIDGE"
SELFTEST="$($HERMES_PY "$TARGET_BRIDGE" --self-test)"
SELFTEST_OK="$($HERMES_PY - "$SELFTEST" <<'PY'
import json, sys
try: d=json.loads(sys.argv[1]); print('true' if d.get('ok') else 'false')
except Exception: print('false')
PY
)"
[ "$SELFTEST_OK" = "true" ] || fail "bridge self-test failed"

"$HERMES_PY" - "$HERMES_PY" "$TARGET_BRIDGE" <<'PY'
import sys
from hermes_cli.mcp_config import _save_mcp_server
py, bridge = sys.argv[1:]
entry = {
  'command': py,
  'args': [bridge],
  'enabled': True,
  'timeout': 60,
  'connect_timeout': 15,
  'supports_parallel_tool_calls': False,
  'tools': {'include': ['afz_control_health','afz_windows_wsl_memory_audit']},
}
if not _save_mcp_server('afz-fabric', entry):
    raise SystemExit('Hermes rejected afz-fabric MCP configuration')
PY

# Discovery-only MCP validation. This starts the local stdio server and lists
# its tools; it does not invoke either AFZ tool and does not call a model.
MCP_TEST="$($HERMES_BIN mcp test afz-fabric 2>&1)" || { echo "$MCP_TEST" >&2; fail "hermes mcp test afz-fabric failed"; }

FINAL_ENTRY="$($HERMES_PY - <<'PY'
import json
from hermes_cli.config import load_config
print(json.dumps((load_config().get('mcp_servers') or {}).get('afz-fabric'), separators=(',',':')))
PY
)"

"$HERMES_PY" - "$STATE" "$VERSION" "$TS_IP" "$CONFIG_BACKUP" "$BRIDGE_BACKUP" "$SELFTEST" "$FINAL_ENTRY" "$PRECHECK" <<'PY'
import json, os, sys, time
state, version, ts_ip, cfg_bak, bridge_bak, selftest, entry, precheck = sys.argv[1:]
obj={
  'schema':1,'ok':True,'status':'ready','classification':'AFZ_HERMES_MCP_READY_READONLY_TYPED',
  'host':'hpenvy','tailscaleIp':ts_ip,'hermesVersion':version,
  'configBackup':cfg_bak,'bridgeBackup':bridge_bak or None,
  'precheck':json.loads(precheck),'selfTest':json.loads(selftest),'entry':json.loads(entry),
  'tools':['afz_control_health','afz_windows_wsl_memory_audit'],
  'supportsParallelToolCalls':False,'arbitraryShell':False,'arbitraryUrl':False,
  'gatewayStarted':False,'generationTestStarted':False,'ollamaExposureChanged':False,
  'finishedAt':time.strftime('%Y-%m-%dT%H:%M:%S%z')
}
os.makedirs(os.path.dirname(state), exist_ok=True)
with open(state,'w',encoding='utf-8') as f: json.dump(obj,f,separators=(',',':'))
os.chmod(state,0o600)
print(json.dumps(obj,separators=(',',':')))
PY

trap - EXIT
exit 0
