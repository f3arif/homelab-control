#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\jellyfin-userstore-audit.json'
$helper=Join-Path $InstallRoot 'afz-openai-agent\tools\Jellyfin-VirtualFolders-LiveAudit.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\jellyfin-userstore-audit'
$stateFile=Join-Path $stateRoot 'latest.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'JELLYFIN-VIRTUALFOLDERS-LIVE-AUDIT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Read-Json([string]$p){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Write-Json([string]$p,$o){[IO.File]::WriteAllText($p,($o|ConvertTo-Json -Depth 20 -Compress),$utf8)}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'Invalid Jellyfin userstore audit request JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'jellyfin-userstore-audit' -or [string]$req.action -ne 'audit-live-userstore-readonly'){throw 'Invalid Jellyfin userstore audit request schema/project/action'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid Jellyfin userstore audit job_id'}
$prior=Read-Json $stateFile
if($prior -and [string]$prior.job_id -eq $job -and [string]$prior.status -in @('completed','failed')){exit 0}
if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Jellyfin virtual-folder audit helper missing: $helper"}
$started=Get-Date
try{
  $lines=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper 2>&1 | ForEach-Object {[string]$_})
  $code=$LASTEXITCODE
  $status=if($code -eq 0){'completed'}else{'failed'}
  $out=[ordered]@{schema=1;controlPlane='github';source='windows-main-local-github-request';job_id=$job;status=$status;readOnly=$true;secretExposed=$false;helperExit=$code;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)}
  Write-Json $stateFile $out
  if(Test-Path -LiteralPath $diagRoot -PathType Container){
    $proof=@('PURPOSE=EMERGENCY_DIAGNOSTIC_ACK_ONLY','CONTROL_PLANE=github',('JOB_ID='+$job),('STATUS='+$status),'READ_ONLY=true','SECRET_EXPOSED=false',('HELPER_EXIT='+$code))+$lines+@('MIRRORED_AT='+(Get-Date -Format o))
    [IO.File]::WriteAllLines($diagFile,$proof,$utf8)
  }
  if($code -ne 0){exit $code};exit 0
}catch{
  $out=[ordered]@{schema=1;controlPlane='github';source='windows-main-local-github-request';job_id=$job;status='failed';readOnly=$true;secretExposed=$false;error=$_.Exception.Message;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)}
  Write-Json $stateFile $out
  if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllLines($diagFile,@('PURPOSE=EMERGENCY_DIAGNOSTIC_ACK_ONLY','CONTROL_PLANE=github',('JOB_ID='+$job),'STATUS=failed','READ_ONLY=true','SECRET_EXPOSED=false',('ERROR='+$_.Exception.Message),('MIRRORED_AT='+(Get-Date -Format o))),$utf8)}
  exit 1
}
