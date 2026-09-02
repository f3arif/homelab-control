#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinScheduleDaily-'+$stamp)
Write-Output 'AFZ_JELLYFIN_10MIN_TO_DAILY_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SCOPE=Jellyfin scheduled tasks with exact PT10M repetition only'
Write-Output 'UNRELATED_TASKS=UNCHANGED'
Write-Output 'RUNNING_PROCESSES=UNCHANGED'

$all=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskName -like 'Jellyfin*'})
Write-Output ('JELLYFIN_TASK_COUNT='+$all.Count)
$plan=New-Object System.Collections.Generic.List[object]
$blockers=New-Object System.Collections.Generic.List[string]
foreach($task in $all){
  $trigs=@($task.Triggers)
  $desc=@()
  foreach($t in $trigs){
    $interval='';$duration='';$start='';$days=''
    try{$interval=[string]$t.Repetition.Interval}catch{}
    try{$duration=[string]$t.Repetition.Duration}catch{}
    try{$start=[string]$t.StartBoundary}catch{}
    try{$days=[string]$t.DaysInterval}catch{}
    $desc += ('type='+$t.CimClass.CimClassName+';start='+$start+';interval='+$interval+';duration='+$duration+';days='+$days+';enabled='+[string]$t.Enabled)
  }
  Write-Output ('BEFORE|task='+$task.TaskPath+$task.TaskName+'|state='+$task.State+'|triggers='+($desc -join ' || '))
  $ten=@($trigs | Where-Object { try{[string]$_.Repetition.Interval -eq 'PT10M'}catch{$false} })
  if($ten.Count -eq 0){continue}
  if($trigs.Count -ne 1 -or $ten.Count -ne 1){
    $blockers.Add($task.TaskPath+$task.TaskName+' has PT10M plus additional/ambiguous triggers')
    continue
  }
  $sb=[string]$ten[0].StartBoundary
  if([string]::IsNullOrWhiteSpace($sb)){
    $blockers.Add($task.TaskPath+$task.TaskName+' PT10M trigger has no StartBoundary')
    continue
  }
  try{$dt=[datetime]::Parse($sb)}catch{$blockers.Add($task.TaskPath+$task.TaskName+' StartBoundary parse failed: '+$sb);continue}
  $plan.Add([pscustomobject]@{TaskName=$task.TaskName;TaskPath=$task.TaskPath;TimeOfDay=$dt.TimeOfDay;BeforeStart=$sb})
}
Write-Output ('PT10M_MATCH_COUNT='+$plan.Count)
Write-Output ('BLOCKER_COUNT='+$blockers.Count)
foreach($b in $blockers){Write-Output ('BLOCKER='+$b)}
if($blockers.Count -gt 0){Write-Output 'STATUS=SAFE_STOP|reason=AMBIGUOUS_TRIGGER_SET';exit 2}
if($plan.Count -eq 0){Write-Output 'STATUS=PASS|changed=0|reason=NO_PT10M_JELLYFIN_TASKS';exit 0}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
foreach($p in $plan){
  $safe=($p.TaskPath.Trim('\\')+'_'+$p.TaskName) -replace '[^A-Za-z0-9_.-]','_'
  $xml=Export-ScheduledTask -TaskName $p.TaskName -TaskPath $p.TaskPath -ErrorAction Stop
  [IO.File]::WriteAllText((Join-Path $backupRoot ($safe+'.xml')),$xml,(New-Object Text.UTF8Encoding($false)))
}
Write-Output ('BACKUP_DIR='+$backupRoot)

$changed=0
foreach($p in $plan){
  $today=[datetime]::Today.Add($p.TimeOfDay)
  $newTrigger=New-ScheduledTaskTrigger -Daily -At $today
  Set-ScheduledTask -TaskName $p.TaskName -TaskPath $p.TaskPath -Trigger $newTrigger -ErrorAction Stop | Out-Null
  $v=Get-ScheduledTask -TaskName $p.TaskName -TaskPath $p.TaskPath -ErrorAction Stop
  $vt=@($v.Triggers)
  if($vt.Count -ne 1){throw ('Verification trigger count mismatch: '+$p.TaskPath+$p.TaskName)}
  $rep='';$days='';$start=''
  try{$rep=[string]$vt[0].Repetition.Interval}catch{}
  try{$days=[string]$vt[0].DaysInterval}catch{}
  try{$start=[string]$vt[0].StartBoundary}catch{}
  if($rep -eq 'PT10M'){throw ('PT10M remained after update: '+$p.TaskPath+$p.TaskName)}
  if($days -notin @('1','')){
    throw ('Daily verification failed DaysInterval='+$days+' for '+$p.TaskPath+$p.TaskName)
  }
  $changed++
  Write-Output ('AFTER|task='+$p.TaskPath+$p.TaskName+'|state='+$v.State+'|start='+$start+'|interval='+$rep+'|days='+$days+'|cadence=DAILY')
}
Write-Output ('CHANGED_COUNT='+$changed)
Write-Output 'STATUS=PASS'
