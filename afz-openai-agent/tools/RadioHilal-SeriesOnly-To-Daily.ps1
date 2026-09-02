#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
trap {
  Write-Output ('STATUS=FAIL|error='+$_.Exception.Message)
  exit 1
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('RadioHilalSeriesOnlyDaily-'+$stamp)
$actionNeedle='AFZ-RADIOHILAL-SERIES-AWARE-INTAKE-LATEST.ps1'
Write-Output 'AFZ_RADIOHILAL_SERIESONLY_TO_DAILY_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SCOPE=exact RadioHilal SeriesOnly scheduled task only'
Write-Output 'INTAKE_SCRIPT=UNCHANGED'
Write-Output 'RESOURCE_REVIEW_WHISPER_GATES=UNCHANGED'
Write-Output 'MULTIPLE_INSTANCES_POLICY=UNCHANGED'
Write-Output 'RUNNING_PROCESSES=UNCHANGED'

$taskMatches=New-Object System.Collections.Generic.List[object]
foreach($taskCandidate in @(Get-ScheduledTask -ErrorAction Stop)){
  $actionText=(($taskCandidate.Actions|ForEach-Object{([string]$_.Execute+' '+[string]$_.Arguments).Trim()}) -join ' || ')
  if($actionText -like ('*'+$actionNeedle+'*') -and $actionText -match '(?i)(?:^|\s)-SeriesOnly(?:\s|$)'){
    [void]$taskMatches.Add([pscustomobject]@{Task=$taskCandidate;Action=$actionText})
  }
}
Write-Output ('MATCH_COUNT='+$taskMatches.Count)
if($taskMatches.Count -ne 1){Write-Output ('STATUS=SAFE_STOP|reason=SERIESONLY_TASK_MATCH_COUNT_'+$taskMatches.Count);exit 2}
$task=$taskMatches[0].Task
Write-Output ('TASK_NAME='+$task.TaskName)
Write-Output ('TASK_PATH='+$task.TaskPath)
Write-Output ('TASK_STATE='+$task.State)
Write-Output ('TASK_USER='+[string]$task.Principal.UserId)
Write-Output ('TASK_RUNLEVEL='+[string]$task.Principal.RunLevel)
Write-Output ('TASK_ACTION='+$taskMatches[0].Action)
try{Write-Output ('TASK_MULTIPLE_INSTANCES='+[string]$task.Settings.MultipleInstances)}catch{}
$trigs=@($task.Triggers)
if($trigs.Count -ne 1){Write-Output ('STATUS=SAFE_STOP|reason=TRIGGER_COUNT_'+$trigs.Count);exit 2}
$t=$trigs[0]
$interval='';$duration='';$start='';$days=''
try{$interval=[string]$t.Repetition.Interval}catch{}
try{$duration=[string]$t.Repetition.Duration}catch{}
try{$start=[string]$t.StartBoundary}catch{}
try{$days=[string]$t.DaysInterval}catch{}
Write-Output ('BEFORE|type='+$t.CimClass.CimClassName+'|start='+$start+'|interval='+$interval+'|duration='+$duration+'|days='+$days+'|enabled='+[string]$t.Enabled)

if([string]::IsNullOrWhiteSpace($interval)){
  if($days -eq '1'){Write-Output 'STATUS=PASS|changed=0|reason=ALREADY_DAILY';exit 0}
  Write-Output 'STATUS=SAFE_STOP|reason=NOT_REPEATING_OR_DAILY';exit 2
}
if($interval -ne 'PT10M'){Write-Output ('STATUS=SAFE_STOP|reason=EXPECTED_PT10M_GOT_'+$interval);exit 2}
if([string]::IsNullOrWhiteSpace($start)){Write-Output 'STATUS=SAFE_STOP|reason=NO_STARTBOUNDARY';exit 2}
try{$dt=[datetime]::Parse($start)}catch{Write-Output ('STATUS=SAFE_STOP|reason=START_PARSE_FAILED|value='+$start);exit 2}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$xml=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
[IO.File]::WriteAllText((Join-Path $backupRoot 'RadioHilal-SeriesOnly.xml'),$xml,(New-Object Text.UTF8Encoding($false)))
Write-Output ('BACKUP_DIR='+$backupRoot)
Write-Output ('PRESERVED_TIME_OF_DAY='+$dt.ToString('HH:mm:ss'))

$newTrigger=New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add($dt.TimeOfDay))
Set-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Trigger $newTrigger -ErrorAction Stop | Out-Null
$v=Get-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
$vt=@($v.Triggers)
if($vt.Count -ne 1){throw 'Verification trigger count mismatch'}
$rep='';$vdays='';$vstart=''
try{$rep=[string]$vt[0].Repetition.Interval}catch{}
try{$vdays=[string]$vt[0].DaysInterval}catch{}
try{$vstart=[string]$vt[0].StartBoundary}catch{}
if(-not [string]::IsNullOrWhiteSpace($rep)){throw ('Repetition remained: '+$rep)}
if($vdays -ne '1'){throw ('Daily verification failed DaysInterval='+$vdays)}
$afterDt=[datetime]::Parse($vstart)
if($afterDt.Hour -ne $dt.Hour -or $afterDt.Minute -ne $dt.Minute -or $afterDt.Second -ne $dt.Second){throw 'Preserved time-of-day verification failed'}
$actionAfter=(($v.Actions|ForEach-Object{([string]$_.Execute+' '+[string]$_.Arguments).Trim()}) -join ' || ')
if($actionAfter -notlike ('*'+$actionNeedle+'*') -or $actionAfter -notmatch '(?i)(?:^|\s)-SeriesOnly(?:\s|$)'){throw 'Action changed unexpectedly'}
Write-Output ('AFTER|type='+$vt[0].CimClass.CimClassName+'|start='+$vstart+'|interval='+$rep+'|days='+$vdays+'|cadence=DAILY')
Write-Output ('ACTION_AFTER='+$actionAfter)
try{Write-Output ('MULTIPLE_INSTANCES_AFTER='+[string]$v.Settings.MultipleInstances)}catch{}
Write-Output 'CHANGED_COUNT=1'
Write-Output 'STATUS=PASS'
exit 0
