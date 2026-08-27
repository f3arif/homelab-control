#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$Port=8796,
  [string]$BindHost='100.70.25.8',
  [switch]$RunJellyfinDiagnosis
)
$ErrorActionPreference='Stop'
$repo='https://github.com/f3arif/homelab-control.git'
$state='C:\ProgramData\AFZ\OpenAIAgent'
$keyFile=Join-Path $state 'openai-key.dpapi'
New-Item -ItemType Directory -Force -Path $state | Out-Null

function Save-Key([string]$key){
  $bytes=[Text.Encoding]::UTF8.GetBytes($key)
  $protected=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
  [IO.File]::WriteAllBytes($keyFile,$protected)
  & icacls.exe $keyFile /inheritance:r /grant:r 'SYSTEM:F' 'Administrators:F' | Out-Null
}

$git=(Get-Command git.exe -ErrorAction Stop).Source
if(Test-Path (Join-Path $InstallRoot '.git')){
  & $git -C $InstallRoot fetch origin main
  & $git -C $InstallRoot checkout main
  & $git -C $InstallRoot pull --ff-only origin main
}else{
  if(Test-Path $InstallRoot){
    if(@(Get-ChildItem $InstallRoot -Force -ErrorAction SilentlyContinue).Count -gt 0){throw "$InstallRoot exists and is not an empty git checkout"}
  }else{New-Item -ItemType Directory -Force -Path (Split-Path $InstallRoot -Parent)|Out-Null}
  & $git clone $repo $InstallRoot
}

$agent=Join-Path $InstallRoot 'afz-openai-agent\AFZ-OpenAI-Agent-v2.ps1'
$wrapper=Join-Path $InstallRoot 'afz-openai-agent\Start-AFZ-OpenAI-Agent.ps1'
$control=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Agent-Control.ps1'
$update=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
foreach($p in @($agent,$wrapper,$control,$update,$allowFile)){if(-not(Test-Path $p)){throw "Required AFZ agent file missing: $p"}}

if(-not(Test-Path $keyFile)){
  $existing=[Environment]::GetEnvironmentVariable('OPENAI_API_KEY','Machine')
  if(-not $existing){$existing=[Environment]::GetEnvironmentVariable('OPENAI_API_KEY','User')}
  if(-not $existing){$existing=$env:OPENAI_API_KEY}
  if($existing){Save-Key $existing}
  else{
    Write-Host 'One-time setup: enter the OpenAI API key. It will be encrypted with Windows DPAPI (LocalMachine); plaintext is not written to disk.' -ForegroundColor Yellow
    $sec=Read-Host 'OpenAI API key' -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try{
      $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
      if(-not $plain){throw 'Empty API key'}
      Save-Key $plain
    }finally{
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
      $plain=$null
    }
  }
}

$ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
if($ips.Count -eq 0){throw 'No Tailscale clients configured in allowed-clients.txt'}

$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$serviceSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

$agentTask='AFZ OpenAI Agent'
$agentAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -InstallRoot `"$InstallRoot`" -Port $Port -BindHost `"$BindHost`""
Register-ScheduledTask -TaskName $agentTask -Action $agentAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null

$controlTask='AFZ OpenAI Agent Control'
$controlAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$control`" -InstallRoot `"$InstallRoot`" -Port 8797 -BindHost `"$BindHost`""
Register-ScheduledTask -TaskName $controlTask -Action $controlAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null

$updaterTask='AFZ OpenAI Agent Updater'
$updaterAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$update`" -InstallRoot `"$InstallRoot`""
$updaterTrigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
$updaterSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $updaterTask -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings -Principal $principal -Force | Out-Null

Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - HP Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $ips -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8797 -RemoteAddress $ips -Profile Any | Out-Null

$shortcutPath=Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'AFZ OpenAI Agent.url'
@("[InternetShortcut]","URL=http://127.0.0.1:$Port/","IconFile=%SystemRoot%\System32\shell32.dll","IconIndex=14") | Set-Content -LiteralPath $shortcutPath -Encoding ASCII
$controlShortcut=Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'AFZ Agent Update.url'
@("[InternetShortcut]","URL=http://127.0.0.1:8797/","IconFile=%SystemRoot%\System32\shell32.dll","IconIndex=238") | Set-Content -LiteralPath $controlShortcut -Encoding ASCII

Start-ScheduledTask -TaskName $agentTask
Start-ScheduledTask -TaskName $controlTask
Start-Sleep 3
try{
  $h=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 10
  $c=Invoke-RestMethod -Uri 'http://127.0.0.1:8797/health' -TimeoutSec 10
  Write-Host "AFZ OpenAI Agent healthy: $($h.version) / $($h.mode)" -ForegroundColor Green
  Write-Host "Agent UI: http://127.0.0.1:$Port/"
  Write-Host 'Update control: http://127.0.0.1:8797/'
  Write-Host "Tailnet agent: http://$BindHost`:$Port/"
  Write-Host "Tailnet update control: http://$BindHost`:8797/"
  Write-Host 'GitHub fallback updater cadence: 1 minute.'
  if($RunJellyfinDiagnosis){
    $diag=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Jellyfin-Diagnosis.ps1'
    if(Test-Path $diag){
      Write-Host 'Running Jellyfin/TorBox diagnosis through the OpenAI typed-tool loop...' -ForegroundColor Cyan
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diag -Port $Port
    }
  }
  Start-Process "http://127.0.0.1:$Port/"
}catch{
  Write-Warning "Tasks installed but health check failed: $($_.Exception.Message)"
  Write-Host 'Check C:\ProgramData\AFZ\OpenAIAgent\logs'
}
