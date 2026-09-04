#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('Audit','Activate','Rollback')]
  [string]$Mode='Audit',
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-H3R6CQN'
$taskName='AFZ H3 Headless Ollama'
$stateRoot='C:\ProgramData\AFZ\H3Headless'
$stateFile=Join-Path $stateRoot 'phase1-state.json'
$backupRoot=Join-Path $stateRoot 'backup'
$runnerSource=Join-Path $InstallRoot 'afz-openai-agent\h3-headless\Run-H3-Ollama-Headless.ps1'
$runnerInstalled=Join-Path $stateRoot 'Run-H3-Ollama-Headless.ps1'
$utf8=New-Object Text.UTF8Encoding($false)

function Save-State($o){
  New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 12),$utf8)
  Write-Output ($o|ConvertTo-Json -Depth 12 -Compress)
}

function Get-OllamaExe {
  foreach($p in @(
    'C:\Users\Faiz\AppData\Local\Programs\Ollama\ollama.exe',
    'C:\Program Files\Ollama\ollama.exe'
  )){
    if(Test-Path -LiteralPath $p -PathType Leaf){return $p}
  }
  return $null
}

function Get-CurrentState {
  $svc=Get-Service sshd -ErrorAction SilentlyContinue
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $ollama=$null
  try{$ollama=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 4}catch{}
  [ordered]@{
    host=$env:COMPUTERNAME
    sshdPresent=[bool]$svc
    sshdStatus=$(if($svc){[string]$svc.Status}else{$null})
    sshdStartType=$(if($svc){[string](Get-CimInstance Win32_Service -Filter "Name='sshd'").StartMode}else{$null})
    headlessOllamaTaskPresent=[bool]$task
    headlessOllamaTaskState=$(if($task){[string]$task.State}else{$null})
    ollamaExe=Get-OllamaExe
    ollamaReachable=[bool]$ollama
    modelCount=$(if($ollama){@($ollama.models).Count}else{0})
    stateFile=$stateFile
  }
}

if($env:COMPUTERNAME -ne $expectedHost){
  Save-State ([ordered]@{schema=1;ok=$false;classification='WRONG_HOST';mode=$Mode;actualHost=$env:COMPUTERNAME;expectedHost=$expectedHost;time=(Get-Date -Format o)})
  exit 20
}

if($Mode -eq 'Audit'){
  Save-State ([ordered]@{schema=1;ok=$true;classification='AUDIT_ONLY';mode=$Mode;state=Get-CurrentState;mutationStarted=$false;time=(Get-Date -Format o)})
  exit 0
}

if($Mode -eq 'Rollback'){
  try{Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}catch{}
  $backup=Join-Path $backupRoot 'sshd-startmode.txt'
  if(Test-Path -LiteralPath $backup){
    $old=(Get-Content -LiteralPath $backup -Raw).Trim()
    if($old -eq 'Auto'){Set-Service sshd -StartupType Automatic}
    elseif($old -eq 'Manual'){Set-Service sshd -StartupType Manual}
    elseif($old -eq 'Disabled'){Set-Service sshd -StartupType Disabled}
  }
  Save-State ([ordered]@{schema=1;ok=$true;classification='ROLLED_BACK';mode=$Mode;state=Get-CurrentState;time=(Get-Date -Format o)})
  exit 0
}

# Activation is intentionally explicit and fail-closed.
$svc=Get-Service sshd -ErrorAction SilentlyContinue
if(-not $svc){throw 'OpenSSH Server service sshd is not installed on H3.'}
$ollamaExe=Get-OllamaExe
if(-not $ollamaExe){throw 'Ollama executable was not found on H3.'}
if(-not(Test-Path -LiteralPath 'C:\Users\Faiz\.ollama\models' -PathType Container)){
  throw 'Existing Faiz Ollama model store was not found.'
}
if(-not(Test-Path -LiteralPath $runnerSource -PathType Leaf)){throw "Runner missing: $runnerSource"}

New-Item -ItemType Directory -Force -Path $stateRoot,$backupRoot | Out-Null
$serviceInfo=Get-CimInstance Win32_Service -Filter "Name='sshd'"
[IO.File]::WriteAllText((Join-Path $backupRoot 'sshd-startmode.txt'),([string]$serviceInfo.StartMode),$utf8)
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){
  Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $backupRoot 'AFZ-H3-Headless-Ollama.xml') -Encoding UTF8
}
Copy-Item -LiteralPath $runnerSource -Destination $runnerInstalled -Force

try{
  Set-Service sshd -StartupType Automatic
  if((Get-Service sshd).Status -ne 'Running'){Start-Service sshd}

  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$runnerInstalled+'"')
  $trigger=New-ScheduledTaskTrigger -AtStartup
  $trigger.Delay='PT30S'
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName

  $sshOk=$false
  for($i=0;$i -lt 10;$i++){
    Start-Sleep -Seconds 1
    try{$sshOk=[bool](Test-NetConnection -ComputerName '127.0.0.1' -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)}catch{}
    if($sshOk){break}
  }

  $ollamaOk=$false;$models=0
  for($i=0;$i -lt 30;$i++){
    Start-Sleep -Seconds 1
    try{$tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3;$ollamaOk=$true;$models=@($tags.models).Count;break}catch{}
  }

  if(-not $sshOk -or -not $ollamaOk){
    throw "Headless validation failed. ssh=$sshOk ollama=$ollamaOk models=$models"
  }

  Save-State ([ordered]@{
    schema=1;ok=$true;classification='H3_HEADLESS_PHASE1_ACTIVE';mode=$Mode
    sshdAutomatic=$true;sshLoopback22=$sshOk
    ollamaTask=$taskName;ollamaSystemPrincipal=$true;ollamaReachable=$ollamaOk;modelCount=$models
    userLoginRequiredForPhase1=$false
    oldInteractiveTasksChanged=$false
    hermesChanged=$false
    radioHilalWorkerChanged=$false
    time=(Get-Date -Format o)
  })
  exit 0
}catch{
  try{Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}catch{}
  try{
    $old=(Get-Content -LiteralPath (Join-Path $backupRoot 'sshd-startmode.txt') -Raw).Trim()
    if($old -eq 'Auto'){Set-Service sshd -StartupType Automatic}
    elseif($old -eq 'Manual'){Set-Service sshd -StartupType Manual}
    elseif($old -eq 'Disabled'){Set-Service sshd -StartupType Disabled}
  }catch{}
  Save-State ([ordered]@{schema=1;ok=$false;classification='H3_HEADLESS_PHASE1_FAILED_ROLLED_BACK';mode=$Mode;error=$_.Exception.Message;time=(Get-Date -Format o)})
  exit 30
}
