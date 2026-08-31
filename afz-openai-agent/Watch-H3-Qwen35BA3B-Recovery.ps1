#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$RetryDelaySeconds=60
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$RetryDelaySeconds=[math]::Max(30,[math]::Min($RetryDelaySeconds,300))
$jobId='qwen35b-a3b-website-20260830-r1'
$recovery=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-TransportRecovery.ps1'
$recoveryState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-transport-recovery\latest.json'
$watchRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-recovery-watch'
$watchState=Join-Path $watchRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirror=Join-Path $mirrorRoot 'AFZ-QWEN35B-RECOVERY-WATCH-LATEST.txt'
$piWakeUri='http://100.91.50.9:8087/wake/h3'
$piStatusUri='http://100.91.50.9:8087/status/h3'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $watchRoot|Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Save-Watch([string]$Status,[string]$Message,$RecoveryState=$null,[int]$Attempt=0,$Wake=$null){
  $o=[ordered]@{
    schema=1
    status=$Status
    message=$Message
    jobId=$jobId
    maxModelCalls=1
    modelCallIssuedByWatch=$false
    attempt=$Attempt
    retryDelaySeconds=$RetryDelaySeconds
    piWake=$Wake
    recoveryState=$RecoveryState
    time=(Get-Date -Format o)
  }
  $json=$o|ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($watchState,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirror,$json,$utf8)}}catch{}
}
function Is-ProtectedCompletion($State){
  if(-not $State){return $false}
  if([string]$State.status -ne 'completed'){return $false}
  $c=[string]$State.classification
  return ($c -in @(
    'QWEN35B_EXISTING_MODEL_CALL_PROTECTED',
    'QWEN35B_SINGLE_GUARDED_MODEL_CALL_STARTED',
    'QWEN35B_EXISTING_GUARDED_STATE_RETURNED',
    'QWEN35B_GUARDED_LAUNCHER_RETURNED'
  ))
}
function Request-PiWake {
  $o=[ordered]@{attempted=$true;status=$null;wake=$null;error=$null}
  try{$o.status=[string](Invoke-WebRequest -Uri $piStatusUri -UseBasicParsing -TimeoutSec 6).Content}catch{}
  try{$o.wake=[string](Invoke-WebRequest -Uri $piWakeUri -UseBasicParsing -TimeoutSec 8).Content}catch{$o.error=$_.Exception.Message}
  return [pscustomobject]$o
}

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "windows-main-only watch; host=$env:COMPUTERNAME"}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if([string]$identity.User.Value -ne 'S-1-5-18'){throw "35B recovery watch must run as SYSTEM; identity=$([string]$identity.Name)"}
if(-not(Test-Path -LiteralPath $recovery -PathType Leaf)){throw "35B recovery helper missing: $recovery"}

$mutex=New-Object Threading.Mutex($false,'Global\AFZQwen35BA3BRecoveryWatch')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  $attempt=0
  while($true){
    $attempt++
    $state=Read-Json $recoveryState
    if(Is-ProtectedCompletion $state){
      Save-Watch 'completed' 'Guarded 35B launch/protected state already proven; recovery watch is exiting.' $state $attempt
      exit 0
    }

    $wake=Request-PiWake
    Save-Watch 'running' 'Requested Pi wake fallback, then starting bounded SYSTEM transport recovery; the watch itself cannot issue a model call.' $state $attempt $wake
    $raw=''
    $code=0
    try{
      $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $recovery -InstallRoot $InstallRoot 2>&1|Out-String)
      $code=$LASTEXITCODE
    }catch{
      $raw=$_.Exception.Message
      $code=99
    }

    $state=Read-Json $recoveryState
    if(Is-ProtectedCompletion $state){
      Save-Watch 'completed' 'SYSTEM recovery reached guarded launch/protected state; no further retries will occur.' $state $attempt $wake
      exit 0
    }

    Save-Watch 'waiting' ("Recovery attempt remained pre-model or unreachable; retrying after ${RetryDelaySeconds}s. exit=$code") $state $attempt $wake
    Start-Sleep -Seconds $RetryDelaySeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
