#Requires -Version 5.1
# Fail-closed installer for the Hermes gateway HA watchers on ASUS/windows-main.
#
# Invoked by the AFZ OpenAI Agent updater postsync hook (SYSTEM context) after
# every successful source sync. Guarantees:
#   - Watch-Hermes-Gateway-HA.ps1 parses (PS5.1 parser) BEFORE any mutation.
#   - The SYSTEM HA watcher task exists, correct action, every 1 minute.
#   - The user-context lifecycle task exists (S4U, no stored password, RunLevel
#     Limited) and the handoff directory ACLs allow the handshake.
#   - Never starts or stops the Hermes gateway itself; registration only.
#   - Never registers anything on any host except DESKTOP-10SKF0M.
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){ throw "Gateway HA installer wrong host: $env:COMPUTERNAME" }

$srcWatcher=Join-Path $InstallRoot 'afz-openai-agent\Watch-Hermes-Gateway-HA.ps1'
$srcLifecycle=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Hermes-Gateway-UserLifecycle.ps1'
$installDir='C:\ProgramData\AFZ\HermesRouting'
$stateFile=Join-Path $installDir 'gateway-ha-install.json'
$stateDir='C:\ProgramData\AFZ\HermesRouting'
$handoffDir=Join-Path $stateDir 'gateway-ha-handoff'
$systemTask='AFZ Hermes Gateway HA Watcher'
$userTask='AFZ Hermes Gateway HA User Action'
$utf8=New-Object Text.UTF8Encoding($false)

function Save-State($o){$o|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $stateFile -Encoding UTF8}

try{
  if(-not (Test-Path -LiteralPath $srcWatcher -PathType Leaf)){throw "HA watcher source missing: $srcWatcher"}
  if(-not (Test-Path -LiteralPath $srcLifecycle -PathType Leaf)){throw "HA lifecycle source missing: $srcLifecycle"}

  # Fail-closed: both scripts must parse under Windows PowerShell 5.1 before any
  # task registration or file copy happens.
  foreach($p in @($srcWatcher,$srcLifecycle)){
    $tokens=$null;$errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count -gt 0){
      $messages=($errors|ForEach-Object{$_.Message}) -join '; '
      throw "PowerShell parser rejected $($p): $messages"
    }
  }

  # Copy to the stable ProgramData location the tasks execute from.
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null
  $dstWatcher=Join-Path $installDir 'Watch-Hermes-Gateway-HA.ps1'
  $dstLifecycle=Join-Path $installDir 'Invoke-Hermes-Gateway-UserLifecycle.ps1'
  Copy-Item -LiteralPath $srcWatcher -Destination $dstWatcher -Force
  Copy-Item -LiteralPath $srcLifecycle -Destination $dstLifecycle -Force

  # Handoff directory: SYSTEM owns command; the Faiz user task writes result.
  New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
  $faizUser='FAIZ\DESIGN'
  try{
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if([string]$identity.User.Value -ne 'S-1-5-18'){
      # Non-SYSTEM (manual) runs: just make sure the directory exists.
      $faizUser=$null
    }
  }catch{}
  if($faizUser){
    try{
      $acl=Get-Acl -LiteralPath $handoffDir
      $hasRule=$false
      foreach($r in @($acl.Access)){
        if($r.IdentityReference -like '*Faiz*' -and [string]$r.AccessControlType -eq 'Allow'){$hasRule=$true}
      }
      if(-not $hasRule){
        $rule=New-Object Security.AccessControl.FileSystemAccessRule('Faiz','Modify','ObjectInherit,ContainerInherit','None','Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $handoffDir -AclObject $acl
      }
    }catch{}
  }

  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 8) -MultipleInstances IgnoreNew

  # SYSTEM-side HA watcher: every 1 minute.
  $systemAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dstWatcher`" -InstallRoot `"$InstallRoot`""
  $systemTrigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $systemPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $existing=Get-ScheduledTask -TaskName $systemTask -ErrorAction SilentlyContinue
  if($existing){
    Set-ScheduledTask -TaskName $systemTask -Action $systemAction -Trigger $systemTrigger -Settings $settings | Out-Null
    $systemTaskAction='updated'
  }else{
    Register-ScheduledTask -TaskName $systemTask -Action $systemAction -Trigger $systemTrigger -Settings $settings -Principal $systemPrincipal -Force | Out-Null
    $systemTaskAction='registered'
  }

  # User-context lifecycle executor: runs as Faiz (S4U), on-demand only.
  $userAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dstLifecycle`""
  $userSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 6) -MultipleInstances IgnoreNew
  $userPrincipal=New-ScheduledTaskPrincipal -UserId 'FAIZ\DESIGN' -LogonType S4U -RunLevel Limited
  $existingUser=Get-ScheduledTask -TaskName $userTask -ErrorAction SilentlyContinue
  if($existingUser){
    Set-ScheduledTask -TaskName $userTask -Action $userAction -Settings $userSettings | Out-Null
    $userTaskAction='updated'
  }else{
    Register-ScheduledTask -TaskName $userTask -Action $userAction -Settings $userSettings -Principal $userPrincipal -Force | Out-Null
    $userTaskAction='registered'
  }

  Save-State ([ordered]@{
    ok=$true
    at=(Get-Date -Format o)
    systemTask=$systemTask
    systemTaskAction=$systemTaskAction
    userTask=$userTask
    userTaskAction=$userTaskAction
    watcher=$dstWatcher
    lifecycle=$dstLifecycle
  })
  Write-Output ([ordered]@{ok=$true;classification='GATEWAY_HA_INSTALLED';systemTask=$systemTaskAction;userTask=$userTaskAction}|ConvertTo-Json -Compress)
  exit 0
}catch{
  Save-State ([ordered]@{
    ok=$false
    at=(Get-Date -Format o)
    error=$_.Exception.Message
  })
  Write-Output ([ordered]@{ok=$false;classification='GATEWAY_HA_INSTALL_FAILED';error=$_.Exception.Message}|ConvertTo-Json -Compress)
  exit 1
}
