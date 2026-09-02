#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-git-migration'
$watchState=Join-Path $stateRoot 'request-watcher.json'
$logFile=Join-Path $stateRoot 'request-watcher.log'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-git-migration.json'
$executor=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZ-Blog-Git-Migration.ps1'
$carrierTaskName='AFZ Edge Backup'
$resultFile='C:\Users\Faiz\AppData\Local\AFZ\BlogGitMigration\latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}}
function Save-State([hashtable]$Values){
  $base=[ordered]@{updatedAt=(Get-Date -Format o);transport='github-typed-request+edge-backup-interactive-carrier';carrierTask=$carrierTaskName;project='afz-blog'}
  foreach($k in $Values.Keys){$base[$k]=$Values[$k]}
  $base|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Valid-Request($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'afz-blog'){return $false}
  if([string]$r.action -ne 'bootstrap-private-repo'){return $false}
  if([string]$r.source_repository -ne 'f3arif/homelab-control'){return $false}
  if([string]$r.target_repository -ne 'f3arif/AFZ-Blog'){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  return $true
}
function Task-IsEnabled($task){return ($task -and [string]$task.State -ne 'Disabled')}
function New-RestoredCarrierAction($state){
  $params=@{Execute=[string]$state.carrierOriginalExecute}
  if(-not [string]::IsNullOrWhiteSpace([string]$state.carrierOriginalArguments)){$params.Argument=[string]$state.carrierOriginalArguments}
  if(-not [string]::IsNullOrWhiteSpace([string]$state.carrierOriginalWorkingDirectory)){$params.WorkingDirectory=[string]$state.carrierOriginalWorkingDirectory}
  return New-ScheduledTaskAction @params
}
function Restore-CarrierTask($state){
  if(-not $state -or [string]::IsNullOrWhiteSpace([string]$state.carrierOriginalExecute)){throw 'Cannot restore AFZ Edge Backup carrier: original action missing.'}
  Set-ScheduledTask -TaskName $carrierTaskName -Action (New-RestoredCarrierAction $state) | Out-Null
  if([bool]$state.carrierWasEnabled){Enable-ScheduledTask -TaskName $carrierTaskName | Out-Null}else{Disable-ScheduledTask -TaskName $carrierTaskName | Out-Null}
}
function Same-Request($state,[string]$JobId){return ($state -and [string]$state.jobId -eq $JobId)}

function Handle-BlogGitMigrationRequest {
  if(-not(Test-Path -LiteralPath $requestFile -PathType Leaf)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed AFZ Blog Git migration request: $requestFile"}
  $jobId=[string]$req.job_id
  $target=[string]$req.target_repository
  $state=Read-Json $watchState

  if((Same-Request $state $jobId) -and [string]$state.status -in @('completed','failed')){return}

  if((Same-Request $state $jobId) -and [string]$state.status -eq 'arming'){
    try{Restore-CarrierTask $state}catch{}
    Save-State @{ok=$false;status='failed';jobId=$jobId;targetRepository=$target;message='Recovered interrupted arming state and restored the carrier where possible. Change job_id to retry.'}
    Log "RECOVER_ARMING job=$jobId"
    return
  }

  if((Same-Request $state $jobId) -and [string]$state.status -eq 'running'){
    $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
    if($carrier -and $carrier.State -eq 'Running'){return}
    $result=Read-Json $resultFile
    $matched=($result -and [string]$result.jobId -eq $jobId -and [string]$result.targetRepository -eq $target)
    try{Restore-CarrierTask $state}catch{
      Save-State @{ok=$false;status='failed';jobId=$jobId;targetRepository=$target;message=('Migration ended but carrier restoration failed: '+$_.Exception.Message);resultFile=$resultFile}
      Log "CARRIER_RESTORE_FAIL job=$jobId error=$($_.Exception.Message)"
      return
    }
    if($matched -and [bool]$result.ok){
      Save-State @{ok=$true;status='completed';jobId=$jobId;targetRepository=$target;classification=[string]$result.classification;published=[bool]$result.published;message=[string]$result.message;resultFile=$resultFile;carrierRestored=$true}
      Log "MIGRATION_DONE job=$jobId classification=$([string]$result.classification) published=$([bool]$result.published)"
    }else{
      $msg=$(if($matched){[string]$result.error}else{'Carrier task ended without a matching migration result file.'})
      Save-State @{ok=$false;status='failed';jobId=$jobId;targetRepository=$target;message=$msg;resultFile=$resultFile;carrierRestored=$true}
      Log "MIGRATION_FAIL job=$jobId message=$msg"
    }
    return
  }

  if(-not(Test-Path -LiteralPath $executor -PathType Leaf)){throw "Blog Git migration executor missing: $executor"}
  $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
  if(-not $carrier){throw "Credential carrier task not found: $carrierTaskName"}
  if($carrier.State -eq 'Running'){
    Save-State @{ok=$true;status='waiting';jobId=$jobId;targetRepository=$target;message='Waiting for the current AFZ Edge Backup invocation to finish before borrowing its Interactive-logon identity.'}
    return
  }

  $original=$carrier.Actions|Select-Object -First 1
  if(-not $original -or [string]::IsNullOrWhiteSpace([string]$original.Execute)){throw 'AFZ Edge Backup carrier has no restorable action.'}
  $carrierWasEnabled=Task-IsEnabled $carrier
  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

  Save-State @{
    ok=$true;status='arming';jobId=$jobId;targetRepository=$target;message='Captured AFZ Edge Backup action before temporary Blog Git migration carrier swap.'
    carrierWasEnabled=$carrierWasEnabled;carrierOriginalExecute=[string]$original.Execute;carrierOriginalArguments=[string]$original.Arguments;carrierOriginalWorkingDirectory=[string]$original.WorkingDirectory
  }

  $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$executor`" -Action bootstrap-private-repo -JobId `"$jobId`" -TargetRepository `"$target`" -ResultPath `"$resultFile`""
  $newAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  Set-ScheduledTask -TaskName $carrierTaskName -Action $newAction | Out-Null
  Enable-ScheduledTask -TaskName $carrierTaskName | Out-Null
  Start-ScheduledTask -TaskName $carrierTaskName

  Save-State @{
    ok=$true;status='running';jobId=$jobId;targetRepository=$target;message='Guarded AFZ Blog Git bootstrap is running under the proven interactive carrier identity.'
    carrierWasEnabled=$carrierWasEnabled;carrierOriginalExecute=[string]$original.Execute;carrierOriginalArguments=[string]$original.Arguments;carrierOriginalWorkingDirectory=[string]$original.WorkingDirectory
  }
  Log "MIGRATION_START job=$jobId target=$target"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZBlogGitMigrationRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s action=bootstrap-private-repo carrier='$carrierTaskName'"
  while($true){
    try{Handle-BlogGitMigrationRequest}catch{
      $msg=$_.Exception.Message;Log "ERROR $msg"
      $req=Read-Json $requestFile;$jid=$(if($req){[string]$req.job_id}else{''});$target=$(if($req){[string]$req.target_repository}else{''})
      Save-State @{ok=$false;status='error';jobId=$jid;targetRepository=$target;message=$msg}
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
