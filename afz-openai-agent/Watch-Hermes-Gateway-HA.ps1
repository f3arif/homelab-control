#Requires -Version 5.1
# Hermes Telegram gateway host-level HA watcher (ASUS / windows-main side).
#
# Normal state  : H3 (DESKTOP-H3R6CQN) runs the Telegram gateway; ASUS stays stopped.
# Failover      : 3 consecutive failed H3 gateway checks -> ASUS promotes its own
#                 native Hermes gateway (user-context task) and marks ACTIVE_HOST=ASUS.
# Demotion      : 3 consecutive healthy H3 checks -> ASUS stops its gateway and
#                 marks ACTIVE_HOST=H3. Handover is deliberate; duplicate Telegram
#                 polling is never knowingly allowed.
#
# Ambiguous probe results (SSH reachable but probe unparseable, or SSH down while
# the H3 host itself answers tailscale ping) never count toward promotion, to
# avoid split-brain when only the control path is degraded.
#
# Simulation    : presence of C:\ProgramData\AFZ\HermesRouting\gateway-ha-simulate.flag
#                 makes the watcher treat the H3 gateway as failed WITHOUT touching H3.
#
# State : C:\ProgramData\AFZ\HermesRouting\gateway-ha.json
# Log   : C:\ProgramData\AFZ\HermesRouting\gateway-ha.log
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){ exit 3 }

$stateDir='C:\ProgramData\AFZ\HermesRouting'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$stateFile=Join-Path $stateDir 'gateway-ha.json'
$logFile=Join-Path $stateDir 'gateway-ha.log'
$simFlag=Join-Path $stateDir 'gateway-ha-simulate.flag'
$handoffDir=Join-Path $stateDir 'gateway-ha-handoff'
$userTask='AFZ Hermes Gateway HA User Action'

$h3Tailscale='100.106.186.118'
$h3Lan='192.168.50.185'
$h3Key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$h3KnownHosts='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$sshExe=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'

$failThreshold=3
$successThreshold=3
$startAssistCooldownSeconds=300
$maxAssistsPerOutage=3
$probeTimeoutMs=15000
$startAssistWaitSeconds=90

$utf8=New-Object Text.UTF8Encoding($false)
$failClasses=@('h3GatewayDown','h3TelegramNotEstablished','h3HostUnreachable','SIMULATED_h3GatewayDown')
$simReason=''

function Write-Log([string]$m){
  try{Add-Content -LiteralPath $logFile -Value ("$(Get-Date -Format o) $m") -Encoding UTF8}catch{}
}
function Read-State{
  if(Test-Path -LiteralPath $stateFile -PathType Leaf){
    try{return Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
  }
  return $null
}
function Write-State($o){
  $json=$o|ConvertTo-Json -Depth 12
  try{[IO.File]::WriteAllText($stateFile,$json,$utf8)}catch{}
}

function Get-LocalGatewayState{
  $pids=@()
  try{
    $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
      ([string]$_.Name)-match '(?i)python|hermes' -and ([string]$_.CommandLine)-match '(?i)hermes_cli[.]main' -and ([string]$_.CommandLine)-match '(?i)gateway\s+run'})
    $pids=@($procs|ForEach-Object{[int]$_.ProcessId})
  }catch{}
  $tg=$false
  if($pids.Count -gt 0){
    try{
      $conns=@(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue|Where-Object{
        [int]$_.RemotePort -eq 443 -and ((([string]$_.RemoteAddress)-like '149.154.*') -or (([string]$_.RemoteAddress)-like '91.108.*'))})
      foreach($c in $conns){ if($pids -contains [int]$c.OwningProcess){$tg=$true;break} }
    }catch{}
  }
  return [ordered]@{gatewayPidCount=@($pids).Count;gatewayPids=@($pids);telegramEstablished=$tg}
}

function Invoke-RemoteScript([string]$Target,[string[]]$Extra,[string]$Script,[int]$TimeoutMs){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''stdin empty''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('ha-probe-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('ha-probe-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('ha-probe-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$h3Key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=7','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$h3KnownHosts))
  if($Extra){$args+=@($Extra)}
  $args+=@($Target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$Script,$utf8)
    $p=Start-Process -FilePath $sshExe -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    $timedOut=(-not $p.WaitForExit($TimeoutMs))
    if($timedOut){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{}}
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    return [pscustomobject]@{timedOut=$timedOut;exit=$(if($timedOut){$null}else{[int]$p.ExitCode});stdout=$stdout;stderrPresent=(-not [string]::IsNullOrWhiteSpace($stderr))}
  }catch{return [pscustomobject]@{timedOut=$false;exit=$null;stdout='';stderrPresent=$true}}
  finally{Remove-Item $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}
function Parse-JsonResult($r){
  if(-not $r){return $null}
  foreach($line in @(([string]$r.stdout)-split "`r?`n"|Where-Object{$_})){
    try{$parsed=$line|ConvertFrom-Json}catch{}
  }
  return $parsed
}

$probeScript=@'
$ErrorActionPreference='SilentlyContinue'
$out=[ordered]@{}
$out.host=$env:COMPUTERNAME
$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]$_.Name)-match '(?i)python|hermes' -and ([string]$_.CommandLine)-match '(?i)hermes_cli[.]main' -and ([string]$_.CommandLine)-match '(?i)gateway\s+run'})
$out.gatewayPids=@($procs|ForEach-Object{[int]$_.ProcessId})
$out.gatewayPidCount=@($procs).Count
$tg=$false
if(@($procs).Count -gt 0){
  $pset=@($procs|ForEach-Object{[int]$_.ProcessId})
  $conns=@(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue|Where-Object{[int]$_.RemotePort -eq 443 -and ((([string]$_.RemoteAddress)-like '149.154.*') -or (([string]$_.RemoteAddress)-like '91.108.*'))})
  foreach($c in $conns){if($pset -contains [int]$c.OwningProcess){$tg=$true;break}}
}
$out.telegramEstablished=$tg
$lp=Join-Path $env:LOCALAPPDATA 'hermes\logs\gateway.log'
if(Test-Path -LiteralPath $lp -PathType Leaf){$out.gatewayLogAgeMinutes=[int]((New-TimeSpan (Get-Item $lp).LastWriteTime (Get-Date)).TotalMinutes)}else{$out.gatewayLogAgeMinutes=$null}
$ollama=$false
try{$v=Invoke-RestMethod http://127.0.0.1:11434/api/version -TimeoutSec 3;$ollama=[bool]$v.version}catch{}
$out.ollamaOk=$ollama
$out|ConvertTo-Json -Compress
'@

function Invoke-H3Probe{
  $routes=@(
    [pscustomobject]@{target=("Faiz@"+$h3Tailscale);transport='tailscale';extra=@()},
    [pscustomobject]@{target='Faiz@192.168.50.185';transport='lan-hostkey-alias';extra=@('-o','HostKeyAlias=' + $h3Tailscale)}
  )
  foreach($r in $routes){
    if(-not (Test-Path -LiteralPath $h3Key -PathType Leaf)){break}
    $rr=Invoke-RemoteScript $r.target $r.extra $probeScript $probeTimeoutMs
    $pp=Parse-JsonResult $rr
    if($pp -and ($pp.PSObject.Properties.Name -contains 'gatewayPidCount')){
      $cls='h3GatewayHealthy'
      if([int]$pp.gatewayPidCount -le 0){$cls='h3GatewayDown'}
      elseif(-not [bool]$pp.telegramEstablished){$cls='h3TelegramNotEstablished'}
      return [ordered]@{
        classification=$cls
        transport=$r.transport
        gatewayPidCount=[int]$pp.gatewayPidCount
        gatewayPids=@($pp.gatewayPids)
        telegramEstablished=[bool]$pp.telegramEstablished
        gatewayLogAgeMinutes=$pp.gatewayLogAgeMinutes
        ollamaOk=[bool]$pp.ollamaOk
      }
    }
  }
  return $null
}

function Test-H3HostUp{
  try{
    $raw=(& tailscale.exe ping --timeout=3s -c 1 $h3Tailscale 2>&1|Out-String)
    return [bool]($raw -match '(?i)\bpong from\b')
  }catch{return $false}
}

function Invoke-UserGatewayAction([string]$Lifecycle){
  if(-not (Test-Path -LiteralPath $handoffDir -PathType Container)){return $null}
  $commandPath=Join-Path $handoffDir 'command.json'
  $resultPath=Join-Path $handoffDir 'result.json'
  $commandId=('ha-'+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  try{
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $commandPath -Force -ErrorAction SilentlyContinue
    $cmdObj=[ordered]@{commandId=$commandId;lifecycle=$lifecycle;requestedAt=(Get-Date -Format o);issuedBy='gateway-ha-watcher'}
    $cmdJson=$cmdObj|ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($commandPath,$cmdJson,$utf8)
  }catch{return $null}
  try{Start-ScheduledTask -TaskName $userTask -ErrorAction Stop}catch{return $null}
  $deadline=(Get-Date).AddSeconds(110)
  do{
    Start-Sleep -Milliseconds 1500
    if(Test-Path -LiteralPath $resultPath -PathType Leaf){
      try{
        $res=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($res -and ([string]$res.commandId -eq $commandId)){return $res}
      }catch{}
    }
  }while((Get-Date) -lt $deadline)
  return $null
}

# ---- main ----
$now=(Get-Date -Format o)
$prev=Read-State
$simulated=(Test-Path -LiteralPath $simFlag -PathType Leaf)

$asus=Get-LocalGatewayState

if($simulated){
  $h3=[ordered]@{classification='SIMULATED_h3GatewayDown';transport='simulation';gatewayPidCount=$null;gatewayPids=@();telegramEstablished=$false;gatewayLogAgeMinutes=$null;ollamaOk=$null}
  $simReason=''
  try{$simReason=((Get-Content -LiteralPath $simFlag -Raw -Encoding UTF8) -split "`r?`n")[0]}catch{}
}else{
  $probe=Invoke-H3Probe
  if($probe){
    $h3=$probe
  }else{
    $hostUp=Test-H3HostUp
    $cls=$(if($hostUp){'h3SshProbeUnavailable'}else{'h3HostUnreachable'})
    $h3=[ordered]@{classification=$cls;transport=$(if($hostUp){'none-host-up'}else{'none-host-down'});gatewayPidCount=$null;gatewayPids=@();telegramEstablished=$false;gatewayLogAgeMinutes=$null;ollamaOk=$null}
  }
}

$state=[ordered]@{}
if($prev){
  foreach($p in $prev.PSObject.Properties){$state[$p.Name]=$p.Value}
}else{
  $state.schema=1
  $state.activeHost='H3'
  $state.primaryHost='DESKTOP-H3R6CQN'
  $state.standbyHost='DESKTOP-10SKF0M'
  $state.consecutivePrimaryFailures=0
  $state.consecutivePrimarySuccesses=0
  $state.lastPromotion=$null
  $state.lastDemotion=$null
  $state.reason='initialized'
  $state.promotionCycle=0
  $state.assistsThisOutage=0
  $state.lastAssistAt=$null
}
$state.time=$now
$state.lastCheckTime=$now
$state.activeHost=[string]$state.activeHost
if($state.activeHost -notin @('H3','ASUS')){$state.activeHost='H3'}
$state.primaryHost='DESKTOP-H3R6CQN'
$state.standbyHost='DESKTOP-10SKF0M'
$state.simulation=$simulated
$state.simulationReason=$simReason
$state.h3=$h3
$state.asus=[ordered]@{gatewayPidCount=[int]$asus.gatewayPidCount;gatewayPids=@($asus.gatewayPids);telegramEstablished=[bool]$asus.telegramEstablished}

$h3Healthy=([string]$h3.classification -eq 'h3GatewayHealthy')
$h3Failed=([string]$h3.classification -in $failClasses)
$action='none'

if($h3Healthy){
  $state.consecutivePrimarySuccesses=[int]$state.consecutivePrimarySuccesses+1
  $state.consecutivePrimaryFailures=0
}elseif($h3Failed){
  $state.consecutivePrimaryFailures=[int]$state.consecutivePrimaryFailures+1
  $state.consecutivePrimarySuccesses=0
}

# Invariant 1: while H3 is the active gateway host, ASUS must not poll Telegram.
if($state.activeHost -eq 'H3' -and [int]$asus.gatewayPidCount -gt 0){
  $stop=Invoke-UserGatewayAction 'stop'
  if($stop -and [bool]$stop.ok){
    $action='enforced-standby-stopped'
    Write-Log "ENFORCED_STANDBY_STOPPED asusPids=$([int]$asus.gatewayPidCount)"
    $state.asus.gatewayPidCount=0;$state.asus.gatewayPids=@();$state.asus.telegramEstablished=$false
  }else{
    $action='enforce-standby-stop-failed'
  }
}

# Promotion: H3 gateway failed repeatedly -> promote ASUS.
if($state.activeHost -eq 'H3' -and $h3Failed -and [int]$state.consecutivePrimaryFailures -ge $failThreshold){
  if([int]$asus.gatewayPidCount -eq 0){
    $start=Invoke-UserGatewayAction 'start'
    if($start -and [bool]$start.ok){
      $state.activeHost='ASUS'
      $state.lastPromotion=$now
      $state.reason=("promotion: " + [string]$h3.classification + " x" + [int]$state.consecutivePrimaryFailures + " sim=" + $simulated)
      $state.promotionCycle=0
      $state.assistsThisOutage=0
      $state.asus.gatewayPidCount=[int]$start.gatewayPidCount
      $state.asus.gatewayPids=@($start.gatewayPids)
      $state.asus.telegramEstablished=[bool]$start.telegramEstablished
      $action='PROMOTED'
      Write-Log ("PROMOTED activeHost=ASUS reason=" + $state.reason + " asusPids=" + [int]$start.gatewayPidCount + " telegramEstablished=" + [bool]$start.telegramEstablished)
    }else{
      $action='promotion-start-failed'
      Write-Log ("PROMOTION_START_FAILED reason=" + [string]$h3.classification + " result=" + $(if($start){[string]($start|ConvertTo-Json -Depth 4 -Compress)}else{'no-result'}))
    }
  }
}

# Re-start watchdog: promoted but the ASUS gateway died -> start it again.
if($state.activeHost -eq 'ASUS' -and [int]$asus.gatewayPidCount -eq 0){
  $state.promotionCycle=[int]$state.promotionCycle+1
  if([int]$state.promotionCycle -le 3){
    $start=Invoke-UserGatewayAction 'start'
    if($start -and [bool]$start.ok){
      $state.asus.gatewayPidCount=[int]$start.gatewayPidCount
      $state.asus.gatewayPids=@($start.gatewayPids)
      $state.asus.telegramEstablished=[bool]$start.telegramEstablished
      $action='promoted-restart'
      Write-Log "PROMOTED_RESTART asus gateway restarted"
    }else{
      $action='promoted-restart-failed'
    }
  }
}

# Demotion: H3 healthy again for N consecutive checks -> hand back.
# Stop-ASUS-first: a short deliberate handover gap is safer than any window with
# two Telegram pollers. If the post-stop H3 re-probe cannot confirm health, the
# next line restarts the ASUS gateway (fail-safe rollback).
if($state.activeHost -eq 'ASUS' -and $h3Healthy -and [int]$state.consecutivePrimarySuccesses -ge $successThreshold){
  $stop=Invoke-UserGatewayAction 'stop'
  if($stop -and [bool]$stop.ok){
    $state.asus.gatewayPidCount=0;$state.asus.gatewayPids=@();$state.asus.telegramEstablished=$false
    $h3StillHealthy=$true
    if(-not $simulated){
      $reprobe=Invoke-H3Probe
      if($reprobe){
        $state.h3=$reprobe
        $h3StillHealthy=([string]$reprobe.classification -eq 'h3GatewayHealthy')
      }
    }
    if($h3StillHealthy){
      $state.activeHost='H3'
      $state.lastDemotion=$now
      $state.reason=("demotion: h3 healthy x" + [int]$state.consecutivePrimarySuccesses)
      $state.consecutivePrimarySuccesses=0
      $action='DEMOTED'
      Write-Log "DEMOTED activeHost=H3 asus gateway stopped h3Healthy=True"
    }else{
      $rollback=Invoke-UserGatewayAction 'start'
      if($rollback -and [bool]$rollback.ok){
        $state.asus.gatewayPidCount=[int]$rollback.gatewayPidCount
        $state.asus.gatewayPids=@($rollback.gatewayPids)
        $state.asus.telegramEstablished=[bool]$rollback.telegramEstablished
      }
      $action='demotion-deferred-h3-unverified-rolled-back'
      Write-Log "DEMOTION_DEFERRED h3 unverified after stop; asus gateway restarted"
    }
  }else{
    $action='demotion-stop-failed'
    Write-Log "DEMOTION_STOP_FAILED asus gateway still running"
  }
}

# Assist: while ASUS is active and H3 host is fine but its gateway is down,
# start it over the existing ASUS->H3 SSH trust so recovery can complete.
if($state.activeHost -eq 'ASUS' -and ([string]$h3.classification -eq 'h3GatewayDown')){
  $lastAssist=$null
  try{$lastAssist=[datetime]::Parse([string]$state.lastAssistAt)}catch{}
  $cooldownOk=((-not $lastAssist) -or (((Get-Date)-$lastAssist).TotalSeconds -ge $startAssistCooldownSeconds))
  if($cooldownOk -and [int]$state.assistsThisOutage -lt $maxAssistsPerOutage){
    $lifecycleScript=@'
$ErrorActionPreference='Continue'
$root=Join-Path $env:LOCALAPPDATA 'hermes'
$env:HERMES_HOME=$root
$hermes=Join-Path $root 'bin\hermes.exe'
& $hermes gateway start *> $null
exit $LASTEXITCODE
'@
    $r=Invoke-RemoteScript ("Faiz@"+$h3Tailscale) @() $lifecycleScript 35000
    if(-not $r -or $r.timedOut -or ($r.exit -ne 0)){
      $r2=Invoke-RemoteScript 'Faiz@192.168.50.185' @('-o','HostKeyAlias=' + $h3Tailscale) $lifecycleScript 35000
      $r=$r2
    }
    $state.lastAssistAt=$now
    $state.assistsThisOutage=[int]$state.assistsThisOutage+1
    $assistOk=($r -and -not $r.timedOut -and $r.exit -eq 0)
    $action='h3-start-assist'
    Write-Log ("H3_START_ASSIST ok=" + $assistOk + " transportExit=" + $(if($r){[string]$r.exit}else{'null'}))
  }
}

if(-not $h3Failed -and $h3Healthy){
  $state.assistsThisOutage=0
}

Write-State $state
if($action -ne 'none'){Write-Log ("action=" + $action + " activeHost=" + $state.activeHost + " h3=" + [string]$h3.classification + " fails=" + [int]$state.consecutivePrimaryFailures + " succ=" + [int]$state.consecutivePrimarySuccesses + " sim=" + $simulated)}
exit 0
