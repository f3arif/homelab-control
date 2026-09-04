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
$taskName='AFZ H3 Hermes Headless Gateway'
$root='C:\ProgramData\AFZ\H3Headless'
$runnerSource=Join-Path $InstallRoot 'afz-openai-agent\h3-headless\Run-H3-Hermes-Headless.ps1'
$runnerInstalled=Join-Path $root 'Run-H3-Hermes-Headless.ps1'
$stateFile=Join-Path $root 'hermes-headless-install-state.json'
$backupTask=Join-Path $root 'hermes-headless-task-before.xml'
$hermes='C:\Users\Faiz\AppData\Local\hermes\bin\hermes.exe'
$jobs='C:\Users\Faiz\AppData\Local\hermes\cron\jobs.json'
$utf8=New-Object Text.UTF8Encoding($false)

function Save-State($o){
  New-Item -ItemType Directory -Force -Path $root|Out-Null
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 10),$utf8)
  Write-Output ($o|ConvertTo-Json -Depth 10 -Compress)
}

$actualHost=[Environment]::MachineName
if($actualHost -ne $expectedHost){
  Save-State ([ordered]@{ok=$false;classification='WRONG_HOST';mode=$Mode;actualHost=$actualHost;expectedHost=$expectedHost;time=(Get-Date -Format o)})
  exit 20
}

function Current-State {
  $t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $cronStatus=''
  if(Test-Path -LiteralPath $hermes -PathType Leaf){
    try{$cronStatus=(& $hermes cron status 2>&1|Out-String)}catch{}
  }
  [ordered]@{
    taskPresent=[bool]$t
    taskState=$(if($t){[string]$t.State}else{$null})
    taskUser=$(if($t){[string]$t.Principal.UserId}else{$null})
    taskLogonType=$(if($t){[string]$t.Principal.LogonType}else{$null})
    cronGatewayHealthy=($cronStatus -match 'Gateway is running')
    runnerPresent=(Test-Path -LiteralPath $runnerInstalled -PathType Leaf)
  }
}

if($Mode -eq 'Audit'){
  Save-State ([ordered]@{ok=$true;classification='AUDIT_ONLY';mode=$Mode;state=Current-State;mutationStarted=$false;time=(Get-Date -Format o)})
  exit 0
}

if($Mode -eq 'Rollback'){
  try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
  try{Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}catch{}
  Save-State ([ordered]@{ok=$true;classification='H3_HERMES_HEADLESS_ROLLED_BACK';mode=$Mode;state=Current-State;time=(Get-Date -Format o)})
  exit 0
}

if(-not(Test-Path -LiteralPath $runnerSource -PathType Leaf)){throw "Runner missing: $runnerSource"}
if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){throw "Hermes launcher missing: $hermes"}
if(-not(Test-Path -LiteralPath $jobs -PathType Leaf)){throw "Hermes cron store missing: $jobs"}

$auth=(& $hermes auth status openai-codex 2>&1|Out-String)
if($auth -notmatch 'logged in'){throw 'OpenAI Codex OAuth is not logged in in the shared H3 Hermes profile.'}
$jobDoc=Get-Content -LiteralPath $jobs -Raw|ConvertFrom-Json
$rh=@($jobDoc.jobs|Where-Object{$_.id -eq '9d9eea1b7618'})|Select-Object -First 1
if(-not $rh){throw 'RadioHilal cron job 9d9eea1b7618 is missing from the shared H3 Hermes profile.'}

New-Item -ItemType Directory -Force -Path $root|Out-Null
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){
  Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath $backupTask -Encoding UTF8
}
Copy-Item -LiteralPath $runnerSource -Destination $runnerInstalled -Force

$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$runnerInstalled+'"')
$trigger=New-ScheduledTaskTrigger -AtStartup
$trigger.Delay='PT60S'
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 50 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $taskName

Start-Sleep -Seconds 2
$t=Get-ScheduledTask -TaskName $taskName
if([string]$t.Principal.UserId -ne 'SYSTEM' -or [string]$t.Principal.LogonType -ne 'ServiceAccount'){
  throw 'Headless Hermes task principal validation failed.'
}

Save-State ([ordered]@{
  ok=$true
  classification='H3_HERMES_HEADLESS_INSTALLED'
  mode=$Mode
  task=$taskName
  taskState=[string]$t.State
  taskUser=[string]$t.Principal.UserId
  taskLogonType=[string]$t.Principal.LogonType
  trigger=[string](@($t.Triggers)[0].CimClass.CimClassName)
  radioHilalCronVisible=$true
  radioHilalSchedule=[string]$rh.schedule_display
  radioHilalProvider=[string]$rh.provider
  radioHilalModel=[string]$rh.model
  radioHilalReasoning=[string]$rh.reasoning_effort
  loginRequired=$false
  time=(Get-Date -Format o)
})
exit 0
