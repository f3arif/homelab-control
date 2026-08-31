#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

# Emergency observability only. This script never reads control input and never
# changes tasks, processes, files outside its own ACK files, or deployment state.
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$ackFile=Join-Path $diagRoot 'AFZ-WEBSITE-DEPLOY-ACK-LATEST.json'
$qwenTextAckFile=Join-Path $diagRoot 'AFZ-GITHUB-TRANSPORT-ACK-LATEST.inspect3.txt'
$watchStatePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy\request-watcher.json'
$resultPath='C:\Users\Faiz\AppData\Local\AFZ\WebsiteGitDeploy\latest.json'
$activeRequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-site-deploy.json'
$r5ReleasePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-site-deploy\r5-orphan-release.json'
$r5JobId='afz-site-git-cutover-r5-20260828T1151'
$h3HotfixMarkerPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix\gh-argument-binding-v1.json'
$h3PostmortemHookPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix\postmortem-hook-latest.json'
$h3PostmortemMarkerPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-postmortem\postmortem-v1.json'
$qwenTransportHelperPath=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-TransportRecovery.ps1'
$qwenPostReturnCarrierPath=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-PostReturnRecovery.ps1'
$qwenPostReturnToolPath=Join-Path $InstallRoot 'afz-openai-agent\tools\Recover-H3-Qwen35BA3B-PostReturn.ps1'
$qwenTransportStatePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-transport-recovery\latest.json'
$qwenPostReturnStatePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-postreturn-recovery\latest.json'
$qwenActivationPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-request\qwen35b-a3b-website-20260830-r1-activation-v1.json'
$qwenBootstrapPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-bootstrap\latest.json'

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
function Safe-FileHash([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}catch{return $null}
}

try {
  if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){exit 0}

  $watch=Read-SafeJson $watchStatePath
  $result=Read-SafeJson $resultPath
  $h3Hotfix=Read-SafeJson $h3HotfixMarkerPath
  $h3PostHook=Read-SafeJson $h3PostmortemHookPath
  $h3PostMarker=Read-SafeJson $h3PostmortemMarkerPath
  $qwenTransportState=Read-SafeJson $qwenTransportStatePath
  $qwenPostReturnState=Read-SafeJson $qwenPostReturnStatePath
  $qwenActivation=Read-SafeJson $qwenActivationPath
  $qwenBootstrap=Read-SafeJson $qwenBootstrapPath
  $carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
  $legacy=Get-ScheduledTask -TaskName 'AFZ Website Sync to Pi' -ErrorAction SilentlyContinue
  $siteWatcher=Get-ScheduledTask -TaskName 'AFZ Website Git Deploy Request Watcher' -ErrorAction SilentlyContinue
  $carrierAction=First-TaskAction $carrier
  $legacyAction=First-TaskAction $legacy
  $r5Release=Read-SafeJson $r5ReleasePath
  $r5Core=@();$r5CorePids=@();$r5Ssh=@()
  try {
    $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    $r5Core=@($all | Where-Object {
      [string]$_.Name -ieq 'powershell.exe' -and
      ([string]$_.CommandLine) -match '(?i)Deploy-AFZ-WebsiteToPi-Core[.]ps1' -and
      ([string]$_.CommandLine) -match [regex]::Escape($r5JobId)
    })
    $r5CorePids=@($r5Core | ForEach-Object {[int]$_.ProcessId})
    $r5Ssh=@($all | Where-Object {
      ([string]$_.Name) -match '(?i)^ssh[.]exe$' -and
      $r5CorePids -contains [int]$_.ParentProcessId -and
      ([string]$_.CommandLine) -match [regex]::Escape('192.168.50.68') -and
      ([string]$_.CommandLine) -match '(?i)mkdir -p' -and
      ([string]$_.CommandLine) -match [regex]::Escape('/opt/edge/afz-site/git-deploy/stage')
    })
  } catch {}

  $payload=[ordered]@{
    schema=1
    purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
    source='windows-main'
    controlPlane='github'
    component='AFZ Website Deploy Post-State ACK'
    qwen35BReadOnly=$true
    qwen35BModelAction='NONE'
    qwen35BTransportHelperExists=(Test-Path -LiteralPath $qwenTransportHelperPath -PathType Leaf)
    qwen35BTransportHelperSha256=Safe-FileHash $qwenTransportHelperPath
    qwen35BPostReturnCarrierExists=(Test-Path -LiteralPath $qwenPostReturnCarrierPath -PathType Leaf)
    qwen35BPostReturnCarrierSha256=Safe-FileHash $qwenPostReturnCarrierPath
    qwen35BPostReturnToolExists=(Test-Path -LiteralPath $qwenPostReturnToolPath -PathType Leaf)
    qwen35BPostReturnToolSha256=Safe-FileHash $qwenPostReturnToolPath
    qwen35BTransportStateExists=(Test-Path -LiteralPath $qwenTransportStatePath -PathType Leaf)
    qwen35BTransportState=$qwenTransportState
    qwen35BPostReturnStateExists=(Test-Path -LiteralPath $qwenPostReturnStatePath -PathType Leaf)
    qwen35BPostReturnState=$qwenPostReturnState
    qwen35BActivationState=$qwenActivation
    qwen35BBootstrapState=$qwenBootstrap
    h3ReturnHotfixMarkerExists=(Test-Path -LiteralPath $h3HotfixMarkerPath -PathType Leaf)
    h3ReturnHotfixStatus=$(if($h3Hotfix){[string]$h3Hotfix.status}else{$null})
    h3ReturnHotfixReason=$(if($h3Hotfix){[string]$h3Hotfix.reason}else{$null})
    h3ReturnPostmortemHookExists=(Test-Path -LiteralPath $h3PostmortemHookPath -PathType Leaf)
    h3ReturnPostmortemHook=$h3PostHook
    h3ReturnPostmortemMarkerExists=(Test-Path -LiteralPath $h3PostmortemMarkerPath -PathType Leaf)
    h3ReturnPostmortem=$h3PostMarker
    r5OrphanReleaseStateExists=(Test-Path -LiteralPath $r5ReleasePath -PathType Leaf)
    r5OrphanReleasePurpose=$(if($r5Release){[string]$r5Release.purpose}else{$null})
    r5OrphanReleaseStatus=$(if($r5Release){[string]$r5Release.status}else{$null})
    r5OrphanReleaseMessage=$(if($r5Release){[string]$r5Release.message}else{$null})
    r5OrphanReleaseCorePid=$(if($r5Release -and $null -ne $r5Release.corePid){[int]$r5Release.corePid}else{$null})
    r5OrphanReleaseSshPid=$(if($r5Release -and $null -ne $r5Release.sshPid){[int]$r5Release.sshPid}else{$null})
    r5OrphanReleaseCoreStillAlive=$(if($r5Release -and $null -ne $r5Release.coreStillAliveAfterObservation){[bool]$r5Release.coreStillAliveAfterObservation}else{$null})
    r5CoreProcessCount=@($r5Core).Count
    r5CorePids=@($r5CorePids)
    r5SshProcessCount=@($r5Ssh).Count
    r5SshPids=@($r5Ssh | ForEach-Object {[int]$_.ProcessId})
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
  $payloadJson=$payload | ConvertTo-Json -Depth 30
  $payloadJson | Set-Content -LiteralPath $ackFile -Encoding UTF8
  $payloadJson | Set-Content -LiteralPath $qwenTextAckFile -Encoding UTF8
} catch {
  try {
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      $errorPayload=[ordered]@{
        schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github'
        component='AFZ Website Deploy Post-State ACK';status='probe-error';message=$_.Exception.Message
        qwen35BReadOnly=$true;qwen35BModelAction='NONE';time=(Get-Date -Format o)
      } | ConvertTo-Json -Depth 4
      $errorPayload | Set-Content -LiteralPath $ackFile -Encoding UTF8
      $errorPayload | Set-Content -LiteralPath $qwenTextAckFile -Encoding UTF8
    }
  } catch {}
}
exit 0
