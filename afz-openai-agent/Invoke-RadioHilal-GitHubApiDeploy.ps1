#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\radiohilal-api-deploy.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\radiohilal-api-deploy'
$stateFile=Join-Path $stateRoot 'latest.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagFile=Join-Path $diagRoot 'AFZ-RadioHilal-ApiDeploy-Latest.json'
$repo='C:\AFZ\RadioHilalGit'
$opsWorktree='C:\AFZ\RadioHilalGit-ops'
$bridgeTask='RadioHilal-GitHub-Bridge'
$serviceName='RadioHilal.Api'
$healthUrl='http://127.0.0.1:5149/api/system/health'
$livePub='C:\Projects\RadioHilal\Publish\Api'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 20 -Compress),$utf8)
}
function Publish-Diagnostic($Object){
  # Backup-only result mirror. Never consumed as request/control input.
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){Write-Json $diagFile $Object}
  }catch{}
}
function Save-Result([string]$Job,[string]$Status,[string]$Classification,[bool]$Retryable,[hashtable]$Extra){
  $o=[ordered]@{
    schema=1;controlPlane='github';source='windows-main-direct-fixed-request';project='radiohilal'
    job_id=$Job;status=$Status;classification=$Classification;retryable=$Retryable
    host=$expectedComputer;secretExposed=$false;oneDriveRole='backup-only-result-mirror';time=(Get-Date -Format o)
  }
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  Write-Json $stateFile $o;Publish-Diagnostic $o
  $o | ConvertTo-Json -Depth 20 -Compress | Write-Output
  return $o
}
function Test-Admin {
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $principal=New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-RadioHilalHealth {
  $h=Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 10
  if($null -eq $h){throw 'HEALTH_EMPTY'}
  if([string]$h.api -ne 'Healthy'){throw "API_HEALTH_$($h.api)"}
  if([string]$h.library -ne 'Healthy'){throw "LIBRARY_HEALTH_$($h.library)"}
  return $h
}
function Wait-RadioHilalHealth([int]$Seconds=60){
  $deadline=(Get-Date).AddSeconds($Seconds);$last=''
  do{
    try{return Get-RadioHilalHealth}catch{$last=$_.Exception.Message;Start-Sleep -Seconds 2}
  }while((Get-Date) -lt $deadline)
  throw "HEALTH_TIMEOUT last=$last"
}
function Wait-TaskIdle([string]$TaskName,[int]$Seconds=240){
  $deadline=(Get-Date).AddSeconds($Seconds)
  do{
    $t=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if(-not $t){throw "BRIDGE_TASK_MISSING $TaskName"}
    if([string]$t.State -ne 'Running'){return}
    Start-Sleep -Seconds 2
  }while((Get-Date) -lt $deadline)
  throw "BRIDGE_TASK_TIMEOUT $TaskName"
}
function Invoke-BridgeOnce {
  Wait-TaskIdle $bridgeTask 240
  Start-ScheduledTask -TaskName $bridgeTask -ErrorAction Stop
  Wait-TaskIdle $bridgeTask 240
}

if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if(-not(Test-Admin)){throw 'ELEVATED_SYSTEM_OR_ADMIN_REQUIRED'}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'INVALID_REQUEST_JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'radiohilal' -or [string]$req.action -ne 'deploy-github-api-exact'){throw 'INVALID_REQUEST_SCHEMA_PROJECT_ACTION'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
if([string]$req.repository -ne 'f3arif/RadioHilal'){throw 'INVALID_REPOSITORY'}
if(-not [bool]$req.rollback_on_failure -or [bool]$req.allow_config_overwrite -or [bool]$req.allow_database_mutation){throw 'INVALID_SAFETY_FLAGS'}
$job=[string]$req.job_id
$expected=([string]$req.expected_main_commit).Trim().ToLowerInvariant()
$validationJobId=([string]$req.validation_job_id).Trim()
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'INVALID_JOB_ID'}
if($expected -notmatch '^[0-9a-f]{40}$'){throw 'INVALID_EXPECTED_MAIN_COMMIT'}
if($validationJobId -notmatch '^[A-Za-z0-9._-]{8,160}$'){throw 'INVALID_VALIDATION_JOB_ID'}

$prior=Read-Json $stateFile
if($prior -and [string]$prior.job_id -eq $job){
  if([string]$prior.status -eq 'completed' -or ([string]$prior.status -eq 'failed' -and -not [bool]$prior.retryable)){
    $prior | ConvertTo-Json -Depth 20 -Compress | Write-Output
    exit 0
  }
}

$started=Get-Date
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$short=$expected.Substring(0,8)
$stageRoot="C:\AFZ\RemoteOps\staging\radiohilal-direct-$short-$stamp"
$worktree=Join-Path $stageRoot 'source'
$candidate=Join-Path $stageRoot 'publish'
$backup="C:\AFZ\RemoteOps\backups\radiohilal-direct-$short-$stamp"
$backupPub=Join-Path $backup 'Publish-Api'
$worktreeAdded=$false
$liveMutationStarted=$false

try{
  if(-not(Test-Path -LiteralPath (Join-Path $repo '.git'))){throw 'RADIOHILAL_GIT_CHECKOUT_MISSING'}
  if(-not(Test-Path -LiteralPath $livePub -PathType Container)){throw 'LIVE_PUBLISH_MISSING'}

  # The scheduled bridge runs as the installed user and owns private-repo Git authentication.
  # Its first action is a guarded pull of origin/main; the lexically-first queued job is the
  # exact BuildApi validation requested here.
  $validationLocal=Join-Path $opsWorktree ("github-ops\results\$validationJobId.json")
  if(-not(Test-Path -LiteralPath $validationLocal -PathType Leaf)){
    Invoke-BridgeOnce
  }
  if(-not(Test-Path -LiteralPath $validationLocal -PathType Leaf)){
    Save-Result $job 'safe-stop' 'RADIOHILAL_BUILD_VALIDATION_PENDING' $true @{expectedMainCommit=$expected;validationJobId=$validationJobId;startedAt=$started.ToString('o')} | Out-Null
    exit 0
  }
  $validation=Read-Json $validationLocal
  if(-not $validation){throw 'BUILD_VALIDATION_JSON_INVALID'}
  if([string]$validation.Action -ne 'BuildApi' -or [string]$validation.Status -ne 'Succeeded' -or [int]$validation.ExitCode -ne 0){throw "BUILD_VALIDATION_NOT_SUCCESS status=$($validation.Status) exit=$($validation.ExitCode)"}
  if((([string]$validation.ExpectedMainCommit).Trim().ToLowerInvariant()) -ne $expected){throw 'BUILD_VALIDATION_COMMIT_MISMATCH'}
  if((([string]$validation.JobId).Trim()) -ne $validationJobId){throw 'BUILD_VALIDATION_JOB_MISMATCH'}

  $localHead=(& git -C $repo rev-parse HEAD 2>&1 | Out-String).Trim().ToLowerInvariant()
  if($LASTEXITCODE -ne 0 -or $localHead -notmatch '^[0-9a-f]{40}$'){throw "LOCAL_HEAD_UNRESOLVED $localHead"}
  if($localHead -ne $expected){
    Save-Result $job 'failed' 'RADIOHILAL_MAIN_MOVED_REVALIDATION_REQUIRED' $false @{expectedMainCommit=$expected;localHead=$localHead;validationJobId=$validationJobId;startedAt=$started.ToString('o')} | Out-Null
    exit 31
  }
  $dirty=(& git -C $repo status --porcelain=v1 2>&1 | Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or $dirty){throw 'RADIOHILAL_GIT_CHECKOUT_DIRTY'}

  $svc=Get-Service -Name $serviceName -ErrorAction Stop
  if([string]$svc.Status -ne 'Running'){throw "SERVICE_NOT_RUNNING current=$($svc.Status)"}
  $pre=Get-RadioHilalHealth
  if($pre.PSObject.Properties['queue'] -and -not [string]::IsNullOrWhiteSpace([string]$pre.queue) -and [string]$pre.queue -ne 'Idle'){
    Save-Result $job 'safe-stop' 'RADIOHILAL_QUEUE_ACTIVE_DEPLOY_DEFERRED' $true @{expectedMainCommit=$expected;validationJobId=$validationJobId;queue=[string]$pre.queue;startedAt=$started.ToString('o')} | Out-Null
    exit 0
  }

  New-Item -ItemType Directory -Force -Path $stageRoot,$candidate,$backup,$backupPub | Out-Null
  & robocopy $livePub $backupPub /E /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /NP | Out-Null
  if($LASTEXITCODE -ge 8){throw "LIVE_BACKUP_FAILED robocopy=$LASTEXITCODE"}

  $previousErrorActionPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $addOut=(& git -C $repo worktree add --quiet --detach $worktree $expected 2>&1 | Out-String).Trim()
    $gitExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$previousErrorActionPreference}
  if($gitExit -ne 0){throw "WORKTREE_CREATE_FAILED exit=$gitExit detail=$addOut"}
  $worktreeAdded=$true

  $worktreeHead=(& git -C $worktree rev-parse HEAD 2>&1 | Out-String).Trim().ToLowerInvariant()
  if($LASTEXITCODE -ne 0 -or $worktreeHead -ne $expected){throw "WORKTREE_SHA_MISMATCH expected=$expected actual=$worktreeHead"}
  $project=Join-Path $worktree 'src\RadioHilal.Api\RadioHilal.Api.csproj'
  if(-not(Test-Path -LiteralPath $project -PathType Leaf)){throw 'API_PROJECT_MISSING'}

  $publishOut=(& dotnet publish $project -c Release --nologo -o $candidate 2>&1 | Out-String).Trim()
  if($LASTEXITCODE -ne 0){throw "CANDIDATE_PUBLISH_FAILED $publishOut"}
  $candidateDll=Join-Path $candidate 'RadioHilal.Api.dll'
  if(-not(Test-Path -LiteralPath $candidateDll -PathType Leaf)){throw 'CANDIDATE_DLL_MISSING'}
  $candidateDllHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $candidateDll).Hash
  $preDll=Join-Path $livePub 'RadioHilal.Api.dll'
  $preDllHash=if(Test-Path -LiteralPath $preDll -PathType Leaf){(Get-FileHash -Algorithm SHA256 -LiteralPath $preDll).Hash}else{''}

  $preStop=Get-RadioHilalHealth
  if($preStop.PSObject.Properties['queue'] -and -not [string]::IsNullOrWhiteSpace([string]$preStop.queue) -and [string]$preStop.queue -ne 'Idle'){
    Save-Result $job 'safe-stop' 'RADIOHILAL_QUEUE_BECAME_ACTIVE_DEPLOY_DEFERRED' $true @{expectedMainCommit=$expected;validationJobId=$validationJobId;queue=[string]$preStop.queue;candidateDllSha256=$candidateDllHash;backupPath=$backup;startedAt=$started.ToString('o')} | Out-Null
    exit 0
  }

  $liveMutationStarted=$true
  Stop-Service -Name $serviceName -Force -ErrorAction Stop
  $deadline=(Get-Date).AddSeconds(30)
  do{Start-Sleep -Milliseconds 500;$serviceState=(Get-Service -Name $serviceName -ErrorAction Stop).Status}while($serviceState -ne 'Stopped' -and (Get-Date) -lt $deadline)
  if($serviceState -ne 'Stopped'){throw 'SERVICE_STOP_TIMEOUT'}

  & robocopy $candidate $livePub /E /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /NP | Out-Null
  if($LASTEXITCODE -ge 8){throw "DEPLOY_COPY_FAILED robocopy=$LASTEXITCODE"}
  Get-ChildItem -LiteralPath $backupPub -Filter 'appsettings*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $livePub $_.Name) -Force
  }

  Start-Service -Name $serviceName -ErrorAction Stop
  $post=Wait-RadioHilalHealth 60
  $serviceState=(Get-Service -Name $serviceName -ErrorAction Stop).Status
  if([string]$serviceState -ne 'Running'){throw "SERVICE_POST_DEPLOY_$serviceState"}
  $deployedDll=Join-Path $livePub 'RadioHilal.Api.dll'
  if(-not(Test-Path -LiteralPath $deployedDll -PathType Leaf)){throw 'DEPLOYED_DLL_MISSING'}
  $deployedDllHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $deployedDll).Hash
  if($deployedDllHash -ne $candidateDllHash){throw 'DEPLOYED_DLL_HASH_MISMATCH'}

  Save-Result $job 'completed' 'RADIOHILAL_API_DEPLOYED' $false @{
    expectedMainCommit=$expected;deployedCommit=$worktreeHead;validationJobId=$validationJobId
    validationFinishedUtc=[string]$validation.FinishedUtc;candidateDllSha256=$candidateDllHash
    previousDllSha256=$preDllHash;deployedDllSha256=$deployedDllHash;serviceStatus=[string]$serviceState
    api=[string]$post.api;library=[string]$post.library;queue=[string]$post.queue;backupPath=$backup
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  } | Out-Null
  exit 0
}catch{
  $err=$_.Exception.Message
  if($liveMutationStarted){
    try{Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue}catch{}
    if(Test-Path -LiteralPath $backupPub -PathType Container){
      & robocopy $backupPub $livePub /MIR /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /NP | Out-Null
      $restoreCode=$LASTEXITCODE
      if($restoreCode -ge 8){
        Save-Result $job 'failed' 'RADIOHILAL_DEPLOY_FAILED_ROLLBACK_COPY_FAILED' $false @{expectedMainCommit=$expected;validationJobId=$validationJobId;error=$err;rollbackRobocopy=$restoreCode;backupPath=$backup;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)} | Out-Null
        exit 41
      }
    }
    try{Start-Service -Name $serviceName -ErrorAction Stop}catch{}
    try{
      $rh=Wait-RadioHilalHealth 60
      Save-Result $job 'failed' 'RADIOHILAL_DEPLOY_FAILED_ROLLED_BACK_HEALTHY' $false @{expectedMainCommit=$expected;validationJobId=$validationJobId;error=$err;rollbackApi=[string]$rh.api;rollbackLibrary=[string]$rh.library;rollbackQueue=[string]$rh.queue;backupPath=$backup;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)} | Out-Null
      exit 42
    }catch{
      Save-Result $job 'failed' 'RADIOHILAL_DEPLOY_FAILED_ROLLBACK_HEALTH_UNVERIFIED' $false @{expectedMainCommit=$expected;validationJobId=$validationJobId;error=$err;rollbackError=$_.Exception.Message;backupPath=$backup;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)} | Out-Null
      exit 43
    }
  }

  $retryable=($err -match 'BRIDGE_TASK_TIMEOUT|BUILD_VALIDATION|HEALTH_|SERVICE_NOT_RUNNING')
  Save-Result $job $(if($retryable){'safe-stop'}else{'failed'}) 'RADIOHILAL_DEPLOY_PREMUTATION_STOP' $retryable @{expectedMainCommit=$expected;validationJobId=$validationJobId;error=$err;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)} | Out-Null
  if($retryable){exit 0}else{exit 44}
}finally{
  if($worktreeAdded){
    try{& git -C $repo worktree remove --force $worktree 2>&1 | Out-Null}catch{}
    try{& git -C $repo worktree prune 2>&1 | Out-Null}catch{}
  }
}
