#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$liveViewsRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Jellyfin-LiveViews-Audit-Request.ps1'
if(Test-Path -LiteralPath $liveViewsRunner -PathType Leaf){
  try{
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $liveViewsRunner -InstallRoot $InstallRoot *> $null
  }catch{}
}
$userStoreRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Jellyfin-UserStore-Audit-Request.ps1'
if(Test-Path -LiteralPath $userStoreRunner -PathType Leaf){
  try{
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $userStoreRunner -InstallRoot $InstallRoot *> $null
  }catch{}
}
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\jellyfin-visibility-repair.json'
$helper=Join-Path $InstallRoot 'afz-openai-agent\tools\Jellyfin-Visibility-Repair.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\jellyfin-visibility-request'
$stateFile=Join-Path $stateRoot 'latest.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'JELLYFIN-VISIBILITY-REPAIR-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Write-Json([string]$p,$o){[IO.File]::WriteAllText($p,($o|ConvertTo-Json -Depth 40 -Compress),$utf8)}
function Publish-Diagnostic($o){try{if(Test-Path -LiteralPath $diagRoot -PathType Container){Write-Json $diagFile $o}}catch{}}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'Invalid Jellyfin visibility request JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'jellyfin-visibility' -or [string]$req.action -ne 'repair-exact-screenshot-user'){throw 'Invalid Jellyfin visibility request schema/project/action'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid Jellyfin visibility request job_id'}
$prior=Read-Json $stateFile
if($prior -and [string]$prior.job_id -eq $job -and [string]$prior.status -in @('completed','safe-stop','failed')){exit 0}
if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Jellyfin visibility helper missing: $helper"}
$started=Get-Date
try{
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Action repair 2>&1|Out-String).Trim()
  $code=$LASTEXITCODE
  if($code -ne 0){throw "Jellyfin helper exit=$code"}
  $result=$raw|ConvertFrom-Json
  $status=$(if([bool]$result.ok){'completed'}elseif([string]$result.status -eq 'SAFE_STOP'){'safe-stop'}else{'failed'})
  $out=[ordered]@{
    schema=1
    purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
    controlPlane='github'
    source='windows-main-local-github-request'
    job_id=$job
    status=$status
    requestAction=[string]$req.action
    result=$result
    secretExposed=$false
    startedAt=$started.ToString('o')
    finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $out
  Publish-Diagnostic $out
  $out|ConvertTo-Json -Depth 40 -Compress|Write-Output
  exit 0
}catch{
  $out=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main-local-github-request';job_id=$job;status='failed';requestAction=[string]$req.action;error=$_.Exception.Message;secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)}
  Write-Json $stateFile $out;Publish-Diagnostic $out;$out|ConvertTo-Json -Depth 20 -Compress|Write-Output;exit 1
}
