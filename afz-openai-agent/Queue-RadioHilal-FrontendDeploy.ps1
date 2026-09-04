#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\radiohilal-frontend-deploy.json'
}
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\radiohilal-frontend-deploy-queue'
$stateFile=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorFile=Join-Path $mirrorRoot 'AFZ-RadioHilal-FrontendDeployQueue-Latest.json'
$repo='C:\AFZ\RadioHilalGit'
$opsWorktree='C:\AFZ\RadioHilalGit-ops'
$bridgeTask='RadioHilal-GitHub-Bridge'
$remoteOpsTask='AFZ Remote Ops'
$remoteOpsRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$jobsDir=Join-Path $remoteOpsRoot 'jobs'
$processingDir=Join-Path $remoteOpsRoot 'processing'
$resultsDir=Join-Path $remoteOpsRoot 'results'
$archiveDir=Join-Path $remoteOpsRoot 'archive'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 20),$utf8)
}
function Save-State([string]$Status,[string]$Classification,[bool]$Retryable,[hashtable]$Extra){
  $o=[ordered]@{
    schema=1
    controlPlane='github'
    source='windows-main-postsync-fixed-request'
    project='radiohilal'
    status=$Status
    classification=$Classification
    retryable=$Retryable
    host=$expectedComputer
    secretExposed=$false
    oneDriveRole='local-queue-plus-backup-result-mirror'
    time=(Get-Date -Format o)
  }
  foreach($k in $Extra.Keys){$o[$k]=$Extra[$k]}
  Write-Json $stateFile $o
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){Write-Json $mirrorFile $o}}catch{}
  $o | ConvertTo-Json -Depth 20 -Compress | Write-Output
}
function Test-Admin {
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $principal=New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Wait-TaskIdle([string]$TaskName,[int]$Seconds=240){
  $deadline=(Get-Date).AddSeconds($Seconds)
  do{
    $t=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if(-not $t){throw "TASK_MISSING $TaskName"}
    if([string]$t.State -ne 'Running'){return}
    Start-Sleep -Seconds 2
  }while((Get-Date) -lt $deadline)
  throw "TASK_TIMEOUT $TaskName"
}
function Invoke-BridgeOnce {
  Wait-TaskIdle $bridgeTask 240
  Start-ScheduledTask -TaskName $bridgeTask -ErrorAction Stop
  Wait-TaskIdle $bridgeTask 240
}

if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if(-not(Test-Admin)){throw 'ELEVATED_SYSTEM_OR_ADMIN_REQUIRED'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){exit 0}
$req=Read-Json $RequestPath
if(-not $req){throw 'INVALID_REQUEST_JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'radiohilal' -or [string]$req.action -ne 'queue-github-frontend-exact'){throw 'INVALID_REQUEST_SCHEMA_PROJECT_ACTION'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
if([string]$req.repository -ne 'f3arif/RadioHilal'){throw 'INVALID_REPOSITORY'}
if(-not [bool]$req.rollback_on_failure -or [bool]$req.allow_api_restart -or [bool]$req.allow_database_mutation){throw 'INVALID_SAFETY_FLAGS'}

$jobId=([string]$req.job_id).Trim()
$expected=([string]$req.expected_main_commit).Trim().ToLowerInvariant()
$validationJobId=([string]$req.validation_job_id).Trim()
if($jobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'INVALID_JOB_ID'}
if($expected -notmatch '^[0-9a-f]{40}$'){throw 'INVALID_EXPECTED_MAIN_COMMIT'}
if($validationJobId -notmatch '^[A-Za-z0-9._-]{8,160}$'){throw 'INVALID_VALIDATION_JOB_ID'}

$prior=Read-Json $stateFile
if($prior -and [string]$prior.jobId -eq $jobId -and [string]$prior.status -eq 'completed'){
  $prior | ConvertTo-Json -Depth 20 -Compress | Write-Output
  exit 0
}

if(-not(Test-Path -LiteralPath (Join-Path $repo '.git'))){throw 'RADIOHILAL_GIT_CHECKOUT_MISSING'}
if(-not(Test-Path -LiteralPath $opsWorktree -PathType Container)){throw 'RADIOHILAL_OPS_WORKTREE_MISSING'}

$validationLocal=Join-Path $opsWorktree ("github-ops\results\$validationJobId.json")
if(-not(Test-Path -LiteralPath $validationLocal -PathType Leaf)){
  try{Invoke-BridgeOnce}catch{
    Save-State 'safe-stop' 'RADIOHILAL_BRIDGE_NOT_READY' $true @{jobId=$jobId;expectedMainCommit=$expected;validationJobId=$validationJobId;error=$_.Exception.Message}
    exit 0
  }
}
if(-not(Test-Path -LiteralPath $validationLocal -PathType Leaf)){
  Save-State 'safe-stop' 'RADIOHILAL_BUILD_VALIDATION_PENDING' $true @{jobId=$jobId;expectedMainCommit=$expected;validationJobId=$validationJobId}
  exit 0
}
$validation=Read-Json $validationLocal
if(-not $validation){throw 'BUILD_VALIDATION_JSON_INVALID'}
if([string]$validation.Action -ne 'BuildApi' -or [string]$validation.Status -ne 'Succeeded' -or [int]$validation.ExitCode -ne 0){throw "BUILD_VALIDATION_NOT_SUCCESS status=$($validation.Status) exit=$($validation.ExitCode)"}
if((([string]$validation.ExpectedMainCommit).Trim().ToLowerInvariant()) -ne $expected){throw 'BUILD_VALIDATION_COMMIT_MISMATCH'}
if((([string]$validation.JobId).Trim()) -ne $validationJobId){throw 'BUILD_VALIDATION_JOB_MISMATCH'}

$localHead=(& git -C $repo rev-parse HEAD 2>&1 | Out-String).Trim().ToLowerInvariant()
if($LASTEXITCODE -ne 0 -or $localHead -ne $expected){
  Save-State 'safe-stop' 'RADIOHILAL_LOCAL_MAIN_NOT_EXACT' $true @{jobId=$jobId;expectedMainCommit=$expected;localHead=$localHead;validationJobId=$validationJobId}
  exit 0
}
$dirty=(& git -C $repo status --porcelain=v1 2>&1 | Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $dirty){throw 'RADIOHILAL_GIT_CHECKOUT_DIRTY'}

foreach($d in @($jobsDir,$processingDir,$resultsDir,$archiveDir)){
  if(-not(Test-Path -LiteralPath $d -PathType Container)){New-Item -ItemType Directory -Path $d -Force | Out-Null}
}
$fileName=$jobId+'.json'
foreach($d in @($jobsDir,$processingDir,$resultsDir,$archiveDir)){
  $p=Join-Path $d $fileName
  if(Test-Path -LiteralPath $p -PathType Leaf){
    Save-State 'completed' 'RADIOHILAL_FRONTEND_DEPLOY_ALREADY_QUEUED_OR_HANDLED' $false @{jobId=$jobId;expectedMainCommit=$expected;validationJobId=$validationJobId;existingPath=$p}
    exit 0
  }
}

$job=[ordered]@{
  id=$jobId
  project='radiohilal'
  action='github-main-frontend-deploy'
  resourceClass='local-heavy'
  quickJob=$false
  expectedSeconds=300
  estimatedMemoryMb=1536
  notify=$false
  args=[ordered]@{
    expectedMainCommit=$expected
    validationJobId=$validationJobId
  }
}
$tmp=Join-Path $jobsDir ($fileName+'.tmp-'+[guid]::NewGuid().ToString('N'))
$dst=Join-Path $jobsDir $fileName
Write-Json $tmp $job
Move-Item -LiteralPath $tmp -Destination $dst -Force

$task=Get-ScheduledTask -TaskName $remoteOpsTask -ErrorAction SilentlyContinue
if(-not $task){throw 'REMOTEOPS_TASK_MISSING'}
$stateBefore=[string]$task.State
if($stateBefore -ne 'Running'){
  Start-ScheduledTask -TaskName $remoteOpsTask -ErrorAction Stop
  Start-Sleep -Seconds 2
}
$stateAfter=[string](Get-ScheduledTask -TaskName $remoteOpsTask -ErrorAction Stop).State

Save-State 'completed' 'RADIOHILAL_FRONTEND_DEPLOY_QUEUED' $false @{
  jobId=$jobId
  expectedMainCommit=$expected
  validationJobId=$validationJobId
  queuePath=$dst
  remoteOpsStateBefore=$stateBefore
  remoteOpsStateAfter=$stateAfter
  apiRestartRequested=$false
}
exit 0
