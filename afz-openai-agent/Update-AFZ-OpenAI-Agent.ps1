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
  foreach($p in @($allowFile,$wrapper,$control,$updater)){if(-not(Test-Path $p)){throw "Required agent file missing after sync: $p"}}

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

  $trigger=$(if($ExpectedSha){'fast-signal-exact-sha'}else{'fallback-poll'})
  $result=[ordered]@{ok=$true;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o);remoteSha=$remoteSha;expectedSha=$(if($ExpectedSha){$ExpectedSha}else{$null});trigger=$trigger;changed=$changed;fastSignalIntervalSeconds=3;fallbackCadenceSeconds=60;agentPort=8796;controlPort=8797;clients=$ips;transport=[string]$syncResult.refTransport}
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusFile -Encoding UTF8
} catch {
  $result=[ordered]@{ok=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o);expectedSha=$(if($ExpectedSha){$ExpectedSha}else{$null});error=$_.Exception.Message}
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusFile -Encoding UTF8
  throw
} finally {
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
