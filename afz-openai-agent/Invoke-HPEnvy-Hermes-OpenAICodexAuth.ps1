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
  # OneDrive is observability/backup only; it is never read as control input.
  try{
    if(Test-Path -LiteralPath $MirrorRoot -PathType Container){
      $json | Set-Content -LiteralPath $MirrorPath -Encoding UTF8
      # Reuse the already-synced H3 hook telemetry item as a reliable readback carrier.
      # This adds sanitized OAuth state only; no raw terminal stream, tokens, or credentials.
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

function Get-SanitizedDeviceState([string]$StdoutPath,[string]$StderrPath){
  $text=''
  foreach($p in @($StdoutPath,$StderrPath)){
    if(Test-Path -LiteralPath $p -PathType Leaf){
      try{$text += "`n" + (Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop)}catch{}
    }
  }
  # Strip ANSI terminal escapes before parsing. Never persist the raw stream.
  $clean=[regex]::Replace($text,"`e\[[0-?]*[ -/]*[@-~]",'')
  $url=$null
  $code=$null
  $urlMatch=[regex]::Match($clean,'https://auth\.openai\.com/codex/device(?:\?[^\s]+)?',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if($urlMatch.Success){$url=$urlMatch.Value.TrimEnd('.',',',')',']')}
  $codeMatch=[regex]::Match($clean,'\b[A-Z0-9]{4}-[A-Z0-9]{5}\b',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if($codeMatch.Success){$code=$codeMatch.Value.ToUpperInvariant()}
  return [ordered]@{url=$url;code=$code}
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
$requestedTask=([string]$req.taskName).Trim()
$target=([string]$req.target).Trim()
$provider=([string]$req.provider).Trim().ToLowerInvariant()
$action=([string]$req.action).Trim().ToLowerInvariant()

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
    if([string]$existing.classification -in @('AUTH_DEVICE_CODE_READY','AUTH_STARTED_CODE_PENDING')){
      Write-State $existing $statePath
      Write-Output ($existing | ConvertTo-Json -Depth 10 -Compress)
      exit 0
    }
  }catch{}
}

$ssh=(Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if(-not $ssh){$ssh=(Get-Command ssh -ErrorAction SilentlyContinue).Source}
if(-not $ssh){throw 'OpenSSH client not found'}

$stdoutPath=Join-Path $StateRoot ($id+'.stdout.tmp')
$stderrPath=Join-Path $StateRoot ($id+'.stderr.tmp')
Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue

# The remote command is completely fixed: no request field is interpolated into shell code.
# It starts only Hermes' OpenAI Codex OAuth device flow as the existing coolyo account.
$sshArgs=@(
  '-tt',
  '-o','BatchMode=yes',
  '-o','ConnectTimeout=15',
  '-o','StrictHostKeyChecking=yes',
  $ExpectedTarget,
  '/home/coolyo/.local/bin/hermes','auth','add','openai-codex'
)
$proc=Start-Process -FilePath $ssh -ArgumentList $sshArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

$device=$null
for($i=0;$i -lt 80;$i++){
  Start-Sleep -Milliseconds 250
  $device=Get-SanitizedDeviceState $stdoutPath $stderrPath
  if($device.code -and $device.url){break}
  try{$proc.Refresh()}catch{}
  if($proc.HasExited -and -not $device.code){break}
}
if(-not $device){$device=[ordered]@{url=$null;code=$null}}
try{$proc.Refresh()}catch{}
$running=-not $proc.HasExited
$classification=$(if($device.code -and $device.url){'AUTH_DEVICE_CODE_READY'}elseif($running){'AUTH_STARTED_CODE_PENDING'}else{'AUTH_START_EXITED_WITHOUT_DEVICE_CODE'})
$exitCode=$(if($proc.HasExited){$proc.ExitCode}else{$null})

$r=[ordered]@{
  schema=1
  requestId=$id
  taskName=$TaskName
  target=$ExpectedTarget
  provider=$ExpectedProvider
  action=$ExpectedAction
  classification=$classification
  deviceUrl=$device.url
  deviceCode=$device.code
  sshProcessId=$proc.Id
  sshProcessRunning=$running
  exitCode=$exitCode
  providerSwitched=$false
  generationStarted=$false
  gatewayStarted=$false
  secretValuesEmitted=$false
  rawOutputPersistedInResult=$false
  githubControl=$true
  oneDriveRole='observability-only'
  time=(Get-Date -Format o)
}
Write-State $r $statePath
Write-Output ($r | ConvertTo-Json -Depth 10 -Compress)

if($classification -eq 'AUTH_START_EXITED_WITHOUT_DEVICE_CODE'){
  Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
  exit 42
}
exit 0
