#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

# Emergency observability only. This script never reads control input and never
# changes tasks, processes, files outside its own ACK file, or deployment state.
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
function Invoke-OneShotRuntimeAudit {
  # Temporary audit hook. The child script is read-only except for its own
  # sanitized local marker/output and exits immediately after its one job id is complete.
  try {
    $audit=Join-Path $InstallRoot 'afz-openai-agent\Publish-WindowsRuntimeAuditAck.ps1'
    if(Test-Path -LiteralPath $audit -PathType Leaf){
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $audit *> $null
    }
  } catch {}
}

try {
  if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){exit 0}

  $watch=Read-SafeJson $watchStatePath
  $result=Read-SafeJson $resultPath
  $carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
  $legacy=Get-ScheduledTask -TaskName 'AFZ Website Sync to Pi' -ErrorAction SilentlyContinue
  $siteWatcher=Get-ScheduledTask -TaskName 'AFZ Website Git Deploy Request Watcher' -ErrorAction SilentlyContinue
  $carrierAction=First-TaskAction $carrier
  $legacyAction=First-TaskAction $legacy

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
    legacySiteTaskState=$(if($legacy){[string]$legacy.State}else{'missing'})
    legacySiteExecute=$(if($legacyAction){[string]$legacyAction.Execute}else{$null})
    legacySiteArguments=$(if($legacyAction){[string]$legacyAction.Arguments}else{$null})
    siteWatcherTaskState=$(if($siteWatcher){[string]$siteWatcher.State}else{'missing'})
    time=(Get-Date -Format o)
  }
  $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ackFile -Encoding UTF8
  Invoke-OneShotRuntimeAudit
} catch {
  try {
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      [ordered]@{
        schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github'
        component='AFZ Website Deploy Post-State ACK';status='probe-error';message=$_.Exception.Message;time=(Get-Date -Format o)
      } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ackFile -Encoding UTF8
    }
  } catch {}
  Invoke-OneShotRuntimeAudit
}
exit 0
