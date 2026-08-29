#Requires -Version 5.1
[CmdletBinding()]
param()

# One-shot, read-only Windows-main runtime inventory.
# Reads process/task/service metadata and writes only its own sanitized diagnostic files.
# It does NOT stop/start/disable/delete/register processes, tasks, or services.
$ErrorActionPreference='Stop'
$jobId='asus-runtime-audit-20260828-r1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\windows-runtime-audit'
$stateFile=Join-Path $stateRoot 'last-job.txt'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$ackFile=Join-Path $diagRoot 'EMERGENCY_FALLBACK-AFZ-WINDOWS-RUNTIME-AUDIT-LATEST.json'

function Round-Mb($Bytes){ if($null -eq $Bytes){return $null}; return [math]::Round(([double]$Bytes/1MB),1) }
function Safe-ScriptIdentity([string]$Name,[string]$Exe,[string]$CommandLine){
  $r=[ordered]@{executable=$null;script=$null}
  try{if($Exe){$r.executable=[IO.Path]::GetFileName($Exe)}}catch{}
  if(-not $r.executable -and $Name){$r.executable=$Name}
  if($CommandLine){
    # Expose only a script basename, never arbitrary arguments/tokens.
    $m=[regex]::Match($CommandLine,'(?i)(?:-File\s+|^|\s)(?:"([^"]+\.(?:ps1|py|js|cmd|bat))"|([^\s"]+\.(?:ps1|py|js|cmd|bat)))')
    if($m.Success){
      $p=$(if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value})
      try{$r.script=[IO.Path]::GetFileName($p)}catch{$r.script=$p}
    }
  }
  return [pscustomobject]$r
}
function Safe-TaskAction($Task){
  $a=@($Task.Actions|Select-Object -First 1)
  if($a.Count -eq 0){return $null}
  $exe=$null;$script=$null
  try{$exe=[IO.Path]::GetFileName([string]$a[0].Execute)}catch{$exe=[string]$a[0].Execute}
  $args=[string]$a[0].Arguments
  if($args){
    $m=[regex]::Match($args,'(?i)(?:-File\s+)(?:"([^"]+\.(?:ps1|py|js|cmd|bat))"|([^\s"]+\.(?:ps1|py|js|cmd|bat)))')
    if($m.Success){$p=$(if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value});try{$script=[IO.Path]::GetFileName($p)}catch{$script=$p}}
  }
  return [pscustomobject][ordered]@{execute=$exe;script=$script}
}
function Trigger-Summary($Task){
  $out=@()
  foreach($t in @($Task.Triggers)){
    $type=$t.CimClass.CimClassName -replace '^MSFT_Task','' -replace 'Trigger$',''
    $row=[ordered]@{type=$type;enabled=$t.Enabled}
    if($null -ne $t.Repetition){
      if($t.Repetition.Interval){$row.interval=[string]$t.Repetition.Interval}
      if($t.Repetition.Duration){$row.duration=[string]$t.Repetition.Duration}
    }
    if($t.StartBoundary){$row.start=[string]$t.StartBoundary}
    $out+=[pscustomobject]$row
  }
  return @($out)
}

try{
  if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){exit 0}
  New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
  if(Test-Path -LiteralPath $stateFile -PathType Leaf){
    if((Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue).Trim() -eq $jobId -and (Test-Path -LiteralPath $ackFile -PathType Leaf)){exit 0}
  }

  $os=Get-CimInstance Win32_OperatingSystem
  $totalBytes=[double]$os.TotalVisibleMemorySize*1KB
  $freeBytes=[double]$os.FreePhysicalMemory*1KB
  $usedBytes=$totalBytes-$freeBytes
  $cpuAvg=(Get-CimInstance Win32_Processor|Measure-Object -Property LoadPercentage -Average).Average

  $cimProc=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $gp=@(Get-Process -ErrorAction SilentlyContinue)
  $gpById=@{};foreach($p in $gp){$gpById[[int]$p.Id]=$p}
  $processRows=@()
  foreach($c in $cimProc){
    $p=$gpById[[int]$c.ProcessId]
    $idn=Safe-ScriptIdentity ([string]$c.Name) ([string]$c.ExecutablePath) ([string]$c.CommandLine)
    $priv=$null;$work=$null;$cpu=$null;$start=$null;$threads=$null;$handles=$null
    if($p){
      try{$priv=Round-Mb $p.PrivateMemorySize64}catch{}
      try{$work=Round-Mb $p.WorkingSet64}catch{}
      try{$cpu=[math]::Round([double]$p.CPU,1)}catch{}
      try{$start=$p.StartTime.ToString('o')}catch{}
      try{$threads=$p.Threads.Count}catch{}
      try{$handles=$p.HandleCount}catch{}
    }
    $processRows+=[pscustomobject][ordered]@{
      pid=[int]$c.ProcessId;parentPid=[int]$c.ParentProcessId;name=[string]$c.Name
      privateMb=$priv;workingMb=$work;cpuSeconds=$cpu;started=$start;threads=$threads;handles=$handles
      executable=$idn.executable;script=$idn.script
    }
  }
  $processRows=@($processRows|Sort-Object @{Expression={if($null -eq $_.privateMb){-1}else{$_.privateMb}};Descending=$true})

  $servicesByPid=@{}
  $serviceRows=@()
  foreach($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)){
    if([int]$s.ProcessId -gt 0){
      if(-not $servicesByPid.ContainsKey([int]$s.ProcessId)){$servicesByPid[[int]$s.ProcessId]=@()}
      $servicesByPid[[int]$s.ProcessId]+=[string]$s.Name
    }
    if($s.StartMode -eq 'Auto' -or $s.State -eq 'Running'){
      $serviceRows+=[pscustomobject][ordered]@{name=[string]$s.Name;displayName=[string]$s.DisplayName;state=[string]$s.State;startMode=[string]$s.StartMode;pid=[int]$s.ProcessId}
    }
  }
  foreach($r in $processRows){if($servicesByPid.ContainsKey([int]$r.pid)){$r|Add-Member -NotePropertyName services -NotePropertyValue @($servicesByPid[[int]$r.pid])}}

  $taskRows=@()
  foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)){
    $isMicrosoft=([string]$t.TaskPath).StartsWith('\Microsoft\',[StringComparison]::OrdinalIgnoreCase)
    $isAfz=(([string]$t.TaskName+' '+[string]$t.TaskPath) -match '(?i)AFZ|RadioHilal|FamilyPTT|Podcast|Jellyfin|TorBox|Marketplace|OpenAI')
    if($isMicrosoft -and -not $isAfz -and [string]$t.State -ne 'Running'){continue}
    $info=$null;try{$info=Get-ScheduledTaskInfo -InputObject $t -ErrorAction Stop}catch{}
    $a=Safe-TaskAction $t
    $taskRows+=[pscustomobject][ordered]@{
      taskName=[string]$t.TaskName;taskPath=[string]$t.TaskPath;state=[string]$t.State;enabled=[bool]$t.Settings.Enabled
      lastRun=$(if($info){$info.LastRunTime.ToString('o')}else{$null});nextRun=$(if($info){$info.NextRunTime.ToString('o')}else{$null});lastResult=$(if($info){[int64]$info.LastTaskResult}else{$null})
      execute=$(if($a){$a.execute}else{$null});script=$(if($a){$a.script}else{$null});triggers=@(Trigger-Summary $t)
    }
  }
  $taskRows=@($taskRows|Sort-Object taskPath,taskName)

  $afzRegex='(?i)AFZ|RadioHilal|FamilyPTT|Podcast|Jellyfin|TorBox|Marketplace|OpenAI|Priority|Queue|H3'
  $afzProcesses=@($processRows|Where-Object{($_.name -match $afzRegex)-or($_.script -match $afzRegex)-or(($_.services -join ' ') -match $afzRegex)})
  $topProcesses=@($processRows|Select-Object -First 40)

  $payload=[ordered]@{
    schema=1;purpose='EMERGENCY_FALLBACK_READ_ONLY_RUNTIME_AUDIT';jobId=$jobId;source='windows-main';computer=$env:COMPUTERNAME
    timestamp=(Get-Date -Format o)
    memory=[ordered]@{totalGb=[math]::Round($totalBytes/1GB,2);usedGb=[math]::Round($usedBytes/1GB,2);freeGb=[math]::Round($freeBytes/1GB,2);usedPercent=[math]::Round(($usedBytes/$totalBytes)*100,1)}
    cpuPercent=$(if($null -ne $cpuAvg){[math]::Round([double]$cpuAvg,1)}else{$null})
    processCount=$processRows.Count;scheduledTaskCount=$taskRows.Count
    topProcesses=$topProcesses;afzProcesses=$afzProcesses;scheduledTasks=$taskRows;autoOrRunningServices=$serviceRows
    safety=[ordered]@{mutation=$false;commandLineArgumentsIncluded=$false;credentialsIncluded=$false;processesChanged=$false;tasksChanged=$false;servicesChanged=$false}
  }
  $payload|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ackFile -Encoding UTF8
  Set-Content -LiteralPath $stateFile -Value $jobId -Encoding ASCII
}catch{
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      [ordered]@{schema=1;purpose='EMERGENCY_FALLBACK_READ_ONLY_RUNTIME_AUDIT';jobId=$jobId;source='windows-main';status='probe-error';message=$_.Exception.Message;timestamp=(Get-Date -Format o)}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $ackFile -Encoding UTF8
    }
  }catch{}
}
exit 0
