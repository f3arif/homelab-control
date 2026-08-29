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

# Credential-bearing execution carrier: documented Interactive-logon task that already
# reaches the Raspberry Pi with C:\Users\Faiz\.ssh\afz_pi_sync. We replace only its
# Action temporarily; principal, triggers and settings remain unchanged and are restored.
$carrierTaskName='AFZ Edge Backup'
# This is the old OneDrive website publisher. It is not used as the credential carrier.
# It is paused during cutover to enforce no-dual-execution and remains disabled only
# after a fully verified Git deployment.
$legacySiteTaskName='AFZ Website Sync to Pi'
$resultFile='C:\Users\Faiz\AppData\Local\AFZ\WebsiteGitDeploy\latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Save-State([hashtable]$Values){
  $base=[ordered]@{
    updatedAt=(Get-Date -Format o)
    transport='github-typed-request+edge-backup-interactive-carrier'
    carrierTask=$carrierTaskName
    legacySiteTask=$legacySiteTaskName
  }
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
function Task-IsEnabled($task){return ($task -and [string]$task.State -ne 'Disabled')}
function New-RestoredCarrierAction($state){
  $params=@{Execute=[string]$state.carrierOriginalExecute}
  if(-not [string]::IsNullOrWhiteSpace([string]$state.carrierOriginalArguments)){$params.Argument=[string]$state.carrierOriginalArguments}
  if(-not [string]::IsNullOrWhiteSpace([string]$state.carrierOriginalWorkingDirectory)){$params.WorkingDirectory=[string]$state.carrierOriginalWorkingDirectory}
  return New-ScheduledTaskAction @params
}
function Restore-CarrierTask($state){
  if(-not $state -or [string]::IsNullOrWhiteSpace([string]$state.carrierOriginalExecute)){throw 'Cannot restore AFZ Edge Backup carrier: original action missing from watcher state.'}
  $action=New-RestoredCarrierAction $state
  Set-ScheduledTask -TaskName $carrierTaskName -Action $action | Out-Null
  if([bool]$state.carrierWasEnabled){Enable-ScheduledTask -TaskName $carrierTaskName | Out-Null}else{Disable-ScheduledTask -TaskName $carrierTaskName | Out-Null}
}
function Restore-LegacySiteTask($state){
  if(-not $state -or -not [bool]$state.legacySiteExisted){return}
  if([bool]$state.legacySiteWasEnabled){Enable-ScheduledTask -TaskName $legacySiteTaskName | Out-Null}else{Disable-ScheduledTask -TaskName $legacySiteTaskName | Out-Null}
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

  # Crash-safe recovery if the process stopped between capturing task state and
  # launching the one-time carrier invocation. Never auto-retry the same job id.
  if((Same-Request $state $jobId $sha) -and [string]$state.status -eq 'arming'){
    try{Restore-CarrierTask $state}catch{}
    try{Restore-LegacySiteTask $state}catch{}
    Save-State @{ok=$false;status='failed';jobId=$jobId;expectedSiteSha=$sha;message='Recovered interrupted R3 arming state; carrier and legacy site task were restored where possible. Change job_id to retry.'}
    Log "RECOVER_ARMING job=$jobId sha=$sha"
    return
  }

  if((Same-Request $state $jobId $sha) -and [string]$state.status -eq 'deploying'){
    $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
    if($carrier -and $carrier.State -eq 'Running'){return}

    $result=Read-Json $resultFile
    $success=($result -and [bool]$result.ok -and [string]$result.status -eq 'completed' -and [string]$result.jobId -eq $jobId -and ([string]$result.expectedSiteSha).ToLowerInvariant() -eq $sha)
    try{
      Restore-CarrierTask $state
    }catch{
      Save-State @{ok=$false;status='failed';jobId=$jobId;expectedSiteSha=$sha;message=('Deployment ended but AFZ Edge Backup carrier restoration failed: '+$_.Exception.Message);resultFile=$resultFile}
      Log "CARRIER_RESTORE_FAIL job=$jobId sha=$sha error=$($_.Exception.Message)"
      return
    }

    if($success){
      # Keep the old OneDrive publisher disabled only after the executor has already
      # verified Pi-local site state, public deployment marker, and real WebChat POST.
      $legacy=Get-ScheduledTask -TaskName $legacySiteTaskName -ErrorAction SilentlyContinue
      if($legacy){Disable-ScheduledTask -TaskName $legacySiteTaskName | Out-Null}
      Save-State @{
        ok=$true;status='completed';jobId=$jobId;expectedSiteSha=$sha
        message='Git-authoritative site deployment verified; AFZ Edge Backup carrier restored; legacy OneDrive website sync disabled.'
        resultFile=$resultFile;carrierRestored=$true;legacySiteDisabled=[bool]$legacy
      }
      Log "DEPLOY_OK job=$jobId sha=$sha carrier=restored legacy_site_sync=disabled"
    }else{
      try{Restore-LegacySiteTask $state}catch{}
      $msg=$(if($result){[string]$result.message}else{'Carrier task ended without a matching deployment result file.'})
      Save-State @{
        ok=$false;status='failed';jobId=$jobId;expectedSiteSha=$sha;message=$msg
        resultFile=$resultFile;carrierRestored=$true;legacySiteRestored=$true
      }
      Log "DEPLOY_FAIL job=$jobId sha=$sha message=$msg"
    }
    return
  }

  if(-not(Test-Path -LiteralPath $deployScript -PathType Leaf)){throw "Fixed site deploy script missing: $deployScript"}
  $carrier=Get-ScheduledTask -TaskName $carrierTaskName -ErrorAction SilentlyContinue
  if(-not $carrier){throw "Credential carrier task not found: $carrierTaskName"}
  if($carrier.State -eq 'Running'){
    Save-State @{ok=$true;status='waiting';jobId=$jobId;expectedSiteSha=$sha;message='Waiting for current AFZ Edge Backup invocation to finish before borrowing its Interactive-logon execution identity.'}
    return
  }

  $legacy=Get-ScheduledTask -TaskName $legacySiteTaskName -ErrorAction SilentlyContinue
  if($legacy -and $legacy.State -eq 'Running'){
    Save-State @{ok=$true;status='waiting';jobId=$jobId;expectedSiteSha=$sha;message='Waiting for current legacy website sync invocation to finish; no-dual-execution boundary is enforced.'}
    return
  }

  $original=$carrier.Actions|Select-Object -First 1
  if(-not $original -or [string]::IsNullOrWhiteSpace([string]$original.Execute)){throw 'AFZ Edge Backup carrier has no restorable action.'}
  $carrierWasEnabled=Task-IsEnabled $carrier
  $legacyExisted=[bool]$legacy
  $legacyWasEnabled=Task-IsEnabled $legacy

  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  Save-State @{
    ok=$true;status='arming';jobId=$jobId;expectedSiteSha=$sha
    message='Captured AFZ Edge Backup action and task enable states before temporary R3 carrier swap.'
    carrierWasEnabled=$carrierWasEnabled
    carrierOriginalExecute=[string]$original.Execute
    carrierOriginalArguments=[string]$original.Arguments
    carrierOriginalWorkingDirectory=[string]$original.WorkingDirectory
    legacySiteExisted=$legacyExisted
    legacySiteWasEnabled=$legacyWasEnabled
  }

  # Prevent the old 15-minute OneDrive publisher from racing the Git promotion.
  if($legacy){Disable-ScheduledTask -TaskName $legacySiteTaskName | Out-Null}

  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$deployScript`" -ExpectedSiteSha `"$sha`" -JobId `"$jobId`""
  $newAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
  Set-ScheduledTask -TaskName $carrierTaskName -Action $newAction | Out-Null
  Enable-ScheduledTask -TaskName $carrierTaskName | Out-Null
  Start-ScheduledTask -TaskName $carrierTaskName

  Save-State @{
    ok=$true;status='deploying';jobId=$jobId;expectedSiteSha=$sha
    message='Fixed Git website deployment is running under the proven AFZ Edge Backup Interactive-logon identity.'
    carrierWasEnabled=$carrierWasEnabled
    carrierOriginalExecute=[string]$original.Execute
    carrierOriginalArguments=[string]$original.Arguments
    carrierOriginalWorkingDirectory=[string]$original.WorkingDirectory
    legacySiteExisted=$legacyExisted
    legacySiteWasEnabled=$legacyWasEnabled
  }
  Log "DEPLOY_START job=$jobId sha=$sha carrier='$carrierTaskName' legacy_site_paused=$legacyExisted"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZSiteDeployRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s action=deploy-pi-static-site carrier='$carrierTaskName'"
  # One-time exact R5 orphan self-heal. This helper is fail-closed and can stop only
  # the verified R5 staging SSH child; it never touches the carrier task or deploy core.
  try{
    $r5Release=Join-Path $InstallRoot 'afz-openai-agent\Release-AFZ-Site-R5-OrphanSsh.ps1'
    if(Test-Path -LiteralPath $r5Release -PathType Leaf){
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $r5Release *> $null
      if($LASTEXITCODE -ne 0){Log "R5_ORPHAN_RELEASE_HELPER_EXIT exit=$LASTEXITCODE"}
    }
  }catch{Log "R5_ORPHAN_RELEASE_HELPER_ERROR $($_.Exception.Message)"}
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
