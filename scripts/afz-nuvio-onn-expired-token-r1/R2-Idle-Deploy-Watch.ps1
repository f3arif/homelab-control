param([switch]$DryRun)
$ErrorActionPreference='Stop'
$stage='C:\AFZ\Nuvio-Setup-20260923\onn-expired-token-repair-20261011'
$root='C:\AFZ\Stremio-Failover-H3'
$taskName='AFZ Nuvio R2 Safe Idle Deploy'
$config=Join-Path $stage 'r2-idle-watch-config.json'
$statusFile=Join-Path $stage 'r2-idle-watch-status.json'
$deploy=Join-Path $stage 'Deploy-Expired-Token-R2.ps1'
$lastReceipt=Join-Path $stage 'r2-deployment-result.json'
$baseline='d6523ee180b3ea6e0b8a41d08c4454e945af662f0d585fc6139a370826605a4f'
$candidate='3dab113e23725a39401f8ba3c619b9eb0b6cd5eec47a0f677df2dc84404a74a5'
$live=Join-Path $root 'stremio_catalog.py'
$staged=Join-Path $stage 'stremio_catalog.r2.candidate.py'
$backup=Join-Path $root 'stremio_catalog.py.before-onn-expired-token-20261011-r2.bak'
$mutex=New-Object System.Threading.Mutex($false,'Global\AFZ_NUVIO_R2_DEPLOY_IDLE_GATE_20261011')
$owned=$false
function Set-WatchStatus([string]$status,[string]$reason='', [int]$count=0) {
  $payload=[ordered]@{
    updatedUtc=(Get-Date).ToUniversalTime().ToString('o')
    status=$status
    reason=$reason.Substring(0,[math]::Min(180,$reason.Length))
    observedConnections=$count
    originalServiceTouched=$false
    initiatedBy='Windows Task Scheduler guarded R2 watch'
    dryRun=[bool]$DryRun
  }
  try{
    $tmp=$statusFile+'.'+[string]$PID+'.tmp'
    [IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $statusFile -Force
  }catch{
    Write-Output ('WATCH_STATUS_WRITE_ERROR='+$_.Exception.GetType().Name)
  }
  Write-Output ('WATCH='+$status+' REASON='+$reason)
}
function Stop-Watch {
  if(-not $DryRun){
    try{Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop|Out-Null}catch{}
  }
}
function Sha([string]$f){return (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()}
function ActiveSessions {
  return @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
    Where-Object {$_.LocalPort -in @(18774,8445,10000)})
}
try {
  try {
    $owned=$mutex.WaitOne(0)
  } catch [Threading.AbandonedMutexException] {
    $owned=$true
  }
  if(-not $owned){Write-Output 'WATCH_ALREADY_RUNNING';return}
  if(-not(Test-Path -LiteralPath $config)){Set-WatchStatus 'DISARMED' 'Missing bounded configuration';Stop-Watch;return}
  $conf=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
  $deadline=[datetimeoffset]::Parse([string]$conf.deadlineUtc)
  if([datetimeoffset]::UtcNow -ge $deadline){
    Set-WatchStatus 'EXPIRED' 'Eight-hour observation window ended without deployment'
    Stop-Watch
    return
  }
  if(Test-Path -LiteralPath $lastReceipt){
    $receipt=Get-Content -LiteralPath $lastReceipt -Raw|ConvertFrom-Json
    if($receipt.status -eq 'DEPLOYED_AND_SMOKE_VERIFIED'){
      if((Sha $live) -eq $candidate){Set-WatchStatus 'DEPLOYED_VERIFIED' 'Deployment receipt and source hash match';Stop-Watch;return}
      Set-WatchStatus 'DISARMED' 'Receipt success but active source hash mismatch';Stop-Watch;return
    }
    if($receipt.status -in @('ROLLED_BACK','ROLLBACK_BLOCKED_MANUAL_RECOVERY_REQUIRED')){
      Set-WatchStatus 'DISARMED' ('Prior deployment status '+$receipt.status);Stop-Watch;return
    }
  }
  if(-not(Test-Path -LiteralPath $live) -or -not(Test-Path -LiteralPath $staged) -or -not(Test-Path -LiteralPath $deploy)){
    Set-WatchStatus 'DISARMED' 'Required pinned source/deploy file missing';Stop-Watch;return
  }
  if((Sha $live) -ne $baseline -or (Sha $staged) -ne $candidate){
    Set-WatchStatus 'DISARMED' 'Baseline or candidate SHA256 drift';Stop-Watch;return
  }
  if(Test-Path -LiteralPath $backup){
    Set-WatchStatus 'DISARMED' 'Existing rollback backup; require manual reconciliation';Stop-Watch;return
  }
  try {
    $m=Invoke-RestMethod 'http://127.0.0.1:18774/manifest.json' -TimeoutSec 4
    if($m.id -ne 'com.afzengineering.releasecatalog' -or $m.version -ne '0.6.243'){throw 'Unexpected manifest'}
  }catch{
    Set-WatchStatus 'DISARMED' 'Catalog baseline unhealthy or unexpected';Stop-Watch;return
  }
  # A true quiet interval avoids a restart during an existing H3 local/edge stream.
  for($i=0;$i -lt 15;$i++){
    $sessions=ActiveSessions
    if($sessions.Count -gt 0){
      Set-WatchStatus 'WAITING_FOR_QUIET' 'Established catalog or media transport connections' $sessions.Count
      return
    }
    if($DryRun){Set-WatchStatus 'DRY_RUN_PASS' 'Pinned artifacts and immediate idle gate valid';return}
    Start-Sleep -Seconds 2
  }
  $sessions=ActiveSessions
  if($sessions.Count -gt 0){
    Set-WatchStatus 'WAITING_FOR_QUIET' 'Connection appeared after 30-second quiet interval' $sessions.Count
    return
  }
  Set-WatchStatus 'DEPLOY_IN_PROGRESS' '30-second network quiet gate passed; invoking guarded deploy'
  $output=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $deploy -Apply 2>&1|Out-String)
  $exitCode=$LASTEXITCODE
  $current=if(Test-Path -LiteralPath $lastReceipt){Get-Content -LiteralPath $lastReceipt -Raw|ConvertFrom-Json}else{$null}
  $res=[string]$current.status
  if($exitCode -eq 0 -and $res -eq 'DEPLOYED_AND_SMOKE_VERIFIED' -and (Sha $live) -eq $candidate){
    Set-WatchStatus 'DEPLOYED_VERIFIED' 'Guarded R2 install, restart and backend HTTP smoke passed'
    Stop-Watch
    return
  }
  $errorText=[string]$current.error
  if($res -eq 'FAILED' -and $errorText.StartsWith('ACTIVE_STREAM_CLIENT_CONNECTIONS=') -and
     (Sha $live) -eq $baseline -and -not(Test-Path -LiteralPath $backup)){
    Set-WatchStatus 'WAITING_FOR_QUIET' 'Final deploy gate found new connections; no change made'
    return
  }
  Set-WatchStatus 'DISARMED_ON_DEPLOY_ERROR' ('Deployment status='+$res+', exit='+$exitCode)
  Stop-Watch
} catch {
  Set-WatchStatus 'DISARMED_ON_WATCH_ERROR' ($_.Exception.GetType().Name+': '+$_.Exception.Message)
  Stop-Watch
} finally {
  if($owned){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
