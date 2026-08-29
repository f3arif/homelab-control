#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$shared=Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc\AFZ Shared'
$priority=Join-Path $shared 'AFZ Priority'
$target=Join-Path $priority 'AFZ-Priority-Controller.ps1'
$backups=Join-Path $priority 'Backups'
$expectedSha256='916ABA18157D6A478CC177D405C5E16D756F8258DE5B56A293A5D3B875A6DD29'
$oldVersion='$controllerVersion = ''5.5-portable-normal-lenovo-wake'''
$newVersion='$controllerVersion = ''5.6-hplaptop-live-recovery'''
$oldVars='$hplaptopHeartbeatFreshSeconds = 90'
$newVars=@'
$hplaptopHeartbeatFreshSeconds = 90
$hplaptopObserverUrl = 'http://100.119.172.36:8766/health'
$hplaptopDirectWorkerTaskName = 'AFZ HPLaptop Direct Remote Worker'
$hplaptopLegacyWorkerTaskName = 'AFZ HPLaptop Remote Worker'
$hplaptopOnlineRecoveryWaitSeconds = 15
'@
$helperAnchor='function Send-AFZHPLaptopMagicPacket {'
$helper=@'
function Test-AFZHPLaptopDirectReady {
  $direct=Join-Path $workerHeartbeatRoot 'hplaptop-direct.txt'
  if(-not (Test-Path -LiteralPath $direct)){ return $false }
  try {
    $age=((Get-Date)-(Get-Item -LiteralPath $direct).LastWriteTime).TotalSeconds
    if($age -gt 20){ return $false }
    $kv=@{}; foreach($line in @(Get-Content -LiteralPath $direct -ErrorAction Stop)){ if($line -match '^([^=]+)=(.*)$'){ $kv[$matches[1].Trim().ToLowerInvariant()]=$matches[2].Trim() } }
    return ([string]$kv['state'] -eq 'READY' -and [string]$kv['eligible'] -eq 'True')
  } catch { return $false }
}

function Invoke-AFZHPLaptopOnlineRecovery {
  $r=[ordered]@{reachable=$false;resourceSafe=$false;directReady=$false;observer=$hplaptopObserverUrl;taskStarted=$false;detail=''}
  $health=$null
  try { $health=Invoke-RestMethod -UseBasicParsing -Uri $hplaptopObserverUrl -TimeoutSec 4 } catch {
    $r.detail='observer_unreachable'
    Log 'HPLAPTOP_LIVE_PROBE_UNREACHABLE | observer health endpoint did not respond'
    return [pscustomobject]$r
  }
  $r.reachable=$true
  $ac=$false; $ram=$null; $computer=''
  try{$ac=($health.acPowerOnline -eq $true)}catch{}
  try{$ram=[double]$health.ramUsedPercent}catch{}
  try{$computer=[string]$health.computer}catch{}
  if($computer -and $computer -ne 'HPLAPTOP'){
    $r.detail=('observer_identity_mismatch:'+ $computer)
    Log ('HPLAPTOP_LIVE_PROBE_REJECT | unexpected observer computer='+$computer)
    return [pscustomobject]$r
  }
  $r.resourceSafe=($ac -and $null -ne $ram -and $ram -lt 85)
  if(-not $r.resourceSafe){
    $r.detail=('observer_gated ac='+$ac+' ram='+$ram)
    Log ('HPLAPTOP_LIVE_PROBE_GATED | ac='+$ac+' ram='+$ram)
    return [pscustomobject]$r
  }

  # The observer proves the laptop is already awake. Re-arm the existing local
  # SSH-over-Tailscale workers instead of attempting Wake-on-LAN.
  foreach($taskName in @($hplaptopDirectWorkerTaskName,$hplaptopLegacyWorkerTaskName)){
    try {
      $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
      if($task -and $task.State -ne 'Running'){
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $r.taskStarted=$true
        Log ('HPLAPTOP_LIVE_WORKER_START | task='+$taskName+' previousState='+[string]$task.State)
      }
    } catch { Log ('HPLAPTOP_LIVE_WORKER_START_FAILED | task='+$taskName+' | '+$_.Exception.Message) }
  }

  $deadline=(Get-Date).AddSeconds($hplaptopOnlineRecoveryWaitSeconds)
  do {
    if(Test-AFZHPLaptopDirectReady){
      $r.directReady=$true
      $r.detail=('direct_ready ac='+$ac+' ram='+$ram)
      try { if(Test-Path -LiteralPath $adaptiveController){ & $adaptiveController } } catch {}
      Log ('HPLAPTOP_LIVE_RECOVERED | direct READY over Tailscale; ac='+$ac+' ram='+$ram)
      return [pscustomobject]$r
    }
    Start-Sleep -Seconds 1
  } while((Get-Date) -lt $deadline)
  $r.detail='observer_reachable_but_direct_worker_heartbeat_not_fresh'
  Log ('HPLAPTOP_LIVE_PROBE_TIMEOUT | wait='+$hplaptopOnlineRecoveryWaitSeconds+'s')
  return [pscustomobject]$r
}

'@
$oldCandidate=@'
function Get-AFZHPLaptopCandidate {
  param([switch]$AllowWake)
  if(-not (Test-AFZWorkerAcceptingNewWork -Worker 'hplaptop')){ return $null }
  try {
    $slot=Get-AFZWorkerFreeSlots -Worker 'hplaptop'
    if($slot.stateFresh -and $slot.available -and $slot.resourceSafe -and [int]$slot.queueRemaining -gt 0){ return 'hplaptop' }
    if($AllowWake -and (-not $slot.stateFresh -or -not $slot.available)){
      [void](Invoke-AFZHPLaptopWakeRecovery)
      $slot=Get-AFZWorkerFreeSlots -Worker 'hplaptop'
      if($slot.stateFresh -and $slot.available -and $slot.resourceSafe -and [int]$slot.queueRemaining -gt 0){ return 'hplaptop' }
    }
  } catch {}
  return $null
}
'@
$newCandidate=@'
function Get-AFZHPLaptopCandidate {
  param([switch]$AllowWake)
  if(-not (Test-AFZWorkerAcceptingNewWork -Worker 'hplaptop')){ return $null }
  try {
    $slot=Get-AFZWorkerFreeSlots -Worker 'hplaptop'
    if($slot.stateFresh -and $slot.available -and $slot.resourceSafe -and [int]$slot.queueRemaining -gt 0){ return 'hplaptop' }

    # Stale AFZ telemetry does not mean the physical laptop is asleep. Probe the
    # proven observer over Tailscale first and re-arm the existing SSH worker locally.
    $live=Invoke-AFZHPLaptopOnlineRecovery
    if($live.reachable){
      if(-not $live.resourceSafe -or -not $live.directReady){ return $null }
      $slot=Get-AFZWorkerFreeSlots -Worker 'hplaptop'
      if($slot.stateFresh -and $slot.available -and $slot.resourceSafe -and [int]$slot.queueRemaining -gt 0){ return 'hplaptop' }

      # Transitional fallback: the direct worker itself is fresh/eligible, but the
      # legacy aggregate may still lag. Respect the configured queue limit and use
      # the direct executor rather than incorrectly falling back to ASUS.
      $queueLimit=1
      try{if([int]$slot.queueLimit -gt 0){$queueLimit=[int]$slot.queueLimit}}catch{}
      $outstanding=Get-AFZWorkerOutstandingCount -Worker 'hplaptop' -Extension '.ps1'
      if($outstanding -lt $queueLimit){
        Log ('HPLAPTOP_LIVE_DIRECT_FALLBACK | direct worker proven READY; outstanding='+$outstanding+' queueLimit='+$queueLimit)
        return 'hplaptop'
      }
      return $null
    }

    # Only an actually unreachable observer is eligible for the existing bounded WOL path.
    if($AllowWake){
      [void](Invoke-AFZHPLaptopWakeRecovery)
      $live=Invoke-AFZHPLaptopOnlineRecovery
      if($live.reachable -and $live.resourceSafe -and $live.directReady){
        $slot=Get-AFZWorkerFreeSlots -Worker 'hplaptop'
        if($slot.stateFresh -and $slot.available -and $slot.resourceSafe -and [int]$slot.queueRemaining -gt 0){ return 'hplaptop' }
        $queueLimit=1
        try{if([int]$slot.queueLimit -gt 0){$queueLimit=[int]$slot.queueLimit}}catch{}
        if((Get-AFZWorkerOutstandingCount -Worker 'hplaptop' -Extension '.ps1') -lt $queueLimit){ return 'hplaptop' }
      }
    }
  } catch { Log ('HPLAPTOP_CANDIDATE_ERROR | '+$_.Exception.Message) }
  return $null
}
'@

if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Priority controller missing: $target"}
New-Item -ItemType Directory -Force -Path $backups | Out-Null
$raw=[IO.File]::ReadAllText($target)
if($raw.Contains($newVersion) -and $raw.Contains('function Invoke-AFZHPLaptopOnlineRecovery')){
  Write-Output 'STATUS=ALREADY_APPLIED'; exit 0
}
$actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()
Write-Output ('SOURCE_SHA256='+$actual)
if($actual -ne $expectedSha256){throw "Source changed concurrently; expected $expectedSha256 got $actual"}
foreach($pair in @(@($oldVersion,$newVersion),@($oldVars,$newVars),@($helperAnchor,($helper+$helperAnchor)),@($oldCandidate,$newCandidate))){
  $old=[string]$pair[0]; $new=[string]$pair[1]
  $count=[regex]::Matches($raw,[regex]::Escape($old)).Count
  if($count -ne 1){throw "Expected exactly one replacement target; found $count for: $($old.Substring(0,[Math]::Min(80,$old.Length)))"}
  $raw=$raw.Replace($old,$new)
}
$tmp=$target+'.hplaptop-live-recovery.tmp'
$utf8Bom=New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($tmp,$raw,$utf8Bom)
try {
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){throw ('Candidate parse failed: '+((@($errors)|ForEach-Object{$_.Message}) -join ' | '))}
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup=Join-Path $backups ("AFZ-Priority-Controller-before-hplaptop-live-recovery-$stamp.ps1")
  Copy-Item -LiteralPath $target -Destination $backup -Force
  Move-Item -LiteralPath $tmp -Destination $target -Force
  $newHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToUpperInvariant()
  Write-Output 'STATUS=PASS'
  Write-Output ('BACKUP='+$backup)
  Write-Output ('NEW_SHA256='+$newHash)
  Write-Output 'CHANGE=Stale HPLaptop telemetry now probes live Tailscale observer and re-arms existing SSH workers before WOL/fallback'
  Write-Output 'UNCHANGED=HPLaptop allow marker; AC and RAM gates; queue limits; host pins; project priority; existing bounded WOL fallback'
} finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
