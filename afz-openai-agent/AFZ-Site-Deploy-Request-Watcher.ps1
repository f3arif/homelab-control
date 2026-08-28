#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy'
$watchState=Join-Path $stateRoot 'request-watcher.json'
$logFile=Join-Path $stateRoot 'request-watcher.log'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-site-deploy.json'
$deployScript=Join-Path $InstallRoot 'afz-openai-agent\Deploy-AFZ-WebsiteToPi.ps1'
$legacyTaskName='AFZ Website Sync to Pi'
$resultFile='C:\Users\Faiz\AppData\Local\AFZ\WebsiteGitDeploy\latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Save-State([hashtable]$Values){
  $base=[ordered]@{updatedAt=(Get-Date -Format o);transport='github-typed-request+windows-local-pi-key';legacyTask=$legacyTaskName}
  foreach($k in $Values.Keys){$base[$k]=$Values[$k]}
  $base|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Valid-Request($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'afz-website'){return $false}
  if([string]$r.action -ne 'deploy-pi-static-site'){return $false}
  if([string]$r.source_repository -ne 'f3arif/afz-engineering'){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  if(([string]$r.expected_sha) -notmatch '^[0-9a-fA-F]{40}$'){return $false}
  return $true
}
function New-RestoredAction($state){
  $params=@{Execute=[string]$state.originalExecute}
  if(-not [string]::IsNullOrWhiteSpace([string]$state.originalArguments)){$params.Argument=[string]$state.originalArguments}
  if(-not [string]::IsNullOrWhiteSpace([string]$state.originalWorkingDirectory)){$params.WorkingDirectory=[string]$state.originalWorkingDirectory}
  return New-ScheduledTaskAction @params
}
function Restore-LegacyTask($state,[bool]$EnableAfter){
  if(-not $state -or [string]::IsNullOrWhiteSpace([string]$state.originalExecute)){throw 'Cannot restore legacy website sync task: original action missing from watcher state.'}
  $action=New-RestoredAction $state
  Set-ScheduledTask -TaskName $legacyTaskName -Action $action | Out-Null
  if($EnableAfter){Enable-ScheduledTask -TaskName $legacyTaskName | Out-Null}else{Disable-ScheduledTask -TaskName $legacyTaskName | Out-Null}
}
function Same-Request($state,[string]$JobId,[string]$Sha){
  return ($state -and [string]$state.jobId -eq $JobId -and ([string]$state.expectedSiteSha).ToLowerInvariant() -eq $Sha)
}

function Handle-SiteDeployRequest {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed AFZ website deployment request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=([string]$req.expected_sha).ToLowerInvariant()
  $state=Read-Json $watchState

  if((Same-Request $state $jobId $sha) -and [string]$state.status -in @('completed','failed')){return}

  if((Same-Request $state $jobId $sha) -and [string]$state.status -eq 'arming'){
    try{Restore-LegacyTask $state ([bool]$state.legacyWasEnabled)}catch{}
    Save-State @{ok=$false;status='failed';jobId=$jobId;expectedSiteSha=$sha;message='Recovered interrupted arming state before deployment; no automatic retry. Change job_id to retry.'}
    Log "RECOVER_ARMING job=$jobId sha=$sha"
    return
  }

  if((Same-Request $state $jobId $sha) -and [string]$state.status -eq 'deploying'){
    $legacy=Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    if($legacy -and $legacy.State -eq 'Running'){return}

    $result=Read-Json $resultFile
    $success=($result -and [bool]$result.ok -and [string]$result.status -eq 'completed' -and [string]$result.jobId -eq $jobId -and ([string]$result.expectedSiteSha).ToLowerInvariant() -eq $sha)
    try{
      Restore-LegacyTask $state $false
    }catch{
      Save-State @{ok=$false;status='failed';jobId=$jobId;expectedSiteSha=$sha;message=('Deployment finished but legacy task restoration failed: '+$_.Exception.Message)}
      Log "RESTORE_FAIL job=$jobId sha=$sha error=$($_.Exception.Message)"
      return
    }

    if($success){
      Save-State @{ok=$true;status='completed';jobId=$jobId;expectedSiteSha=$sha;message='Git-authoritative site deployment verified; legacy OneDrive website sync restored then disabled.';resultFile=$resultFile;legacyWasEnabled=[bool]$state.legacyWasEnabled}
      Log "DEPLOY_OK job=$jobId sha=$sha legacy_sync=disabled"
    }else{
      if([bool]$state.legacyWasEnabled){Enable-ScheduledTask -TaskName $legacyTaskName | Out-Null}
      $msg=$(if($result){[string]$result.message}else{'Deployment task ended without a matching result file.'})
      Save-State @{ok=$false;status='failed';jobId=$jobId;expectedSiteSha=$sha;message=$msg;resultFile=$resultFile;legacyRestored=$true;legacyWasEnabled=[bool]$state.legacyWasEnabled}
      Log "DEPLOY_FAIL job=$jobId sha=$sha message=$msg"
    }
    return
  }

  if(-not(Test-Path -LiteralPath $deployScript -PathType Leaf)){throw "Fixed site deploy script missing: $deployScript"}
  $legacy=Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
  if(-not $legacy){throw "Legacy website task not found: $legacyTaskName"}
  if($legacy.State -eq 'Running'){
    Save-State @{ok=$true;status='waiting';jobId=$jobId;expectedSiteSha=$sha;message='Waiting for current legacy website sync invocation to finish before taking over its execution identity.'}
    return
  }

  $original=$legacy.Actions|Select-Object -First 1
  if(-not $original -or [string]::IsNullOrWhiteSpace([string]$original.Execute)){throw 'Legacy website task has no restorable action.'}
  $wasEnabled=[bool]$legacy.Settings.Enabled

  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  Save-State @{
    ok=$true
    status='arming'
    jobId=$jobId
    expectedSiteSha=$sha
    message='Original legacy task action captured before temporary Git deploy action swap.'
    legacyWasEnabled=$wasEnabled
    originalExecute=[string]$original.Execute
    originalArguments=[string]$original.Arguments
    originalWorkingDirectory=[string]$original.WorkingDirectory
  }

  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$deployScript`" -ExpectedSiteSha `"$sha`" -JobId `"$jobId`""
  $newAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  Set-ScheduledTask -TaskName $legacyTaskName -Action $newAction | Out-Null
  Enable-ScheduledTask -TaskName $legacyTaskName | Out-Null
  Start-ScheduledTask -TaskName $legacyTaskName

  Save-State @{
    ok=$true
    status='deploying'
    jobId=$jobId
    expectedSiteSha=$sha
    message='Fixed Git website deployment is running under the existing website-sync user identity.'
    legacyWasEnabled=$wasEnabled
    originalExecute=[string]$original.Execute
    originalArguments=[string]$original.Arguments
    originalWorkingDirectory=[string]$original.WorkingDirectory
  }
  Log "DEPLOY_START job=$jobId sha=$sha legacy_enabled_before=$wasEnabled"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZSiteDeployRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s action=deploy-pi-static-site"
  while($true){
    try{Handle-SiteDeployRequest}catch{
      $msg=$_.Exception.Message
      Log "ERROR $msg"
      $req=Read-Json $requestFile
      $jid=$(if($req){[string]$req.job_id}else{''})
      $sha=$(if($req){[string]$req.expected_sha}else{''})
      Save-State @{ok=$false;status='error';jobId=$jid;expectedSiteSha=$sha;message=$msg}
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
