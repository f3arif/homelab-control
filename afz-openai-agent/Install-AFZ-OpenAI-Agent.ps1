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
$wrapper=Join-Path $InstallRoot 'afz-openai-agent\Start-AFZ-OpenAI-Agent.ps1'
if(-not(Test-Path $wrapper)){throw "Agent wrapper not found after pull: $wrapper"}

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

$taskName='AFZ OpenAI Agent'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -InstallRoot `"$InstallRoot`" -Port $Port -BindHost `"$BindHost`""
$trigger=New-ScheduledTaskTrigger -AtStartup
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

$update=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
$uAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$update`" -InstallRoot `"$InstallRoot`""
$uTrigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Minutes 15)
$uSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'AFZ OpenAI Agent Updater' -Action $uAction -Trigger $uTrigger -Settings $uSettings -Principal $principal -Force | Out-Null

$allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
$ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
if($ips.Count -eq 0){throw 'No Tailscale clients configured'}
Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - HP Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $ips -Profile Any | Out-Null

$shortcutPath=Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'AFZ OpenAI Agent.url'
@("[InternetShortcut]","URL=http://127.0.0.1:$Port/","IconFile=%SystemRoot%\System32\shell32.dll","IconIndex=14") | Set-Content -LiteralPath $shortcutPath -Encoding ASCII

Start-ScheduledTask -TaskName $taskName
Start-Sleep 3
try{
  $h=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 10
  Write-Host "AFZ OpenAI Agent installed and healthy: $($h.version) / $($h.mode)" -ForegroundColor Green
  Write-Host "UI: http://127.0.0.1:$Port/"
  Write-Host "Tailscale UI/API: http://$BindHost`:$Port/"
  Write-Host ('Allowed Tailscale peers: '+($ips -join ', '))
  Write-Host 'Future code/access-policy updates will pull from GitHub main automatically every 15 minutes.'
  if($RunJellyfinDiagnosis){
    $diag=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Jellyfin-Diagnosis.ps1'
    if(Test-Path $diag){
      Write-Host ''
      Write-Host 'Running the Jellyfin/TorBox diagnosis through the new OpenAI typed-tool loop...' -ForegroundColor Cyan
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $diag -Port $Port
    }else{Write-Warning "Diagnosis launcher missing: $diag"}
  }
  Start-Process "http://127.0.0.1:$Port/"
}catch{
  Write-Warning "Task installed but health check failed: $($_.Exception.Message)"
  Write-Host 'Check C:\ProgramData\AFZ\OpenAIAgent\logs\agent.log'
}
