#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)
$ErrorActionPreference='Stop'

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\windows-console-flash-audit'
$stateFile=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorFile=Join-Path $mirrorRoot 'WINDOWS-MAIN-CONSOLE-FLASH-AUDIT-LATEST.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Redact([string]$s){
  if([string]::IsNullOrWhiteSpace($s)){return $s}
  $v=$s
  $v=[regex]::Replace($v,'(?i)(authorization\s*[:=]\s*bearer\s+)[^\s\"'']+','$1<redacted>')
  $v=[regex]::Replace($v,'(?i)((?:api[_-]?key|token|secret|password)\s*[:=]\s*)[^\s\"'']+','$1<redacted>')
  $v=[regex]::Replace($v,'(?i)(--?(?:api[_-]?key|token|secret|password)\s+)[^\s\"'']+','$1<redacted>')
  return $v
}
function ActionText($a){
  return (Redact (([string]$a.Execute)+' '+([string]$a.Arguments))).Trim()
}
function IsShellAction([string]$text){
  return $text -match '(?i)(powershell|pwsh|cmd\.exe|conhost|wscript|cscript|\.ps1(?:\s|$)|\.bat(?:\s|$)|\.cmd(?:\s|$))'
}
function HasHiddenGuard([string]$text){
  return $text -match '(?i)(-WindowStyle\s+Hidden|-w\s+hidden|wscript\.exe|cscript\.exe|CREATE_NO_WINDOW|SW_HIDE)'
}
function TriggerView($t){
  [ordered]@{
    type=[string]$t.CimClass.CimClassName
    enabled=$(if($null -ne $t.Enabled){[bool]$t.Enabled}else{$null})
    startBoundary=[string]$t.StartBoundary
    repetitionInterval=[string]$t.Repetition.Interval
    repetitionDuration=[string]$t.Repetition.Duration
  }
}

$now=Get-Date
$explorerSessions=@(Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SessionId -Unique)
$all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
$byPid=@{}
foreach($p in $all){$byPid[[int]$p.ProcessId]=$p}

$processes=@()
foreach($p in $all){
  $name=[string]$p.Name
  if($name -notmatch '(?i)^(powershell|pwsh|cmd|conhost|wscript|cscript|node)\.exe$'){continue}
  $parent=$null
  if($byPid.ContainsKey([int]$p.ParentProcessId)){$parent=$byPid[[int]$p.ParentProcessId]}
  $cmd=Redact ([string]$p.CommandLine)
  $isInteractive=$explorerSessions -contains [int]$p.SessionId
  $risk='low'
  $reason=''
  if($isInteractive -and $name -match '(?i)^(powershell|pwsh|cmd|conhost)\.exe$'){
    if(-not(HasHiddenGuard $cmd)){$risk='high';$reason='interactive shell process without an explicit hidden-window guard'}
    else{$risk='medium';$reason='interactive shell process; hidden guard present'}
  } elseif($isInteractive){
    $risk='medium';$reason='interactive helper process'
  } else {
    $reason='non-interactive/session-isolated process'
  }
  $processes += [ordered]@{
    pid=[int]$p.ProcessId
    parentPid=[int]$p.ParentProcessId
    sessionId=[int]$p.SessionId
    interactiveSession=[bool]$isInteractive
    name=$name
    parentName=$(if($parent){[string]$parent.Name}else{''})
    created=[string]$p.CreationDate
    commandLine=$cmd
    risk=$risk
    reason=$reason
  }
}

$tasks=@()
foreach($t in @(Get-ScheduledTask -ErrorAction Stop)){
  $info=$null
  try{$info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop}catch{}
  foreach($a in @($t.Actions)){
    $text=ActionText $a
    if(-not(IsShellAction $text)){continue}
    $user=[string]$t.Principal.UserId
    $logon=[string]$t.Principal.LogonType
    $serviceAccount=($user -match '(?i)^(SYSTEM|NT AUTHORITY\\SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$' -or $logon -match '(?i)ServiceAccount')
    $hidden=HasHiddenGuard $text
    $risk='low'
    $reason='service/session-isolated shell task'
    if(-not $serviceAccount -and -not $hidden){
      $risk='high';$reason='interactive/user shell task without hidden-window guard'
    } elseif(-not $serviceAccount -and $hidden){
      $risk='medium';$reason='interactive/user shell task with hidden-window guard'
    } elseif($serviceAccount -and -not $hidden){
      $risk='low';$reason='service-account shell task; normally isolated from desktop'
    }
    $tasks += [ordered]@{
      taskPath=[string]$t.TaskPath
      taskName=[string]$t.TaskName
      state=[string]$t.State
      userId=$user
      logonType=$logon
      runLevel=[string]$t.Principal.RunLevel
      execute=[string]$a.Execute
      arguments=Redact ([string]$a.Arguments)
      hiddenGuard=[bool]$hidden
      serviceAccount=[bool]$serviceAccount
      risk=$risk
      reason=$reason
      triggers=@($t.Triggers | ForEach-Object { TriggerView $_ })
      lastRunTime=$(if($info){[string]$info.LastRunTime}else{''})
      lastTaskResult=$(if($info){[long]$info.LastTaskResult}else{$null})
      nextRunTime=$(if($info){[string]$info.NextRunTime}else{''})
    }
  }
}

$startup=@()
try{
  foreach($s in @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop)){
    $cmd=Redact ([string]$s.Command)
    if(IsShellAction $cmd){
      $startup += [ordered]@{
        name=[string]$s.Name
        location=[string]$s.Location
        user=[string]$s.User
        command=$cmd
        hiddenGuard=[bool](HasHiddenGuard $cmd)
      }
    }
  }
}catch{}

$events=@()
try{
  $start=$now.AddHours(-2)
  foreach($e in @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational';StartTime=$start} -ErrorAction Stop | Where-Object {$_.Id -in 100,107,129,200,201} | Select-Object -First 250)){
    $msg=Redact ([string]$e.Message)
    if($msg -match '(?i)(powershell|pwsh|cmd\.exe|\.ps1|\.bat|\.cmd|AFZ|Desktop Commander)'){
      $events += [ordered]@{time=[string]$e.TimeCreated;id=[int]$e.Id;message=$msg}
    }
  }
}catch{}

$highTasks=@($tasks | Where-Object {$_.risk -eq 'high'})
$highProcesses=@($processes | Where-Object {$_.risk -eq 'high'})
$result=[ordered]@{
  schema=1
  ok=$true
  mode='read-only'
  host=$env:COMPUTERNAME
  generatedAt=$now.ToString('o')
  interactiveExplorerSessions=@($explorerSessions)
  summary=[ordered]@{
    shellProcessCount=@($processes).Count
    interactiveShellProcessCount=@($processes | Where-Object {$_.interactiveSession}).Count
    highRiskProcessCount=@($highProcesses).Count
    shellTaskCount=@($tasks).Count
    highRiskTaskCount=@($highTasks).Count
    shellStartupCount=@($startup).Count
    matchingTaskSchedulerEventCount=@($events).Count
  }
  likelyFlashTasks=@($highTasks | Select-Object -First 30)
  likelyFlashProcesses=@($highProcesses | Select-Object -First 30)
  shellTasks=$tasks
  shellProcesses=$processes
  shellStartupCommands=$startup
  recentTaskSchedulerEvents=$events
}
$json=$result | ConvertTo-Json -Depth 12
$json | Set-Content -LiteralPath $stateFile -Encoding UTF8
try{
  if(Test-Path -LiteralPath $mirrorRoot -PathType Container){
    $json | Set-Content -LiteralPath $mirrorFile -Encoding UTF8
  }
}catch{}
[ordered]@{
  ok=$true
  action='audit'
  project='windows-console-flash'
  stateFile=$stateFile
  mirrorFile=$mirrorFile
  summary=$result.summary
} | ConvertTo-Json -Depth 6 -Compress
