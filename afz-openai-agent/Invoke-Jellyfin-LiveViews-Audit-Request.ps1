#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\jellyfin-liveviews-audit.json'
$helper=Join-Path $InstallRoot 'afz-openai-agent\tools\Jellyfin-Temporary-ApiKey-Decoded-Audit.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\jellyfin-liveviews-audit'
$stateFile=Join-Path $stateRoot 'latest.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'JELLYFIN-API-DECODED-STATE-AUDIT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Write-Json([string]$p,$o){[IO.File]::WriteAllText($p,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'Invalid Jellyfin liveviews audit request JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'jellyfin-liveviews-audit' -or [string]$req.action -ne 'audit-decoded-api-live-views-readonly'){throw 'Invalid Jellyfin liveviews audit request'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid Jellyfin liveviews audit job_id'}
$prior=Read-Json $stateFile
if($prior -and [string]$prior.job_id -eq $job -and [string]$prior.status -in @('completed','failed')){exit 0}
if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Jellyfin temporary-key decoded audit helper missing: $helper"}
$started=Get-Date
try{
  $lines=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper 2>&1 | ForEach-Object {[string]$_})
  $code=$LASTEXITCODE
  $status=if($code -eq 0){'completed'}else{'failed'}
  $out=[ordered]@{schema=1;controlPlane='github';source='windows-main-local-github-request';job_id=$job;status=$status;readOnly=$true;temporaryCredential=$true;secretExposed=$false;helperExit=$code;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)}
  Write-Json $stateFile $out
  if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllLines($diagFile,@('PURPOSE=EMERGENCY_DIAGNOSTIC_ACK_ONLY','CONTROL_PLANE=github',('JOB_ID='+$job),('STATUS='+$status),'READ_ONLY=true','TEMPORARY_CREDENTIAL=true','SECRET_EXPOSED=false',('HELPER_EXIT='+$code))+$lines+@('MIRRORED_AT='+(Get-Date -Format o)),$utf8)}
  if($code -ne 0){exit $code};exit 0
}catch{
  $out=[ordered]@{schema=1;controlPlane='github';source='windows-main-local-github-request';job_id=$job;status='failed';readOnly=$true;temporaryCredential=$true;secretExposed=$false;error=$_.Exception.Message;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)}
  Write-Json $stateFile $out
  if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllLines($diagFile,@('PURPOSE=EMERGENCY_DIAGNOSTIC_ACK_ONLY','CONTROL_PLANE=github',('JOB_ID='+$job),'STATUS=failed','READ_ONLY=true','TEMPORARY_CREDENTIAL=true','SECRET_EXPOSED=false',('ERROR='+$_.Exception.Message),('MIRRORED_AT='+(Get-Date -Format o))),$utf8)}
  exit 1
}
