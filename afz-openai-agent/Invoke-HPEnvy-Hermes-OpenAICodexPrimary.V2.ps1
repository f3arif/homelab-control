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
$SystemStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-hermes-openai-codex-primary'
$UserStateRoot='C:\Users\Faiz\AppData\Local\AFZ\CodexPrimary'
$MirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$MirrorPath=Join-Path $MirrorRoot 'HPENVY-HERMES-OPENAI-CODEX-PRIMARY-LATEST.txt'
$HookMirror='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius\HPENVY-HERMES-OPENAI-CODEX-PRIMARY-HOOK-LATEST.txt'

function Marker([string]$Text,[string]$Name){
  $m=[regex]::Match([string]$Text,'(?m)^'+[regex]::Escape($Name)+'=([^\r\n]*)$')
  if($m.Success){return $m.Groups[1].Value.Trim()}
  return $null
}
function SshClass([string]$Text,[int]$Code){
  if($Code -eq 0){return 'SSH_OK'}
  $t=([string]$Text).ToLowerInvariant()
  if($t -match 'host key verification failed|remote host identification has changed'){return 'SSH_HOST_KEY_REJECTED'}
  if($t -match 'permission denied|no supported authentication methods available|bad permissions'){return 'SSH_AUTH_REJECTED'}
  if($t -match 'connection timed out|operation timed out'){return 'SSH_CONNECT_TIMEOUT'}
  if($t -match 'connection refused'){return 'SSH_CONNECTION_REFUSED'}
  if($t -match 'no route to host|network is unreachable'){return 'SSH_NETWORK_UNREACHABLE'}
  return 'SSH_EXIT_'+$Code
}

$currentName=''
try{$currentName=[Security.Principal.WindowsIdentity]::GetCurrent().Name}catch{$currentName="$env:USERDOMAIN\$env:USERNAME"}
$isSystem=($currentName -match '(?i)(^|\\)SYSTEM$' -or [string]$env:USERNAME -ieq 'SYSTEM')
$StateRoot=$(if($isSystem){$SystemStateRoot}else{$UserStateRoot})
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
function Write-State([object]$Object,[string]$Path){
  $json=$Object | ConvertTo-Json -Depth 12
  try{$json | Set-Content -LiteralPath $Path -Encoding UTF8}catch{}
  try{if(Test-Path -LiteralPath $MirrorRoot -PathType Container){$json | Set-Content -LiteralPath $MirrorPath -Encoding UTF8}}catch{}
  try{$hookDir=Split-Path -Parent $HookMirror;if(Test-Path -LiteralPath $hookDir -PathType Container){$json | Set-Content -LiteralPath $HookMirror -Encoding UTF8}}catch{}
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw 'Request missing'}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request identity'}
if(([string]$req.taskName).Trim() -ne $TaskName -or ([string]$req.target).Trim() -ne $ExpectedTarget){throw 'Request target mismatch'}
if(([string]$req.action).Trim().ToLowerInvariant() -ne $ExpectedAction -or ([string]$req.provider).Trim().ToLowerInvariant() -ne $ExpectedProvider -or ([string]$req.model).Trim() -ne $ExpectedModel){throw 'Request model/provider mismatch'}
if(-not [bool]$req.allow_provider_switch -or [bool]$req.allow_generation -or [bool]$req.allow_gateway_start -or [bool]$req.allow_firewall_change -or [bool]$req.allow_tailscale_change){throw 'Unsafe request flags'}
if(([string]$req.status).Trim().ToLowerInvariant() -ne 'active'){throw 'Request is not active'}

$statePath=Join-Path $StateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$prior.classification -eq 'HP_HERMES_CODEX_PRIMARY_CONFIGURED'){
      Write-State $prior $statePath
      Write-Output ($prior|ConvertTo-Json -Depth 12 -Compress)
      exit 0
    }
  }catch{}
}

if($isSystem){
  if([string]$env:AFZ_CODEX_USER_WORKER -eq '1'){
    $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_USER_WORKER_WRONG_IDENTITY';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;executionIdentity='SYSTEM';time=(Get-Date -Format o)}
    Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 49
  }
  $queueDir='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Queue\windows-main'
  $workerResultDir='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
  $taskId=('000-hpenvy-hermes-codex-faiz-'+$id)
  $taskPath=Join-Path $queueDir ($taskId+'.ps1')
  $workerResultPath=Join-Path $workerResultDir ($taskId+'.txt')
  New-Item -ItemType Directory -Force -Path $queueDir | Out-Null
  if(-not(Test-Path -LiteralPath $taskPath -PathType Leaf) -and -not(Test-Path -LiteralPath $workerResultPath -PathType Leaf)){
    $task=@"
`$ErrorActionPreference='Stop'
`$env:AFZ_CODEX_USER_WORKER='1'
`$runner='$InstallRoot\afz-openai-agent\Invoke-HPEnvy-Hermes-OpenAICodexPrimary.ps1'
`$request='$InstallRoot\afz-openai-agent\requests\hpenvy-hermes-openai-codex-primary.json'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `$runner -InstallRoot '$InstallRoot' -RequestPath `$request
`$code=`$LASTEXITCODE
if(`$code -ne 0){exit `$code}
exit 0
"@
    $tmp=Join-Path $queueDir ('.'+$taskId+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    [IO.File]::WriteAllText($tmp,$task,(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $taskPath -Force
  }
  $r=[ordered]@{schema=1;requestId=$id;taskName=$TaskName;target=$ExpectedTarget;provider=$ExpectedProvider;model=$ExpectedModel;classification='HP_HERMES_CODEX_QUEUED_FAIZ_WORKER';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;executionIdentity='SYSTEM';worker='windows-main';queueTask=$taskId;privateKeyCopied=$false;globalKnownHostsModified=$false;rawOutputPersistedInResult=$false;githubControl=$true;oneDriveRole='execution-bridge-existing-worker';time=(Get-Date -Format o)}
  Write-State $r $statePath
  Write-Output ($r|ConvertTo-Json -Depth 12 -Compress)
  exit 0
}

$ssh=(Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if(-not $ssh){$ssh=(Get-Command ssh -ErrorAction SilentlyContinue).Source}
if(-not $ssh){throw 'OpenSSH client not found'}

# Validate the proven alias using OpenSSH's resolved config. ssh -G emits whitespace,
# not NAME=value, so parse it explicitly without inspecting any private-key bytes.
$old=$ErrorActionPreference;$ErrorActionPreference='Continue'
$resolved=(& $ssh -G hpenvy-restic 2>&1 | Out-String).Trim();$resolveExit=$LASTEXITCODE
$ErrorActionPreference=$old
$mh=[regex]::Match($resolved,'(?im)^hostname\s+(\S+)\s*$')
$mu=[regex]::Match($resolved,'(?im)^user\s+(\S+)\s*$')
$resolvedHost=$(if($mh.Success){$mh.Groups[1].Value.Trim()}else{$null})
$resolvedUser=$(if($mu.Success){$mu.Groups[1].Value.Trim()}else{$null})
if($resolveExit -ne 0 -or $resolvedHost -ne '100.71.26.69' -or $resolvedUser -ne 'coolyo'){
  $r=[ordered]@{schema=1;requestId=$id;classification='HP_HERMES_CODEX_SSH_ALIAS_MISMATCH';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;executionIdentity=$currentName;sshAlias='hpenvy-restic';resolvedHost=$resolvedHost;resolvedUser=$resolvedUser;time=(Get-Date -Format o)}
  Write-State $r $statePath;Write-Output ($r|ConvertTo-Json -Compress);exit 48
}

$remote=@'
set -u
LAUNCHER="$HOME/.local/bin/hermes"
CONFIG="$HOME/.hermes/config.yaml"
AUTH="$HOME/.hermes/auth.json"
MODEL='gpt-5.6-luna'
PROVIDER='openai-codex'
CONTEXT='65536'

if [ "$(hostname 2>/dev/null || true)" != 'hpenvy' ] || [ "$(id -un 2>/dev/null || true)" != 'coolyo' ]; then echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_WRONG_TARGET'; exit 41; fi
if [ ! -x "$LAUNCHER" ] || [ ! -r "$CONFIG" ]; then echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_INSTALL_INCOMPLETE'; exit 42; fi
AUTH_VERIFIED="$(python3 - "$AUTH" <<'PY'
import json,sys
ok=False
try:
    with open(sys.argv[1],'r',encoding='utf-8') as f:d=json.load(f)
    p=(d.get('providers') or {}).get('openai-codex')
    t=p.get('tokens') if isinstance(p,dict) else None
    ok=isinstance(t,dict) and bool(t.get('access_token')) and bool(t.get('refresh_token'))
except Exception:pass
print('true' if ok else 'false')
PY
)"
printf 'AUTH_VERIFIED=%s\n' "$AUTH_VERIFIED"
if [ "$AUTH_VERIFIED" != true ]; then echo 'PROVIDER_SWITCHED=false'; echo 'GENERATION_STARTED=false'; echo 'GATEWAY_STARTED=false'; echo 'SECRET_VALUES_EMITTED=false'; echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_AUTH_NOT_VERIFIED'; exit 44; fi
if pgrep -af '[h]ermes.*gateway' >/dev/null 2>&1; then echo 'PROVIDER_SWITCHED=false'; echo 'GENERATION_STARTED=false'; echo 'GATEWAY_STARTED=false'; echo 'SECRET_VALUES_EMITTED=false'; echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_GATEWAY_ALREADY_RUNNING_SAFE_STOP'; exit 43; fi

read_model(){ awk '/^model:/{m=1;next} m&&/^[^[:space:]#]/{m=0} m&&/^[[:space:]]+default:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$CONFIG"; }
read_provider(){ awk '/^model:/{m=1;next} m&&/^[^[:space:]#]/{m=0} m&&/^[[:space:]]+provider:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$CONFIG"; }
read_context(){ awk '/^model:/{m=1;next} m&&/^[^[:space:]#]/{m=0} m&&/^[[:space:]]+context_length:/{sub(/^[^:]+:[[:space:]]*/,"");gsub(/[\"'\'' ]/,"");print;exit}' "$CONFIG"; }
read_base(){ awk '/^model:/{m=1;next} m&&/^[^[:space:]#]/{m=0} m&&/^[[:space:]]+base_url:/{print;exit}' "$CONFIG"; }

model="$(read_model)"; provider="$(read_provider)"; ctx="$(read_context)"; base="$(read_base)"
if [ "$provider" = "$PROVIDER" ] && [ "$model" = "$MODEL" ] && [ "$ctx" = "$CONTEXT" ] && [ -z "$base" ]; then
  printf 'MODEL=%s\nPROVIDER=%s\nCONTEXT_LENGTH=%s\nBASE_URL_PRESENT=false\n' "$model" "$provider" "$ctx"
  echo 'PROVIDER_SWITCHED=true'; echo 'GENERATION_STARTED=false'; echo 'GATEWAY_STARTED=false'; echo 'SECRET_VALUES_EMITTED=false'; echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_PRIMARY_CONFIGURED'; exit 0
fi

backup="$CONFIG.afz-pre-codex-$(date +%Y%m%dT%H%M%S).bak"
cp -p "$CONFIG" "$backup"
if ! "$LAUNCHER" config set model.default "$MODEL" >/dev/null 2>&1 || ! "$LAUNCHER" config set model.provider "$PROVIDER" >/dev/null 2>&1 || ! "$LAUNCHER" config set model.context_length "$CONTEXT" >/dev/null 2>&1; then
  cp -p "$backup" "$CONFIG"; echo 'PROVIDER_SWITCHED=false'; echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_CONFIG_SET_FAILED_ROLLED_BACK'; exit 45
fi
if ! "$LAUNCHER" config unset model.base_url >/dev/null 2>&1; then
python3 - "$CONFIG" <<'PY'
import sys,re
p=sys.argv[1]
lines=open(p,encoding='utf-8').readlines();out=[];m=False
for line in lines:
    if re.match(r'^model:\s*(?:#.*)?$',line):m=True;out.append(line);continue
    if m and re.match(r'^[^\s#][^:]*:',line):m=False
    if m and re.match(r'^\s+base_url\s*:',line):continue
    out.append(line)
open(p,'w',encoding='utf-8').writelines(out)
PY
fi
model="$(read_model)"; provider="$(read_provider)"; ctx="$(read_context)"; base="$(read_base)"
base_present=false; [ -n "$base" ] && base_present=true
printf 'MODEL=%s\nPROVIDER=%s\nCONTEXT_LENGTH=%s\nBASE_URL_PRESENT=%s\n' "$model" "$provider" "$ctx" "$base_present"
echo 'GENERATION_STARTED=false'; echo 'GATEWAY_STARTED=false'; echo 'SECRET_VALUES_EMITTED=false'
if [ "$provider" = "$PROVIDER" ] && [ "$model" = "$MODEL" ] && [ "$ctx" = "$CONTEXT" ] && [ "$base_present" = false ]; then
  echo 'PROVIDER_SWITCHED=true'; echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_PRIMARY_CONFIGURED'; exit 0
fi
cp -p "$backup" "$CONFIG"; echo 'PROVIDER_SWITCHED=false'; echo 'FINAL_CLASSIFICATION=HP_HERMES_CODEX_CONFIG_VERIFY_FAILED_ROLLED_BACK'; exit 46
'@

$sshArgs=@('-o','BatchMode=yes','-o','ConnectTimeout=15','-o','StrictHostKeyChecking=yes','hpenvy-restic','bash -s')
$old=$ErrorActionPreference;$ErrorActionPreference='Continue'
$raw=($remote | & $ssh @sshArgs 2>&1 | Out-String).Trim();$code=$LASTEXITCODE
$ErrorActionPreference=$old
$class=Marker $raw 'FINAL_CLASSIFICATION';$sshClass=SshClass $raw $code
if([string]::IsNullOrWhiteSpace($class)){$class=$(if($code -ne 0){$sshClass}else{'HP_HERMES_CODEX_UNKNOWN_RESULT'})}
$r=[ordered]@{
  schema=1;requestId=$id;taskName=$TaskName;target=$ExpectedTarget;provider=$ExpectedProvider;model=$ExpectedModel
  classification=$class
  authVerified=((Marker $raw 'AUTH_VERIFIED') -eq 'true')
  configuredProvider=(Marker $raw 'PROVIDER')
  configuredModel=(Marker $raw 'MODEL')
  contextLength=(Marker $raw 'CONTEXT_LENGTH')
  baseUrlPresent=((Marker $raw 'BASE_URL_PRESENT') -eq 'true')
  providerSwitched=((Marker $raw 'PROVIDER_SWITCHED') -eq 'true')
  generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false
  sshExitCode=$code;sshClassification=$sshClass;sshAlias='hpenvy-restic';executionIdentity=$currentName
  globalKnownHostsModified=$false;privateKeyCopied=$false;rawOutputPersistedInResult=$false
  githubControl=$true;oneDriveRole='observability-only';time=(Get-Date -Format o)
}
Write-State $r $statePath
Write-Output ($r|ConvertTo-Json -Depth 12 -Compress)
if($class -ne 'HP_HERMES_CODEX_PRIMARY_CONFIGURED'){exit 47}
exit 0