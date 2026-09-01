#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$ExpectedTarget='coolyo@100.71.26.69'
$ExpectedProvider='openai-codex'
$ExpectedModel='gpt-5.6-luna'
$ExpectedAction='verify-and-configure-primary'
$TaskName='HP Envy Hermes OpenAI Codex Primary'
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-hermes-openai-codex-primary'
$MirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$MirrorPath=Join-Path $MirrorRoot 'HPENVY-HERMES-OPENAI-CODEX-PRIMARY-LATEST.txt'
$KnownHostsPath=Join-Path $StateRoot 'hpenvy-tailscale-known_hosts'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

function Write-State([object]$Object,[string]$Path){
  $json=$Object | ConvertTo-Json -Depth 12
  $json | Set-Content -LiteralPath $Path -Encoding UTF8
  try{
    if(Test-Path -LiteralPath $MirrorRoot -PathType Container){
      $json | Set-Content -LiteralPath $MirrorPath -Encoding UTF8
    }
  }catch{}
}
function Classify-SshFailure([string]$Text,[int]$ExitCode){
  if($ExitCode -eq 0){return 'SSH_OK'}
  $t=([string]$Text).ToLowerInvariant()
  if($t -match 'host key verification failed|remote host identification has changed'){return 'SSH_HOST_KEY_REJECTED'}
  if($t -match 'permission denied|no supported authentication methods available'){return 'SSH_AUTH_REJECTED'}
  if($t -match 'connection timed out|operation timed out'){return 'SSH_CONNECT_TIMEOUT'}
  if($t -match 'connection refused'){return 'SSH_CONNECTION_REFUSED'}
  if($t -match 'no route to host|network is unreachable'){return 'SSH_NETWORK_UNREACHABLE'}
  if($t -match 'could not resolve hostname|name or service not known'){return 'SSH_NAME_RESOLUTION_FAILED'}
  if($t -match 'connection reset|connection closed'){return 'SSH_CONNECTION_CLOSED'}
  return 'SSH_EXIT_'+$ExitCode
}
function Marker([string]$Text,[string]$Name){
  $m=[regex]::Match([string]$Text,'(?m)^'+[regex]::Escape($Name)+'=([^\r\n]*)$')
  if($m.Success){return $m.Groups[1].Value.Trim()}
  return $null
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1){throw 'Unsupported request schema'}
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}
if(([string]$req.taskName).Trim() -ne $TaskName){throw 'Task name mismatch'}
if(([string]$req.target).Trim() -ne $ExpectedTarget){throw 'Target mismatch'}
if(([string]$req.action).Trim().ToLowerInvariant() -ne $ExpectedAction){throw 'Action mismatch'}
if(([string]$req.provider).Trim().ToLowerInvariant() -ne $ExpectedProvider){throw 'Provider mismatch'}
if(([string]$req.model).Trim() -ne $ExpectedModel){throw 'Model mismatch'}
if(-not [bool]$req.allow_provider_switch){throw 'Provider switch must be explicitly enabled'}
if([bool]$req.allow_generation -or [bool]$req.allow_gateway_start -or [bool]$req.allow_firewall_change -or [bool]$req.allow_tailscale_change){throw 'Unsafe request flags'}
if(([string]$req.status).Trim().ToLowerInvariant() -ne 'active'){throw 'Request is not active'}

$statePath=Join-Path $StateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$existing.classification -eq 'HP_HERMES_CODEX_PRIMARY_CONFIGURED'){
      Write-State $existing $statePath
      Write-Output ($existing|ConvertTo-Json -Depth 12 -Compress)
      exit 0
    }
  }catch{}
}

$ssh=(Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if(-not $ssh){$ssh=(Get-Command ssh -ErrorAction SilentlyContinue).Source}
if(-not $ssh){throw 'OpenSSH client not found'}

$remoteScript=@'
set -u
LAUNCHER="$HOME/.local/bin/hermes"
HERMES_HOME="$HOME/.hermes"
CONFIG="$HERMES_HOME/config.yaml"
AUTH="$HERMES_HOME/auth.json"
WRAPPER="$HOME/.local/bin/hermes-afz"
MODEL='gpt-5.6-luna'
PROVIDER='openai-codex'
CONTEXT='65536'

printf 'HOST=%s\n' "$(hostname 2>/dev/null || true)"
printf 'USER=%s\n' "$(id -un 2>/dev/null || true)"
if [ "$(hostname 2>/dev/null || true)" != 'hpenvy' ] || [ "$(id -un 2>/dev/null || true)" != 'coolyo' ]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_WRONG_TARGET'
  exit 41
fi
if [ ! -x "$LAUNCHER" ] || [ ! -r "$CONFIG" ]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_INSTALL_INCOMPLETE'
  exit 42
fi

AUTH_VERIFIED="$(python3 - "$AUTH" <<'PY'
import json,sys
p=sys.argv[1]
ok=False
try:
    with open(p,'r',encoding='utf-8') as f:
        d=json.load(f)
    provider=(d.get('providers') or {}).get('openai-codex')
    tokens=provider.get('tokens') if isinstance(provider,dict) else None
    ok=isinstance(tokens,dict) and bool(tokens.get('access_token')) and bool(tokens.get('refresh_token'))
except Exception:
    ok=False
print('true' if ok else 'false')
PY
)"
printf 'AUTH_VERIFIED=%s\n' "$AUTH_VERIFIED"
if [ "$AUTH_VERIFIED" != 'true' ]; then
  echo 'PROVIDER_SWITCHED=false'
  echo 'GENERATION_STARTED=false'
  echo 'GATEWAY_STARTED=false'
  echo 'SECRET_VALUES_EMITTED=false'
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_AUTH_NOT_VERIFIED'
  exit 44
fi
if pgrep -af '[h]ermes.*gateway' >/dev/null 2>&1; then
  echo 'PROVIDER_SWITCHED=false'
  echo 'GENERATION_STARTED=false'
  echo 'GATEWAY_STARTED=false'
  echo 'SECRET_VALUES_EMITTED=false'
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_GATEWAY_ALREADY_RUNNING_SAFE_STOP'
  exit 43
fi

backup="$CONFIG.afz-pre-codex-$(date +%Y%m%dT%H%M%S).bak"
cp -p "$CONFIG" "$backup"
printf 'CONFIG_BACKUP_CREATED=true\n'

if ! "$LAUNCHER" config set model.default "$MODEL" >/dev/null 2>&1; then
  cp -p "$backup" "$CONFIG"
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_CONFIG_SET_FAILED'
  exit 45
fi
if ! "$LAUNCHER" config set model.provider "$PROVIDER" >/dev/null 2>&1; then
  cp -p "$backup" "$CONFIG"
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_CONFIG_SET_FAILED'
  exit 45
fi
if ! "$LAUNCHER" config set model.context_length "$CONTEXT" >/dev/null 2>&1; then
  cp -p "$backup" "$CONFIG"
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_CONFIG_SET_FAILED'
  exit 45
fi

if ! "$LAUNCHER" config unset model.base_url >/dev/null 2>&1; then
  python3 - "$CONFIG" <<'PY'
import sys,re
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f: lines=f.readlines()
out=[]; in_model=False
for line in lines:
    if re.match(r'^model:\s*(?:#.*)?$', line):
        in_model=True; out.append(line); continue
    if in_model and re.match(r'^[^\s#][^:]*:', line):
        in_model=False
    if in_model and re.match(r'^\s+base_url\s*:', line):
        continue
    out.append(line)
with open(p,'w',encoding='utf-8') as f: f.writelines(out)
PY
fi

mkdir -p "$HOME/.local/bin"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/hermes" "$@"
EOF
chmod 700 "$WRAPPER"

provider="$(awk '/^model:/{m=1;next} m && /^[^[:space:]#]/{m=0} m && /^[[:space:]]+provider:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$CONFIG")"
model="$(awk '/^model:/{m=1;next} m && /^[^[:space:]#]/{m=0} m && /^[[:space:]]+default:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$CONFIG")"
ctx="$(awk '/^model:/{m=1;next} m && /^[^[:space:]#]/{m=0} m && /^[[:space:]]+context_length:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$CONFIG")"
base="$(awk '/^model:/{m=1;next} m && /^[^[:space:]#]/{m=0} m && /^[[:space:]]+base_url:/{print;exit}' "$CONFIG")"
base_present=false; [ -n "$base" ] && base_present=true
printf 'MODEL=%s\nPROVIDER=%s\nCONTEXT_LENGTH=%s\nBASE_URL_PRESENT=%s\n' "$model" "$provider" "$ctx" "$base_present"
printf 'PROVIDER_SWITCHED=true\nGENERATION_STARTED=false\nGATEWAY_STARTED=false\nSECRET_VALUES_EMITTED=false\n'

if [ "$model" = "$MODEL" ] && [ "$provider" = "$PROVIDER" ] && [ "$ctx" = "$CONTEXT" ] && [ "$base_present" = false ]; then
  echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_PRIMARY_CONFIGURED'
  exit 0
fi
cp -p "$backup" "$CONFIG"
echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_CONFIG_VERIFY_FAILED_ROLLED_BACK'
exit 46
'@

# Use a job-scoped known-hosts file instead of the interactive user's global
# known_hosts. The endpoint is the fixed Tailscale IP from the typed request.
# accept-new permits only first trust for this dedicated file; any later key change
# is still rejected by OpenSSH. No Tailscale, firewall, or global SSH settings change.
$sshArgs=@(
  '-o','BatchMode=yes',
  '-o','ConnectTimeout=15',
  '-o',("UserKnownHostsFile={0}" -f $KnownHostsPath),
  '-o','StrictHostKeyChecking=accept-new',
  $ExpectedTarget,
  'bash -s'
)
$old=$ErrorActionPreference;$ErrorActionPreference='Continue'
$raw=($remoteScript | & $ssh @sshArgs 2>&1 | Out-String).Trim()
$sshExit=$LASTEXITCODE
$ErrorActionPreference=$old
$sshClass=Classify-SshFailure $raw $sshExit
$classification=Marker $raw 'FINAL_CLASSIFICATION'
if([string]::IsNullOrWhiteSpace($classification)){$classification=$(if($sshExit -ne 0){$sshClass}else{'HP_HERMES_CODEX_UNKNOWN_RESULT'})}
$r=[ordered]@{
  schema=1
  requestId=$id
  taskName=$TaskName
  target=$ExpectedTarget
  provider=$ExpectedProvider
  model=$ExpectedModel
  classification=$classification
  authVerified=((Marker $raw 'AUTH_VERIFIED') -eq 'true')
  configuredProvider=(Marker $raw 'PROVIDER')
  configuredModel=(Marker $raw 'MODEL')
  contextLength=(Marker $raw 'CONTEXT_LENGTH')
  baseUrlPresent=((Marker $raw 'BASE_URL_PRESENT') -eq 'true')
  providerSwitched=((Marker $raw 'PROVIDER_SWITCHED') -eq 'true')
  generationStarted=$false
  gatewayStarted=$false
  secretValuesEmitted=$false
  sshExitCode=$sshExit
  sshClassification=$sshClass
  sshKnownHostsScope='afz-job-local-tailscale-ip'
  globalKnownHostsModified=$false
  rawOutputPersistedInResult=$false
  githubControl=$true
  oneDriveRole='observability-only'
  time=(Get-Date -Format o)
}
Write-State $r $statePath
Write-Output ($r|ConvertTo-Json -Depth 12 -Compress)
if($classification -ne 'HP_HERMES_CODEX_PRIMARY_CONFIGURED'){exit 47}
exit 0
