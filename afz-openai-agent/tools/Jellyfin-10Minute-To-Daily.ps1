#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinScheduleDaily-'+$stamp)
$taskName='Jellyfin Watchdog'
Write-Output 'AFZ_JELLYFIN_WATCHDOG_TO_DAILY_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SCOPE=Jellyfin Watchdog sub-daily repetition only'
Write-Output 'JELLYFIN_SERVER_TRIGGER=UNCHANGED'
Write-Output 'UNRELATED_TASKS=UNCHANGED'
Write-Output 'RUNNING_PROCESSES=UNCHANGED'

$server=Get-ScheduledTask -TaskName 'Jellyfin Server' -ErrorAction SilentlyContinue
if($server){
  $sdesc=@()
  foreach($t in @($server.Triggers)){
    $interval='';$start='';try{$interval=[string]$t.Repetition.Interval}catch{};try{$start=[string]$t.StartBoundary}catch{}
    $sdesc+=('type='+$t.CimClass.CimClassName+';start='+$start+';interval='+$interval)
  }
  Write-Output ('SERVER_BEFORE|state='+$server.State+'|triggers='+($sdesc -join ' || '))
}

$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
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
Write-Output ('WATCHDOG_BEFORE|state='+$task.State+'|triggers='+($desc -join ' || '))
if($trigs.Count -ne 1){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_TRIGGER_COUNT_NOT_ONE';exit 2}
$t=$trigs[0]
$interval='';try{$interval=[string]$t.Repetition.Interval}catch{}
$days='';try{$days=[string]$t.DaysInterval}catch{}
if([string]::IsNullOrWhiteSpace($interval)){
  if($days -eq '1'){Write-Output 'STATUS=PASS|changed=0|reason=ALREADY_DAILY';exit 0}
  Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_NOT_SUBDAILY_REPETITION';exit 2
}
try{$span=[System.Xml.XmlConvert]::ToTimeSpan($interval)}catch{Write-Output ('STATUS=SAFE_STOP|reason=INTERVAL_PARSE_FAILED|interval='+$interval);exit 2}
if($span.TotalMinutes -ge 1440){Write-Output ('STATUS=SAFE_STOP|reason=INTERVAL_NOT_SUBDAILY|interval='+$interval);exit 2}
$sb=[string]$t.StartBoundary
if([string]::IsNullOrWhiteSpace($sb)){Write-Output 'STATUS=SAFE_STOP|reason=NO_STARTBOUNDARY';exit 2}
try{$dt=[datetime]::Parse($sb)}catch{Write-Output ('STATUS=SAFE_STOP|reason=STARTBOUNDARY_PARSE_FAILED|value='+$sb);exit 2}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$xml=Export-ScheduledTask -TaskName $taskName -ErrorAction Stop
[IO.File]::WriteAllText((Join-Path $backupRoot 'Jellyfin_Watchdog.xml'),$xml,(New-Object Text.UTF8Encoding($false)))
Write-Output ('BACKUP_DIR='+$backupRoot)
Write-Output ('PRESERVED_TIME_OF_DAY='+$dt.ToString('HH:mm:ss'))

$newTrigger=New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add($dt.TimeOfDay))
Set-ScheduledTask -TaskName $taskName -Trigger $newTrigger -ErrorAction Stop | Out-Null
$v=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$vt=@($v.Triggers)
if($vt.Count -ne 1){throw 'Verification trigger count mismatch'}
$rep='';$vdays='';$start=''
try{$rep=[string]$vt[0].Repetition.Interval}catch{}
try{$vdays=[string]$vt[0].DaysInterval}catch{}
try{$start=[string]$vt[0].StartBoundary}catch{}
if(-not [string]::IsNullOrWhiteSpace($rep)){throw ('Repetition remained after daily update: '+$rep)}
if($vdays -ne '1'){throw ('Daily verification failed DaysInterval='+$vdays)}
$afterTime=([datetime]::Parse($start)).TimeOfDay
if($afterTime.Hours -ne $dt.TimeOfDay.Hours -or $afterTime.Minutes -ne $dt.TimeOfDay.Minutes){throw 'Daily time-of-day changed unexpectedly'}
Write-Output ('WATCHDOG_AFTER|state='+$v.State+'|start='+$start+'|interval='+$rep+'|days='+$vdays+'|cadence=DAILY')
Write-Output 'CHANGED_COUNT=1'
Write-Output 'STATUS=PASS'
