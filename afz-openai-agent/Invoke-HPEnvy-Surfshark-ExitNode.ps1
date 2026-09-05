#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$ExpectedTarget='coolyo@100.71.26.69'
$TaskName='HP Envy Surfshark Exit Node'
$StateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hpenvy-surfshark-exitnode'
$MirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$MirrorPath=Join-Path $MirrorRoot 'HPENVY-SURFSHARK-EXITNODE-LATEST.json'
$LocalAuthorizationSentinel='C:\ProgramData\AFZ\Authorizations\hpenvy-surfshark-route.approved'
$RemoteScript=Join-Path $InstallRoot 'afz-openai-agent\remoteops\hpenvy-surfshark-exitnode.sh'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

function Write-State([object]$Object,[string]$Path){
  $json=$Object | ConvertTo-Json -Depth 12
  $json | Set-Content -LiteralPath $Path -Encoding UTF8
  # OneDrive is backup-only. Mirror failure must never change execution status.
  try{
    if(Test-Path -LiteralPath $MirrorRoot -PathType Container){
      $json | Set-Content -LiteralPath $MirrorPath -Encoding UTF8
    }
  }catch{}
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
if(-not(Test-Path -LiteralPath $RemoteScript -PathType Leaf)){throw "Remote script missing: $RemoteScript"}

$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
$requestedTask=([string]$req.taskName).Trim()
$target=([string]$req.target).Trim()
$mode=([string]$req.mode).Trim().ToLowerInvariant()

if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}
if($requestedTask -ne $TaskName){throw "Unsupported task name: $requestedTask"}
if($target -ne $ExpectedTarget){throw "Target mismatch: $target"}
if($mode -notin @('audit','apply')){throw "Unsupported mode: $mode"}

$statePath=Join-Path $StateRoot ($id+'.json')
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$existing.classification -match '^(AUDIT_|APPLY_)'){
      Write-State $existing $statePath
      Write-Output ($existing | ConvertTo-Json -Depth 12 -Compress)
      exit $(if([int]$existing.exitCode -eq 0){0}else{[int]$existing.exitCode})
    }
  }catch{}
}

if($mode -eq 'apply' -and -not(Test-Path -LiteralPath $LocalAuthorizationSentinel -PathType Leaf)){
  $denied=[ordered]@{
    schema=1
    requestId=$id
    taskName=$TaskName
    target=$target
    mode=$mode
    classification='APPLY_DENIED_LOCAL_AUTHORIZATION_REQUIRED'
    exitCode=41
    githubControl=$true
    oneDriveRole='backup-only'
    time=(Get-Date -Format o)
  }
  Write-State $denied $statePath
  Write-Output ($denied | ConvertTo-Json -Depth 12 -Compress)
  exit 41
}

$ssh=(Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if(-not $ssh){$ssh=(Get-Command ssh -ErrorAction SilentlyContinue).Source}
if(-not $ssh){throw 'OpenSSH client not found'}

$scriptText=Get-Content -LiteralPath $RemoteScript -Raw -Encoding UTF8
$remoteCommand=$(if($mode -eq 'apply'){'AFZ_CHANGE_AUTHORIZED=1 bash -s -- apply'}else{'bash -s -- audit'})
$sshArgs=@(
  '-o','BatchMode=yes',
  '-o','ConnectTimeout=15',
  '-o','StrictHostKeyChecking=yes',
  $target,
  $remoteCommand
)

$oldEap=$ErrorActionPreference
$ErrorActionPreference='Continue'
$raw=($scriptText | & $ssh @sshArgs 2>&1 | Out-String).Trim()
$exitCode=$LASTEXITCODE
$ErrorActionPreference=$oldEap

$resultLine=($raw -split "`r?`n" | Where-Object {$_ -match '^RESULT='} | Select-Object -Last 1)
$resultValue=$(if($resultLine){($resultLine -replace '^RESULT=','').Trim()}else{'NO_RESULT_MARKER'})
$classification=$(if($mode -eq 'audit'){"AUDIT_$resultValue"}else{"APPLY_$resultValue"})

$r=[ordered]@{
  schema=1
  requestId=$id
  taskName=$TaskName
  target=$target
  mode=$mode
  classification=$classification
  exitCode=$exitCode
  githubControl=$true
  oneDriveRole='backup-only'
  output=$raw
  time=(Get-Date -Format o)
}
Write-State $r $statePath
Write-Output ($r | ConvertTo-Json -Depth 12 -Compress)
if($exitCode -ne 0){exit $exitCode}
