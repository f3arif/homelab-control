#Requires -Version 5.1
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$git=(Get-Command git.exe -ErrorAction Stop).Source
if(-not(Test-Path (Join-Path $InstallRoot '.git'))){throw 'AFZ homelab-control checkout missing'}

$before=(& $git -C $InstallRoot rev-parse HEAD).Trim()
& $git -C $InstallRoot fetch origin main | Out-Null
& $git -C $InstallRoot checkout main | Out-Null
& $git -C $InstallRoot pull --ff-only origin main | Out-Null
$after=(& $git -C $InstallRoot rev-parse HEAD).Trim()

$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$wrapper=Join-Path $InstallRoot 'afz-openai-agent\Start-AFZ-OpenAI-Agent.ps1'
if(-not(Test-Path $wrapper)){throw "Agent wrapper missing: $wrapper"}
$ips=@()
if(Test-Path $allowFile){
  $ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
}
if($ips.Count -eq 0){throw 'No Tailscale client IPs configured'}

# Keep Windows Firewall closed except for explicitly allowlisted Tailscale peers.
Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - HP Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8796 -RemoteAddress $ips -Profile Any | Out-Null

# Ensure the service task always launches the runtime wrapper, which injects the current allowlist into a disposable copy.
$taskName='AFZ OpenAI Agent'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -InstallRoot `"$InstallRoot`" -Port 8796 -BindHost `"100.70.25.8`""
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($task){
  Set-ScheduledTask -TaskName $taskName -Action $action | Out-Null
}else{
  $trigger=New-ScheduledTaskTrigger -AtStartup
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
Start-Sleep 1
Start-ScheduledTask -TaskName $taskName
