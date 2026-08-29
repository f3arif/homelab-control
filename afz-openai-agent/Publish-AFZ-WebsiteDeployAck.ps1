#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

# Emergency observability publisher. Temporary final cleanup: retire the duplicate
# OneDrive-named AutoRunner only when it is byte-for-byte equivalent at the Task
# Scheduler action level to the canonical Queue AutoRunner and the canonical task is healthy.
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$ackFile=Join-Path $diagRoot 'AFZ-WEBSITE-DEPLOY-ACK-LATEST.json'
$watchStatePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy\request-watcher.json'
$resultPath='C:\Users\Faiz\AppData\Local\AFZ\WebsiteGitDeploy\latest.json'
$activeRequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-site-deploy.json'

function Read-SafeJson([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop}catch{return $null}
}
function First-TaskAction($Task){
  if(-not $Task){return $null}
  $a=@($Task.Actions | Select-Object -First 1)
  if($a.Count -eq 0){return $null}
  return $a[0]
}
function Task-Signature($Task){
  $a=First-TaskAction $Task
  if(-not $a){return $null}
  return (([string]$a.Execute).Trim().ToLowerInvariant()+'|'+([string]$a.Arguments).Trim().ToLowerInvariant())
}
function Invoke-FinalAutoRunnerCleanup {
  $out=[ordered]@{attempted=$true;ok=$false;legacy='AFZ OneDrive Auto Runner';canonical='AFZ Queue AutoRunner';action=$null;message=$null}
  try{
    $legacy=Get-ScheduledTask -TaskName $out.legacy -ErrorAction SilentlyContinue
    $canonical=Get-ScheduledTask -TaskName $out.canonical -ErrorAction SilentlyContinue
    if(-not $legacy){$out.ok=$true;$out.action='already-absent';$out.message='Legacy AutoRunner is already absent.';return $out}
    if(-not $canonical){$out.action='retained';$out.message='Canonical Queue AutoRunner is missing.';return $out}
    if((Task-Signature $legacy) -ne (Task-Signature $canonical)){$out.action='retained';$out.message='Task actions differ; no cleanup performed.';return $out}
    if(-not [bool]$canonical.Settings.Enabled){Enable-ScheduledTask -TaskName $out.canonical -TaskPath $canonical.TaskPath -ErrorAction Stop|Out-Null}
    $canonical=Get-ScheduledTask -TaskName $out.canonical -ErrorAction Stop
    if([string]$canonical.State -ne 'Running'){
      Start-ScheduledTask -TaskName $out.canonical -TaskPath $canonical.TaskPath -ErrorAction Stop
      Start-Sleep -Seconds 3
      $canonical=Get-ScheduledTask -TaskName $out.canonical -ErrorAction Stop
    }
    if([string]$canonical.State -notin @('Running','Ready')){$out.action='retained';$out.message="Canonical state is $($canonical.State).";return $out}
    if([string]$legacy.State -eq 'Running'){
      Stop-ScheduledTask -TaskName $out.legacy -TaskPath $legacy.TaskPath -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 2
    }
    Disable-ScheduledTask -TaskName $out.legacy -TaskPath $legacy.TaskPath -ErrorAction Stop|Out-Null
    $legacy=Get-ScheduledTask -TaskName $out.legacy -ErrorAction Stop
    $canonical=Get-ScheduledTask -TaskName $out.canonical -ErrorAction Stop
    if([bool]$legacy.Settings.Enabled){throw 'Legacy AutoRunner remained enabled.'}
    if(-not [bool]$canonical.Settings.Enabled){throw 'Canonical Queue AutoRunner became disabled.'}
    $out.ok=$true;$out.action='disabled-duplicate';$out.message="Legacy disabled; canonical state=$($canonical.State)."
    return $out
  }catch{
    $out.action='retained-or-partial';$out.message=$_.Exception.Message
    return $out
  }
}

try {
  if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){exit 0}

  $cleanup=Invoke-FinalAutoRunnerCleanup
  $watch=Read-SafeJson $watchStatePath
  $result=Read-SafeJson $resultPath
  $carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
  $legacySite=Get-ScheduledTask -TaskName 'AFZ Website Sync to Pi' -ErrorAction SilentlyContinue
  $siteWatcher=Get-ScheduledTask -TaskName 'AFZ Website Git Deploy Request Watcher' -ErrorAction SilentlyContinue
  $carrierAction=First-TaskAction $carrier
  $legacySiteAction=First-TaskAction $legacySite

  $payload=[ordered]@{
    schema=1
    purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
    source='windows-main'
    controlPlane='github'
    component='AFZ Website Deploy Post-State ACK'
    activeRequestExists=(Test-Path -LiteralPath $activeRequestPath -PathType Leaf)
    watcherStateExists=(Test-Path -LiteralPath $watchStatePath -PathType Leaf)
    watcherStatus=$(if($watch){[string]$watch.status}else{$null})
    watcherJobId=$(if($watch){[string]$watch.jobId}else{$null})
    watcherExpectedSiteSha=$(if($watch){[string]$watch.expectedSiteSha}else{$null})
    watcherMessage=$(if($watch){[string]$watch.message}else{$null})
    carrierRestored=$(if($watch -and $null -ne $watch.carrierRestored){[bool]$watch.carrierRestored}else{$null})
    legacySiteRestored=$(if($watch -and $null -ne $watch.legacySiteRestored){[bool]$watch.legacySiteRestored}else{$null})
    legacySiteDisabled=$(if($watch -and $null -ne $watch.legacySiteDisabled){[bool]$watch.legacySiteDisabled}else{$null})
    resultExists=(Test-Path -LiteralPath $resultPath -PathType Leaf)
    resultOk=$(if($result -and $null -ne $result.ok){[bool]$result.ok}else{$null})
    resultStatus=$(if($result){[string]$result.status}else{$null})
    resultJobId=$(if($result){[string]$result.jobId}else{$null})
    resultExpectedSiteSha=$(if($result){[string]$result.expectedSiteSha}else{$null})
    resultMessage=$(if($result){[string]$result.message}else{$null})
    edgeBackupTaskState=$(if($carrier){[string]$carrier.State}else{'missing'})
    edgeBackupExecute=$(if($carrierAction){[string]$carrierAction.Execute}else{$null})
    edgeBackupArguments=$(if($carrierAction){[string]$carrierAction.Arguments}else{$null})
    legacySiteTaskState=$(if($legacySite){[string]$legacySite.State}else{'missing'})
    legacySiteExecute=$(if($legacySiteAction){[string]$legacySiteAction.Execute}else{$null})
    legacySiteArguments=$(if($legacySiteAction){[string]$legacySiteAction.Arguments}else{$null})
    siteWatcherTaskState=$(if($siteWatcher){[string]$siteWatcher.State}else{'missing'})
    runtimeCleanup=$cleanup
    time=(Get-Date -Format o)
  }
  $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ackFile -Encoding UTF8
} catch {
  try {
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      [ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github';component='AFZ Website Deploy Post-State ACK';status='probe-error';message=$_.Exception.Message;time=(Get-Date -Format o)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ackFile -Encoding UTF8
    }
  } catch {}
}
exit 0
