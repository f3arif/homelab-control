#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
if($env:COMPUTERNAME -ne $expectedHost){throw "Project execution router installer wrong host: $env:COMPUTERNAME"}

$sourceRoot=Join-Path $InstallRoot 'afz-openai-agent'
$watcher=Join-Path $sourceRoot 'AFZ-ProjectTask-Request-Watcher.ps1'
$executor=Join-Path $sourceRoot 'Invoke-AFZ-HermesProjectTask.ps1'
$selfHeal=Join-Path $sourceRoot 'Watch-AFZ-ProjectExecutionRouter.ps1'
$router=Join-Path $sourceRoot 'control\project-execution-router.json'
$stateRoot='C:\ProgramData\AFZ\ProjectExecution'
$installState=Join-Path $stateRoot 'install.json'
$watcherTask='AFZ Project Task Router Watcher'
$userTask='AFZ Hermes Project Task User Action'
$selfHealTask='AFZ Project Task Router Self Heal'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-State($Object){try{[IO.File]::WriteAllText($installState,($Object|ConvertTo-Json -Depth 12),$utf8)}catch{}}

try{
  foreach($p in @($watcher,$executor,$selfHeal,$router)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required router source missing: $p"}}
  foreach($p in @($watcher,$executor,$selfHeal)){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "PowerShell parser rejected $p`: "+(($errors|ForEach-Object{$_.Message}) -join '; ')}
  }
  $cfg=Get-Content -LiteralPath $router -Raw -Encoding UTF8|ConvertFrom-Json
  if([int]$cfg.schema -ne 1 -or [string]$cfg.status -ne 'ACTIVE' -or [string]$cfg.default_route -notin @('hermes','commander')){throw 'Project execution router JSON contract invalid.'}
  if([bool]$cfg.safety.arbitrary_shell_request_field_allowed -or [bool]$cfg.safety.hermes_yolo_allowed -or -not [bool]$cfg.safety.require_checkpoints){throw 'Project execution router safety contract invalid.'}

  # SYSTEM watcher owns request dispatch/state. Polling is sub-second but local-only,
  # so it adds no OneDrive/network polling load. Both boot and later logon re-arm it.
  $watchAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$watcher`" -InstallRoot `"$InstallRoot`" -IntervalMilliseconds 750"
  $watchPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $watchSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Seconds 10) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  $watchTriggers=@(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn)
  )
  $existing=Get-ScheduledTask -TaskName $watcherTask -ErrorAction SilentlyContinue
  if($existing){Set-ScheduledTask -TaskName $watcherTask -Action $watchAction -Trigger $watchTriggers -Settings $watchSettings -Principal $watchPrincipal | Out-Null;$watchActionState='updated'}
  else{Register-ScheduledTask -TaskName $watcherTask -Action $watchAction -Trigger $watchTriggers -Settings $watchSettings -Principal $watchPrincipal -Force | Out-Null;$watchActionState='registered'}

  # Hermes must run in the user's context so its configured providers, profiles,
  # skills, checkpoints, and file-tool policy are available. S4U matches the
  # already-proven Hermes gateway user-action pattern and stores no password.
  $userAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$executor`" -InstallRoot `"$InstallRoot`""
  $userPrincipal=New-ScheduledTaskPrincipal -UserId 'FAIZ\DESIGN' -LogonType S4U -RunLevel Limited
  $userSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
  $existingUser=Get-ScheduledTask -TaskName $userTask -ErrorAction SilentlyContinue
  if($existingUser){Set-ScheduledTask -TaskName $userTask -Action $userAction -Settings $userSettings -Principal $userPrincipal | Out-Null;$userActionState='updated'}
  else{Register-ScheduledTask -TaskName $userTask -Action $userAction -Settings $userSettings -Principal $userPrincipal -Force | Out-Null;$userActionState='registered'}

  # Independent one-shot watchdog. It never reruns Hermes and never touches Commander;
  # it only re-arms the SYSTEM request watcher if that bounded watcher stopped. A
  # minute repetition means a later task exit does not require inbound connectivity.
  $healAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$selfHeal`" -InstallRoot `"$InstallRoot`""
  $healPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $healSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
  $healTrigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
  $existingHeal=Get-ScheduledTask -TaskName $selfHealTask -ErrorAction SilentlyContinue
  if($existingHeal){Set-ScheduledTask -TaskName $selfHealTask -Action $healAction -Trigger $healTrigger -Settings $healSettings -Principal $healPrincipal | Out-Null;$selfHealActionState='updated'}
  else{Register-ScheduledTask -TaskName $selfHealTask -Action $healAction -Trigger $healTrigger -Settings $healSettings -Principal $healPrincipal -Force | Out-Null;$selfHealActionState='registered'}

  # Allow only the Hermes user task to exchange pending/result envelopes with the
  # SYSTEM watcher. This directory contains task text/state only, never secrets.
  try{
    $acl=Get-Acl -LiteralPath $stateRoot
    $rule=New-Object Security.AccessControl.FileSystemAccessRule('FAIZ\DESIGN','Modify','ObjectInherit,ContainerInherit','None','Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $stateRoot -AclObject $acl
  }catch{}

  $watch=Get-ScheduledTask -TaskName $watcherTask -ErrorAction Stop
  if($watch.State -eq 'Running'){
    $latest='C:\ProgramData\AFZ\ProjectExecution\latest.json';$busy=$false
    if(Test-Path -LiteralPath $latest -PathType Leaf){try{$s=Get-Content -LiteralPath $latest -Raw|ConvertFrom-Json;$busy=([string]$s.status -in @('dispatched','running'))}catch{}}
    if(-not $busy){Stop-ScheduledTask -TaskName $watcherTask -ErrorAction SilentlyContinue;Start-Sleep -Milliseconds 250;Start-ScheduledTask -TaskName $watcherTask}
  }else{Start-ScheduledTask -TaskName $watcherTask}

  # Run the one-shot watchdog once immediately; subsequent invocations are scheduled.
  Start-ScheduledTask -TaskName $selfHealTask -ErrorAction SilentlyContinue

  $state=[ordered]@{schema=1;ok=$true;classification='PROJECT_EXECUTION_ROUTER_INSTALLED';host=$env:COMPUTERNAME;watcherTask=$watcherTask;watcherTaskAction=$watchActionState;userTask=$userTask;userTaskAction=$userActionState;selfHealTask=$selfHealTask;selfHealTaskAction=$selfHealActionState;selfHealIntervalSeconds=60;defaultRoute=[string]$cfg.default_route;pollIntervalMs=750;commanderFallback=[string]$cfg.fallback.transport;arbitraryShellAllowed=$false;yoloAllowed=$false;installedAt=(Get-Date -Format o)}
  Save-State $state
  Write-Output ($state|ConvertTo-Json -Depth 12 -Compress)
  exit 0
}catch{
  $state=[ordered]@{schema=1;ok=$false;classification='PROJECT_EXECUTION_ROUTER_INSTALL_FAILED';host=$env:COMPUTERNAME;error=$_.Exception.Message;installedAt=(Get-Date -Format o)}
  Save-State $state
  Write-Output ($state|ConvertTo-Json -Depth 12 -Compress)
  exit 1
}
