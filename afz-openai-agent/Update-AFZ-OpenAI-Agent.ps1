#Requires -Version 5.1
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$git=(Get-Command git.exe -ErrorAction Stop).Source
if(-not(Test-Path (Join-Path $InstallRoot '.git'))){throw 'AFZ homelab-control checkout missing'}

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$statusFile=Join-Path $stateRoot 'last-update.json'
$started=Get-Date

# Clean only the legacy generated mutation from the original updater design.
& $git -C $InstallRoot checkout -- 'afz-openai-agent/AFZ-OpenAI-Agent-v2.ps1' 2>$null
$before=(& $git -C $InstallRoot rev-parse HEAD).Trim()
& $git -C $InstallRoot fetch origin main | Out-Null
& $git -C $InstallRoot checkout main | Out-Null
& $git -C $InstallRoot pull --ff-only origin main | Out-Null
$after=(& $git -C $InstallRoot rev-parse HEAD).Trim()
$changed=($before -ne $after)

$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$wrapper=Join-Path $InstallRoot 'afz-openai-agent\Start-AFZ-OpenAI-Agent.ps1'
$control=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Agent-Control.ps1'
$updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
if(-not(Test-Path $wrapper)){throw "Agent wrapper missing: $wrapper"}
if(-not(Test-Path $control)){throw "Agent control missing: $control"}

$ips=@()
if(Test-Path $allowFile){
  $ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
}
if($ips.Count -eq 0){throw 'No Tailscale client IPs configured'}

# Firewall is tailnet-IP restricted. Rebuild after a code/policy pull or when missing.
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

# Main OpenAI agent.
$agentTaskName='AFZ OpenAI Agent'
$agentAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -InstallRoot `"$InstallRoot`" -Port 8796 -BindHost `"100.70.25.8`""
$agentTask=Get-ScheduledTask -TaskName $agentTaskName -ErrorAction SilentlyContinue
if($agentTask){Set-ScheduledTask -TaskName $agentTaskName -Action $agentAction | Out-Null}
else{
  Register-ScheduledTask -TaskName $agentTaskName -Action $agentAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null
  $changed=$true
}

# Separate control plane survives agent restarts and can trigger this updater immediately.
$controlTaskName='AFZ OpenAI Agent Control'
$controlAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$control`" -InstallRoot `"$InstallRoot`" -Port 8797 -BindHost `"100.70.25.8`""
$controlTask=Get-ScheduledTask -TaskName $controlTaskName -ErrorAction SilentlyContinue
if($controlTask){Set-ScheduledTask -TaskName $controlTaskName -Action $controlAction | Out-Null}
else{
  Register-ScheduledTask -TaskName $controlTaskName -Action $controlAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null
  $changed=$true
}

# Reconfigure updater itself to a one-minute fallback. On-demand requests use the control service instead.
$updaterTaskName='AFZ OpenAI Agent Updater'
$updaterAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallRoot `"$InstallRoot`""
$updaterTrigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
$updaterSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$updaterTask=Get-ScheduledTask -TaskName $updaterTaskName -ErrorAction SilentlyContinue
if($updaterTask){
  Set-ScheduledTask -TaskName $updaterTaskName -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings | Out-Null
}else{
  Register-ScheduledTask -TaskName $updaterTaskName -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings -Principal $principal -Force | Out-Null
}

function Ensure-Running([string]$taskName,[bool]$restart){
  $t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if(-not $t){return}
  if($restart){
    try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
    Start-Sleep -Milliseconds 700
    Start-ScheduledTask -TaskName $taskName
  }elseif($t.State -ne 'Running'){
    Start-ScheduledTask -TaskName $taskName
  }
}

Ensure-Running $agentTaskName $changed
Ensure-Running $controlTaskName $changed

$result=[ordered]@{
  ok=$true
  startedAt=$started.ToString('o')
  finishedAt=(Get-Date -Format o)
  before=$before
  after=$after
  changed=$changed
  updaterCadenceSeconds=60
  agentPort=8796
  controlPort=8797
  clients=$ips
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding UTF8
