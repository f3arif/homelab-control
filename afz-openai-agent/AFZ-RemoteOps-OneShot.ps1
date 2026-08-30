#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$taskName='AFZ Remote Ops'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\remoteops-start'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-REMOTEOPS-START-LATEST.json'
$h3HookMirror=Join-Path $mirrorRoot 'H3-TAILSCALE-UNATTENDED-HOOK-LATEST.txt'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Write-Result($obj,[string]$path){
  $json=$obj | ConvertTo-Json -Depth 12
  $json | Set-Content -LiteralPath $path -Encoding UTF8
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){$json | Set-Content -LiteralPath $mirrorPath -Encoding UTF8}}catch{}
}
function Write-H3HookResult($obj){
  try{
    if(Test-Path -LiteralPath $mirrorRoot -PathType Container){
      ($obj | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $h3HookMirror -Encoding UTF8
    }
  }catch{}
}
function Invoke-Phase1FamilyPttPrep {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Phase1-Apk-Prepare.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-phase1-apk-prepare.json'
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf) -or -not(Test-Path -LiteralPath $request -PathType Leaf)){return}
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request *> $null}catch{}
}
function Invoke-H3TailscaleUnattended {
  # Typed, fixed-target one-shot. GitHub is the control input; OneDrive is result-only.
  # The helper can only enforce H3's Tailscale UnattendedMode=always and verify it.
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Enable-H3-Tailscale-Unattended.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-tailscale-unattended.json'
  $helperExists=Test-Path -LiteralPath $helper -PathType Leaf
  $requestExists=Test-Path -LiteralPath $request -PathType Leaf
  if(-not $helperExists -or -not $requestExists){
    Write-H3HookResult ([ordered]@{schema=1;status='not-invoked';helperExists=$helperExists;requestExists=$requestExists;helper=$helper;request=$request;time=(Get-Date -Format o)})
    return
  }
  try{
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request 2>&1 | Out-String).Trim()
    $code=$LASTEXITCODE
    Write-H3HookResult ([ordered]@{schema=1;status=$(if($code -eq 0){'completed'}else{'failed'});exitCode=$code;helperExists=$true;requestExists=$true;output=$raw;time=(Get-Date -Format o)})
  }catch{
    Write-H3HookResult ([ordered]@{schema=1;status='exception';exitCode=$LASTEXITCODE;helperExists=$true;requestExists=$true;error=$_.Exception.Message;detail=($_ | Out-String).Trim();time=(Get-Date -Format o)})
  }
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
$requestedTask=([string]$req.taskName).Trim()
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}
if($requestedTask -ne $taskName){throw "Unsupported task name: $requestedTask"}

# First-stage typed auxiliary requests are idempotent and isolated from RemoteOps.
# A failure here must never prevent the existing RemoteOps recovery path.
Invoke-H3TailscaleUnattended

# The Phase 1 FamilyPTT prep is a separate typed, idempotent request. It is invoked
# here only because this helper already runs at the first AFZ-agent startup stage.
# Its request status controls activation and it cannot mutate network/backend state.
Invoke-Phase1FamilyPttPrep

$statePath=Join-Path $stateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$existing.classification -eq 'REMOTEOPS_TASK_RUNNING'){
      Write-Result $existing $statePath
      Write-Output ($existing | ConvertTo-Json -Depth 12 -Compress)
      exit 0
    }
  }catch{}
}

$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $task){
  $r=[ordered]@{schema=1;requestId=$id;taskName=$taskName;classification='REMOTEOPS_TASK_MISSING';time=(Get-Date -Format o)}
  Write-Result $r $statePath
  Write-Output ($r|ConvertTo-Json -Compress)
  exit 20
}

$before=[string]$task.State
$startAttempted=$false
if($before -ne 'Running'){
  Start-ScheduledTask -TaskName $taskName
  $startAttempted=$true
  Start-Sleep -Seconds 3
}
$afterTask=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$after=[string]$afterTask.State
$info=$null
try{$info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop}catch{}
$class=$(if($after -eq 'Running'){'REMOTEOPS_TASK_RUNNING'}else{'REMOTEOPS_TASK_START_NOT_RUNNING'})
$r=[ordered]@{
  schema=1
  requestId=$id
  taskName=$taskName
  classification=$class
  startAttempted=$startAttempted
  stateBefore=$before
  stateAfter=$after
  lastRunTime=$(if($info){$info.LastRunTime}else{$null})
  lastTaskResult=$(if($info){$info.LastTaskResult}else{$null})
  nextRunTime=$(if($info){$info.NextRunTime}else{$null})
  time=(Get-Date -Format o)
}
Write-Result $r $statePath
Write-Output ($r | ConvertTo-Json -Depth 12 -Compress)
if($class -ne 'REMOTEOPS_TASK_RUNNING'){exit 21}
