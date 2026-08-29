#Requires -Version 5.1
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$ExpectedSha=''
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$statusFile=Join-Path $stateRoot 'last-update.json'
$started=Get-Date
$mutex=New-Object Threading.Mutex($false,'Global\AFZOpenAIAgentUpdater')
$locked=$false

function Write-TransportDiagnosticAck {
  param(
    [string]$RemoteSha,
    [string]$Expected,
    [string]$TriggerName,
    [string]$PushTaskState,
    [string]$SiteTaskState
  )
  # Emergency observability only. This file is never read as a command, request,
  # lease, approval, or deployment authority. Failure to write it never blocks GitHub.
  try {
    $diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $diag=[ordered]@{
      schema=1
      purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
      source='windows-main'
      controlPlane='github'
      component='AFZ OpenAI Agent Updater'
      remoteSha=$RemoteSha
      expectedSha=$(if($Expected){$Expected}else{$null})
      trigger=$TriggerName
      updaterTask='AFZ OpenAI Agent Updater'
      pushWatcherTask='AFZ OpenAI Agent Push Deploy Watcher'
      pushWatcherTaskState=$PushTaskState
      siteWatcherTask='AFZ Website Git Deploy Request Watcher'
      siteWatcherTaskState=$SiteTaskState
      time=(Get-Date -Format o)
    }
    $diag | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $diagRoot 'AFZ-GITHUB-TRANSPORT-ACK-LATEST.json') -Encoding UTF8
  } catch {}
}

try{
  $locked=$mutex.WaitOne([TimeSpan]::FromSeconds(60))
  if(-not $locked){throw 'Another AFZ updater instance remained active for more than 60 seconds'}

  if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
    $ExpectedSha=$ExpectedSha.Trim().ToLowerInvariant()
    if($ExpectedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}
  }

  # Always bootstrap the current sync helper so stale local source cannot pin updates.
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $tmpSync=Join-Path $env:TEMP ('Sync-AFZ-AgentFromGitHub-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $syncUri="https://raw.githubusercontent.com/f3arif/homelab-control/main/afz-openai-agent/Sync-AFZ-AgentFromGitHub.ps1?nocache=$nonce"
  $syncHeaders=@{'User-Agent'='AFZ-OpenAI-Agent-Updater';'Cache-Control'='no-cache';'Pragma'='no-cache'}
  Invoke-WebRequest -Uri $syncUri -Headers $syncHeaders -OutFile $tmpSync -UseBasicParsing -TimeoutSec 60
  try{
    $syncArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$tmpSync,'-InstallRoot',$InstallRoot)
    if($ExpectedSha){$syncArgs+=@('-ExpectedSha',$ExpectedSha)}
    $syncResult=& powershell.exe @syncArgs | Select-Object -Last 1
  }finally{Remove-Item -LiteralPath $tmpSync -Force -ErrorAction SilentlyContinue}
  if(-not $syncResult){throw 'Agent source sync returned no result'}
  if($syncResult -is [string]){try{$syncResult=$syncResult|ConvertFrom-Json}catch{}}
  $changed=[bool]$syncResult.changed
  $remoteSha=[string]$syncResult.remoteSha

  $allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
  $wrapper=Join-Path $InstallRoot 'afz-openai-agent\Start-AFZ-OpenAI-Agent.ps1'
  $control=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Agent-Control.ps1'
  $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
  $pushWatcher=Join-Path $InstallRoot 'afz-openai-agent\Push-Deploy-Watcher.ps1'
  $benchmarkRelay=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen27B-WebsiteBenchmark.ps1'
  $benchmarkRequestWatcher=Join-Path $InstallRoot 'afz-openai-agent\H3-Qwen27B-Request-Watcher.ps1'
  $siteDeployRequestWatcher=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Site-Deploy-Request-Watcher.ps1'
  $siteDeployExecutor=Join-Path $InstallRoot 'afz-openai-agent\Deploy-AFZ-WebsiteToPi.ps1'
  $familyPttEdgeWatcher=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Edge-Preflight-Watcher-R12.ps1'
  $prospectModule=Join-Path $InstallRoot 'afz-openai-agent\prospect-engine\ProspectEngine.ps1'
  $prospectUi=Join-Path $InstallRoot 'afz-openai-agent\prospect-engine\index.html'
  foreach($p in @($allowFile,$wrapper,$control,$updater,$pushWatcher,$benchmarkRelay,$benchmarkRequestWatcher,$siteDeployRequestWatcher,$siteDeployExecutor,$familyPttEdgeWatcher,$prospectModule,$prospectUi)){if(-not(Test-Path $p)){throw "Required agent file missing after sync: $p"}}

  $ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
  if($ips.Count -eq 0){throw 'No Tailscale client IPs configured'}

  $agentFw=Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue
  $controlFw=Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -ErrorAction SilentlyContinue
  if($changed -or -not $agentFw -or -not $controlFw){
    Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - HP Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8796 -RemoteAddress $ips -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8797 -RemoteAddress $ips -Profile Any | Out-Null
  }

  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $serviceSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

  $agentTaskName='AFZ OpenAI Agent'
  $agentAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -InstallRoot `"$InstallRoot`" -Port 8796 -BindHost `"100.70.25.8`""
  $agentTask=Get-ScheduledTask -TaskName $agentTaskName -ErrorAction SilentlyContinue
  if($agentTask){Set-ScheduledTask -TaskName $agentTaskName -Action $agentAction | Out-Null}else{Register-ScheduledTask -TaskName $agentTaskName -Action $agentAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $controlTaskName='AFZ OpenAI Agent Control'
  $controlAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$control`" -InstallRoot `"$InstallRoot`" -Port 8797 -BindHost `"100.70.25.8`""
  $controlTask=Get-ScheduledTask -TaskName $controlTaskName -ErrorAction SilentlyContinue
  if($controlTask){Set-ScheduledTask -TaskName $controlTaskName -Action $controlAction | Out-Null}else{Register-ScheduledTask -TaskName $controlTaskName -Action $controlAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  # Persistent secretless GitHub signal consumer. This used to exist only as a
  # hidden child of the API wrapper, so agent restarts could silently remove the
  # only fast-signal consumer. Give it an independent SYSTEM task lifecycle.
  $pushWatcherTaskName='AFZ OpenAI Agent Push Deploy Watcher'
  $pushWatcherAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$pushWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 3"
  $pushWatcherTask=Get-ScheduledTask -TaskName $pushWatcherTaskName -ErrorAction SilentlyContinue
  if($pushWatcherTask){Set-ScheduledTask -TaskName $pushWatcherTaskName -Action $pushWatcherAction | Out-Null}else{Register-ScheduledTask -TaskName $pushWatcherTaskName -Action $pushWatcherAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  # Secretless GitHub request consumer. It only reads fixed typed request files
  # from the exact-SHA synced source and can launch only fixed allowlisted relays.
  $benchmarkWatcherTaskName='AFZ H3 Qwen27B Request Watcher'
  $benchmarkWatcherAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$benchmarkRequestWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $benchmarkWatcherTask=Get-ScheduledTask -TaskName $benchmarkWatcherTaskName -ErrorAction SilentlyContinue
  if($benchmarkWatcherTask){Set-ScheduledTask -TaskName $benchmarkWatcherTaskName -Action $benchmarkWatcherAction | Out-Null}else{Register-ScheduledTask -TaskName $benchmarkWatcherTaskName -Action $benchmarkWatcherAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  # Fixed AFZ website Git->Pi cutover lane. The SYSTEM watcher never reads or moves
  # the Pi private key. It temporarily reuses a proven user-context carrier task,
  # restores that task's original action, and disables the old OneDrive sync only
  # after the Git deployment reports full success.
  $siteWatcherTaskName='AFZ Website Git Deploy Request Watcher'
  $siteWatcherAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$siteDeployRequestWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $siteWatcherTask=Get-ScheduledTask -TaskName $siteWatcherTaskName -ErrorAction SilentlyContinue
  if($siteWatcherTask){Set-ScheduledTask -TaskName $siteWatcherTaskName -Action $siteWatcherAction | Out-Null}else{Register-ScheduledTask -TaskName $siteWatcherTaskName -Action $siteWatcherAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  # FamilyPTT production-edge preflight watcher. Own this task directly from the
  # SYSTEM updater so R12 self-heals even if the API wrapper is already running.
  # Never forcibly restart a running R12 watcher because it may temporarily own the
  # AFZ Edge Backup carrier and is responsible for restoring that carrier safely.
  $familyPttEdgeTaskName='AFZ FamilyPTT Edge Preflight Watcher R12'
  $familyPttEdgeTaskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$familyPttEdgeWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $familyPttEdgeTask=Get-ScheduledTask -TaskName $familyPttEdgeTaskName -ErrorAction SilentlyContinue
  if($familyPttEdgeTask){Set-ScheduledTask -TaskName $familyPttEdgeTaskName -Action $familyPttEdgeTaskAction | Out-Null}else{Register-ScheduledTask -TaskName $familyPttEdgeTaskName -Action $familyPttEdgeTaskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  # The 3-second fast signal watcher is primary. This one-minute task is recovery-only.
  $updaterTaskName='AFZ OpenAI Agent Updater'
  $updaterAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallRoot `"$InstallRoot`""
  $updaterTrigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $updaterSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  $updaterTask=Get-ScheduledTask -TaskName $updaterTaskName -ErrorAction SilentlyContinue
  if($updaterTask){Set-ScheduledTask -TaskName $updaterTaskName -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings | Out-Null}else{Register-ScheduledTask -TaskName $updaterTaskName -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings -Principal $principal -Force | Out-Null}

  function Ensure-Running([string]$taskName,[bool]$restart){
    $t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if(-not $t){return}
    if($restart){try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{};Start-Sleep -Milliseconds 700;Start-ScheduledTask -TaskName $taskName}
    elseif($t.State -ne 'Running'){Start-ScheduledTask -TaskName $taskName}
  }
  Ensure-Running $agentTaskName $changed
  Ensure-Running $controlTaskName $changed
  # Never forcibly restart the push watcher from inside an update it may have
  # initiated. If absent or stopped, start it; otherwise leave the live loop alone.
  Ensure-Running $pushWatcherTaskName $false
  Ensure-Running $benchmarkWatcherTaskName $changed
  Ensure-Running $siteWatcherTaskName $changed
  Ensure-Running $familyPttEdgeTaskName $false

  $trigger=$(if($ExpectedSha){'fast-signal-exact-sha'}else{'fallback-poll'})
  $pushTaskState=[string](Get-ScheduledTask -TaskName $pushWatcherTaskName -ErrorAction SilentlyContinue).State
  $siteTaskState=[string](Get-ScheduledTask -TaskName $siteWatcherTaskName -ErrorAction SilentlyContinue).State
  $familyPttEdgeTaskState=[string](Get-ScheduledTask -TaskName $familyPttEdgeTaskName -ErrorAction SilentlyContinue).State
  Write-TransportDiagnosticAck $remoteSha $ExpectedSha $trigger $pushTaskState $siteTaskState

  $result=[ordered]@{ok=$true;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o);remoteSha=$remoteSha;expectedSha=$(if($ExpectedSha){$ExpectedSha}else{$null});trigger=$trigger;changed=$changed;fastSignalIntervalSeconds=3;fallbackCadenceSeconds=60;agentPort=8796;controlPort=8797;pushDeployWatcherTask=$pushWatcherTaskName;pushDeployWatcherState=$pushTaskState;benchmarkRequestWatcherTask=$benchmarkWatcherTaskName;siteDeployRequestWatcherTask=$siteWatcherTaskName;siteDeployRequestWatcherState=$siteTaskState;familyPttEdgePreflightWatcherTask=$familyPttEdgeTaskName;familyPttEdgePreflightWatcherState=$familyPttEdgeTaskState;diagnosticAck='OneDrive emergency observability only';clients=$ips;transport=[string]$syncResult.refTransport}
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusFile -Encoding UTF8
} catch {
  $result=[ordered]@{ok=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o);expectedSha=$(if($ExpectedSha){$ExpectedSha}else{$null});error=$_.Exception.Message}
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusFile -Encoding UTF8
  throw
} finally {
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
