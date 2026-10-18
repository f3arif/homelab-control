# Remove only this task and a child proven to belong to this installation.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName='AFZ Nuvio Public Edge'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($task){
 $expected='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Run-PublicEdge.ps1')+'"'
 if(@($task.Actions).Count -ne 1 -or [string]$task.Actions[0].Arguments -ne $expected){throw 'TASK_OWNERSHIP_CHANGED'}
 Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
$runtimeFile=Join-Path $root 'runtime-private.json'
if(Test-Path -LiteralPath $runtimeFile){
 $runtime=Get-Content -LiteralPath $runtimeFile -Raw | ConvertFrom-Json
 $process=Get-CimInstance Win32_Process -Filter ("ProcessId="+[int]$runtime.pid)
 if($process){
  $delta=[Math]::Abs(($process.CreationDate.ToUniversalTime()-[DateTime]::Parse($runtime.startedUtc).ToUniversalTime()).TotalSeconds)
  if($delta -gt 2 -or $process.Name -notmatch '^python' -or $process.CommandLine -notmatch '(?i)(^|\s)afz_public_proxy:app(\s|$)'){throw 'CHILD_OWNERSHIP_CHANGED'}
  Stop-Process -Id $process.ProcessId -Force
 }
}
Write-Output 'AFZ_NUVIO_PUBLIC_EDGE_REMOVED_EXISTING_SERVE_UNCHANGED'
