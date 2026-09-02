#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Write-Output 'AFZ_AUDIT_10MIN_SCHEDULED_TASKS_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
$all=@(Get-ScheduledTask -ErrorAction Stop)
$matches=New-Object System.Collections.Generic.List[object]
foreach($task in $all){
  foreach($t in @($task.Triggers)){
    $interval='';$start='';$duration=''
    try{$interval=[string]$t.Repetition.Interval}catch{}
    try{$start=[string]$t.StartBoundary}catch{}
    try{$duration=[string]$t.Repetition.Duration}catch{}
    if($interval -eq 'PT10M'){
      $matches.Add([pscustomobject]@{TaskName=$task.TaskName;TaskPath=$task.TaskPath;State=[string]$task.State;Start=$start;Duration=$duration;User=[string]$task.Principal.UserId;Action=(($task.Actions|ForEach-Object{([string]$_.Execute+' '+[string]$_.Arguments).Trim()}) -join ' || ')})
    }
  }
}
Write-Output ('PT10M_TASK_COUNT='+$matches.Count)
foreach($m in $matches){Write-Output ('PT10M_TASK|path='+$m.TaskPath+$m.TaskName+'|state='+$m.State+'|start='+$m.Start+'|duration='+$m.Duration+'|user='+$m.User+'|action='+$m.Action)}
Write-Output 'STATUS=PASS'
