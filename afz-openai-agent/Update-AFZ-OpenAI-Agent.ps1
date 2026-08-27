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

$agent=Join-Path $InstallRoot 'afz-openai-agent\AFZ-OpenAI-Agent-v2.ps1'
$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$accessChanged=$false

if((Test-Path $agent) -and (Test-Path $allowFile)){
  $ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
  if($ips.Count -gt 0){
    $agentText=Get-Content -LiteralPath $agent -Raw
    $vals=@('127.0.0.1','::1') + $ips
    $replacement='$AllowedClients = @(' + (($vals | ForEach-Object {"'$_'"}) -join ',') + ')'
    $patched=[regex]::Replace($agentText,'(?m)^\$AllowedClients\s*=\s*@\([^\r\n]*\)\s*$',[System.Text.RegularExpressions.MatchEvaluator]{param($m) $replacement},1)
    if($patched -ne $agentText){
      Set-Content -LiteralPath $agent -Value $patched -Encoding UTF8
      $accessChanged=$true
    }

    try{
      Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
      Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - HP Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
      New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8796 -RemoteAddress $ips -Profile Any | Out-Null
      $accessChanged=$true
    }catch{}
  }
}

if(($before -ne $after) -or $accessChanged){
  try{Stop-ScheduledTask -TaskName 'AFZ OpenAI Agent' -ErrorAction SilentlyContinue}catch{}
  Start-Sleep 1
  Start-ScheduledTask -TaskName 'AFZ OpenAI Agent'
}
