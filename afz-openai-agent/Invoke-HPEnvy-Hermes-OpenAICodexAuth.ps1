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
$ExpectedAction='start-device-auth'
$TaskName='HP Envy Hermes OpenAI Codex Auth'
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-hermes-openai-codex-auth'
$MirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$MirrorPath=Join-Path $MirrorRoot 'HPENVY-HERMES-OPENAI-CODEX-AUTH-LATEST.txt'
$ExistingHookMirror=Join-Path $MirrorRoot 'H3-TAILSCALE-UNATTENDED-HOOK-LATEST.txt'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

function Write-State([object]$Object,[string]$Path){
  $json=$Object | ConvertTo-Json -Depth 10
  $json | Set-Content -LiteralPath $Path -Encoding UTF8
  try{
    if(Test-Path -LiteralPath $MirrorRoot -PathType Container){
      $json | Set-Content -LiteralPath $MirrorPath -Encoding UTF8
      $carrier=[ordered]@{schema=1;component='AFZ startup hooks';hermesOAuth=$Object;time=(Get-Date -Format o)}
      try{
        if(Test-Path -LiteralPath $ExistingHookMirror -PathType Leaf){
          $existing=Get-Content -LiteralPath $ExistingHookMirror -Raw -Encoding UTF8 | ConvertFrom-Json
          $carrier=[ordered]@{schema=1;h3=$existing;hermesOAuth=$Object;time=(Get-Date -Format o)}
        }
      }catch{}
      ($carrier | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $ExistingHookMirror -Encoding UTF8
    }
  }catch{}
}

function Parse-Device([string]$Text){
  $clean=[regex]::Replace([string]$Text,"`e\[[0-?]*[ -/]*[@-~]",'')
  $url=$null;$code=$null;$remotePidValue=$null;$log=$null
  $m=[regex]::Match($clean,'https://auth\.openai\.com/codex/device(?:\?[^\s]+)?',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if($m.Success){$url=$m.Value.TrimEnd('.',',',')',']')}
  $m=[regex]::Match($clean,'\b[A-Z0-9]{4}-[A-Z0-9]{5}\b',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if($m.Success){$code=$m.Value.ToUpperInvariant()}
  $m=[regex]::Match($clean,'(?m)^AFZ_OAUTH_PID=(\d+)$');if($m.Success){$remotePidValue=[int]$m.Groups[1].Value}
  $m=[regex]::Match($clean,'(?m)^AFZ_OAUTH_LOG=([^\r\n]+)$');if($m.Success){$log=$m.Groups[1].Value.Trim()}
  return [ordered]@{url=$url;code=$code;remotePid=$remotePidValue;remoteLog=$log}
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

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim();$requestedTask=([string]$req.taskName).Trim();$target=([string]$req.target).Trim()
$provider=([string]$req.provider).Trim().ToLowerInvariant();$action=([string]$req.action).Trim().ToLowerInvariant()
if([int]$req.schema -ne 1){throw 'Unsupported request schema'}
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}
if($requestedTask -ne $TaskName){throw "Unsupported task name: $requestedTask"}
if($target -ne $ExpectedTarget){throw "Target mismatch: $target"}
if($provider -ne $ExpectedProvider){throw "Provider mismatch: $provider"}
if($action -ne $ExpectedAction){throw "Unsupported action: $action"}
if([bool]$req.allow_provider_switch){throw 'Provider switching is forbidden during device auth'}
if([bool]$req.allow_generation){throw 'Model generation is forbidden during device auth'}

$statePath=Join-Path $StateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$existing.classification -eq 'AUTH_DEVICE_CODE_READY'){
      Write-State $existing $statePath
      Write-Output ($existing|ConvertTo-Json -Depth 10 -Compress)
      exit 0
    }
  }catch{}
}

$ssh=(Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if(-not $ssh){$ssh=(Get-Command ssh -ErrorAction SilentlyContinue).Source}
if(-not $ssh){throw 'OpenSSH client not found'}

$remoteScript=@'
set -eu
root="$HOME/.hermes/afz-openai-oauth"
mkdir -p "$root"
pkill -f '/home/coolyo/.local/bin/hermes auth add openai-codex' >/dev/null 2>&1 || true
ts=$(date -u +%Y%m%dT%H%M%SZ)
log="$root/login-$ts.log"
nohup script -qefc '/home/coolyo/.local/bin/hermes auth add openai-codex' "$log" >/dev/null 2>&1 </dev/null &
pid=$!
printf 'AFZ_OAUTH_PID=%s\n' "$pid"
printf 'AFZ_OAUTH_LOG=%s\n' "$log"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 0.5
  if grep -q 'auth.openai.com/codex/device' "$log" 2>/dev/null; then break; fi
done
cat "$log" 2>/dev/null || true
'@
$sshArgs=@('-o','BatchMode=yes','-o','ConnectTimeout=15','-o','StrictHostKeyChecking=yes',$ExpectedTarget,'bash -s')
$old=$ErrorActionPreference;$ErrorActionPreference='Continue'
$raw=($remoteScript | & $ssh @sshArgs 2>&1 | Out-String).Trim()
$sshExit=$LASTEXITCODE
$ErrorActionPreference=$old
$device=Parse-Device $raw
$transportClass=Classify-SshFailure $raw $sshExit
$classification=$(if($device.code -and $device.url){'AUTH_DEVICE_CODE_READY'}elseif($sshExit -ne 0){$transportClass}else{'AUTH_DEVICE_CODE_NOT_EMITTED'})
$r=[ordered]@{
  schema=1;requestId=$id;taskName=$TaskName;target=$ExpectedTarget;provider=$ExpectedProvider;action=$ExpectedAction
  classification=$classification;deviceUrl=$device.url;deviceCode=$device.code;remoteOauthPid=$device.remotePid;remoteOauthLog=$device.remoteLog
  sshExitCode=$sshExit;sshClassification=$transportClass;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false
  rawOutputPersistedInResult=$false;githubControl=$true;oneDriveRole='observability-only';time=(Get-Date -Format o)
}
Write-State $r $statePath
Write-Output ($r|ConvertTo-Json -Depth 10 -Compress)
if($classification -ne 'AUTH_DEVICE_CODE_READY'){exit 42}
exit 0
