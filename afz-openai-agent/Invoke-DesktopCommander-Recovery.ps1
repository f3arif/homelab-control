#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','apply','watchdog')]
  [string]$Action='audit'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$taskName='AFZ Desktop Commander Watchdog'
$self=$MyInvocation.MyCommand.Path
$pattern='(?i)(desktop[ ._-]*commander|remote[ ._-]*desktop[ ._-]*commander|commander.*mcp|mcp.*commander)'

function Get-CommanderProcesses {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ([string]$_.Name -match $pattern) -or ([string]$_.CommandLine -match $pattern) -or ([string]$_.ExecutablePath -match $pattern)
  } | Select-Object ProcessId,Name,ExecutablePath,CommandLine)
}

function Get-CommanderServices {
  @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
    ([string]$_.Name -match $pattern) -or ([string]$_.DisplayName -match $pattern) -or ([string]$_.PathName -match $pattern)
  } | Select-Object Name,DisplayName,State,StartMode,PathName)
}

function Get-CommanderTasks {
  $out=@()
  foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)){
    $joined=(@($t.Actions | ForEach-Object { ([string]$_.Execute)+' '+([string]$_.Arguments) }) -join ' ')
    if(([string]$t.TaskName -match $pattern) -or ([string]$t.TaskPath -match $pattern) -or ($joined -match $pattern)){
      $out += [pscustomobject]@{TaskName=$t.TaskName;TaskPath=$t.TaskPath;State=[string]$t.State;Actions=$joined}
    }
  }
  @($out)
}

function Get-StartupCommands {
  $out=@()
  $keys=@(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
  )
  foreach($key in $keys){
    if(-not(Test-Path $key)){continue}
    $p=Get-ItemProperty $key -ErrorAction SilentlyContinue
    if(-not $p){continue}
    foreach($prop in $p.PSObject.Properties){
      if($prop.Name -like 'PS*'){continue}
      $v=[string]$prop.Value
      if($prop.Name -match $pattern -or $v -match $pattern){
        $out += [pscustomobject]@{Source=$key;Name=$prop.Name;Command=$v}
      }
    }
  }
  $startup=[Environment]::GetFolderPath('Startup')
  if($startup -and (Test-Path $startup)){
    $ws=New-Object -ComObject WScript.Shell
    foreach($lnk in @(Get-ChildItem $startup -Filter '*.lnk' -File -ErrorAction SilentlyContinue)){
      try{
        $s=$ws.CreateShortcut($lnk.FullName)
        $joined=([string]$s.TargetPath)+' '+([string]$s.Arguments)
        if($lnk.Name -match $pattern -or $joined -match $pattern){
          $out += [pscustomobject]@{Source=$startup;Name=$lnk.Name;Command=$joined}
        }
      }catch{}
    }
  }
  @($out)
}

function Get-CommandCandidates {
  $out=@()
  foreach($n in @('desktop-commander','desktop-commander.exe','remote-desktop-commander','remote-desktop-commander.exe')){
    $c=Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
    if($c){
      $p=if($c.Source){[string]$c.Source}else{[string]$c.Path}
      if($p){$out += $p}
    }
  }
  $pf86=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $roots=@(
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    (Join-Path $env:APPDATA 'npm'),
    $env:ProgramFiles,
    $pf86
  ) | Where-Object {$_ -and (Test-Path $_)}
  foreach($root in $roots){
    try{
      $hits=Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern -and $_.Extension -in @('.exe','.cmd','.bat') } |
        Select-Object -First 12 -ExpandProperty FullName
      $out += @($hits)
    }catch{}
  }
  @($out | Where-Object {$_} | Select-Object -Unique)
}

function Start-RegisteredCommander {
  param($services,$tasks,$startup,$commands,$processes)
  $actions=@()

  foreach($s in @($services)){
    try{
      if([string]$s.State -eq 'Running'){
        Restart-Service -Name $s.Name -Force -ErrorAction Stop
        $actions += "restart-service:$($s.Name)"
      }else{
        Start-Service -Name $s.Name -ErrorAction Stop
        $actions += "start-service:$($s.Name)"
      }
      return @($actions)
    }catch{$actions += "service-failed:$($s.Name)"}
  }

  foreach($t in @($tasks)){
    try{
      if([string]$t.State -eq 'Running'){Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue}
      Start-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
      $actions += "start-task:$($t.TaskPath)$($t.TaskName)"
      return @($actions)
    }catch{$actions += "task-failed:$($t.TaskName)"}
  }

  foreach($p in @($processes)){
    if([string]$p.ExecutablePath -and (Test-Path -LiteralPath ([string]$p.ExecutablePath)){
      try{
        Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Start-Process -FilePath ([string]$p.ExecutablePath) -WindowStyle Hidden | Out-Null
        $actions += "restart-process:$($p.ExecutablePath)"
        return @($actions)
      }catch{$actions += "process-restart-failed:$($p.ProcessId)"}
    }
  }

  foreach($s in @($startup)){
    try{
      Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c','start','""',([string]$s.Command) -WindowStyle Hidden | Out-Null
      $actions += "startup-command:$($s.Name)"
      return @($actions)
    }catch{$actions += "startup-failed:$($s.Name)"}
  }

  foreach($c in @($commands)){
    try{
      if($c -match '\.(cmd|bat)$'){
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c',"`"$c`"") -WindowStyle Hidden | Out-Null
      }else{
        Start-Process -FilePath $c -WindowStyle Hidden | Out-Null
      }
      $actions += "command:$c"
      return @($actions)
    }catch{$actions += "command-failed:$c"
  }

  @($actions)
}

function Ensure-Watchdog {
  if(-not $self -or -not(Test-Path -LiteralPath $self)){return $false}
  try{
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$self`" -Action watchdog"
    $triggers=@(
      (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
      (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $principal=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    return $true
  }catch{return $false}
}

$before=Get-CommanderProcesses
$services=Get-CommanderServices
$tasks=Get-CommanderTasks | Where-Object {$_.TaskName -ne $taskName}
$startup=Get-StartupCommands
$commands=Get-CommandCandidates
$actions=@()
$watchdogInstalled=$false

if($Action -eq 'watchdog'){
  if(@($before).Count -eq 0){
    $actions=Start-RegisteredCommander $services $tasks $startup $commands $before
    Start-Sleep -Seconds 5
  }
}elseif($Action -eq 'apply'){
  $actions=Start-RegisteredCommander $services $tasks $startup $commands $before
  Start-Sleep -Seconds 8
  $watchdogInstalled=Ensure-Watchdog
}

$after=Get-CommanderProcesses
$identified=(@($services).Count + @($tasks).Count + @($startup).Count + @($commands).Count + @($before).Count) -gt 0
$ok=(@($after).Count -gt 0)
$result=[ordered]@{
  schema=1
  action=$Action
  computer=$env:COMPUTERNAME
  ok=$ok
  classification=$(if($ok){'DESKTOP_COMMANDER_PROCESS_PRESENT'}elseif($identified){'DESKTOP_COMMANDER_IDENTIFIED_BUT_NOT_RUNNING'}else{'DESKTOP_COMMANDER_NOT_IDENTIFIED'})
  processBefore=@($before).Count
  processAfter=@($after).Count
  services=@($services)
  tasks=@($tasks)
  startup=@($startup)
  commandCandidates=@($commands)
  actions=@($actions)
  watchdogInstalled=$watchdogInstalled
  watchdogTask=$taskName
  credentialsChanged=$false
  tailscaleChanged=$false
  installedNewPackage=$false
  time=(Get-Date -Format o)
}
$result | ConvertTo-Json -Depth 8 -Compress
