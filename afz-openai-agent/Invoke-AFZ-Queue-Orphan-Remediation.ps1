#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('audit','apply')][string]$Action,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,180}$')][string]$TaskId,
  [string]$QuarantineRoot='C:\ProgramData\AFZ\QueueJanitor\Quarantine'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-LiveExecutors([string]$Needle){
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine -and $_.CommandLine -like "*$Needle*"}|ForEach-Object{[pscustomobject]@{processId=$_.ProcessId;parentProcessId=$_.ParentProcessId;name=$_.Name;creationDate=$_.CreationDate;commandLine=$_.CommandLine}})
}
function Get-ArtifactClass([System.IO.FileInfo]$File){
  $p=$File.FullName.ToLowerInvariant();$n=$File.Name.ToLowerInvariant()
  if($n -match 'hold' -or $p -match '\\hold'){return 'HELD'}
  if($p -match '\\results?\\'){return 'RESULT'}
  if($p -match '\\processing\\'){return 'PROCESSING'}
  if($p -match '\\quarantine\\'){return 'QUARANTINED'}
  if($p -match '\\failed\\'){return 'FAILED'}
  if($p -match '\\completed\\'){return 'COMPLETED'}
  if($p -match '\\queue\\' -or $p -match '\\pending\\'){return 'QUEUED'}
  return 'UNKNOWN'
}
function Get-ResultStatus([System.IO.FileInfo]$File){
  if($File.Extension -ine '.txt' -or $File.Length -ge 2MB){return $null}
  try{$line=Get-Content -LiteralPath $File.FullName -TotalCount 40 -ErrorAction Stop|Where-Object{$_ -match '^Status='}|Select-Object -First 1;if($line){return $line.Substring(7)}}catch{}
  return $null
}
function Add-Root($List,[string]$Path){if($Path -and (Test-Path -LiteralPath $Path -PathType Container) -and -not $List.Contains($Path)){[void]$List.Add($Path)}}
function Get-SearchRoots{
  $roots=New-Object System.Collections.Generic.List[string]
  # This runner normally executes as SYSTEM. Never rely only on $env:USERPROFILE,
  # which would point at systemprofile and miss the user's AFZ queue tree.
  $sharedCandidates=New-Object System.Collections.Generic.List[string]
  [void]$sharedCandidates.Add('C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared')
  if($env:USERPROFILE){[void]$sharedCandidates.Add((Join-Path (Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc') 'AFZ Shared'))}
  [void]$sharedCandidates.Add('C:\AFZ-Shared')
  try{
    Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue|ForEach-Object{
      $candidate=Join-Path (Join-Path $_.FullName 'OneDrive - AFZ Engineering Inc') 'AFZ Shared'
      if(-not $sharedCandidates.Contains($candidate)){[void]$sharedCandidates.Add($candidate)}
    }
  }catch{}
  foreach($shared in @($sharedCandidates|Select-Object -Unique)){
    if(-not(Test-Path -LiteralPath $shared -PathType Container)){continue}
    foreach($name in @('AFZ Workers','AFZ Queue','AFZ Results','Queue','Results','Processing','Hold','Staging','Failed','Completed','Quarantine')){Add-Root $roots (Join-Path $shared $name)}
    try{Get-ChildItem -LiteralPath $shared -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match 'Queue|Worker|Result|Processing|Hold|Staging|Failed|Completed|Quarantine'}|ForEach-Object{Add-Root $roots $_.FullName}}catch{}
  }
  foreach($local in @('C:\ProgramData\AFZ\Runtime\LocalTasks\AutoRunner','C:\ProgramData\AFZ\QueueJanitor','C:\ProgramData\AFZ\QueueSafety')){Add-Root $roots $local}
  @($roots)
}
function Find-TaskArtifacts([string]$Needle){
  $seen=@{};$items=New-Object System.Collections.Generic.List[object]
  foreach($root in @(Get-SearchRoots)){
    try{Get-ChildItem -LiteralPath $root -Recurse -File -Filter "$Needle*" -ErrorAction SilentlyContinue|ForEach-Object{if(-not $seen.ContainsKey($_.FullName)){$seen[$_.FullName]=$true;[void]$items.Add([pscustomobject]@{file=$_;classification=(Get-ArtifactClass $_);resultStatus=(Get-ResultStatus $_)})}}}catch{}
  }
  @($items)
}
function Get-SafeHash([string]$Path){try{return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash}catch{return $null}}
function Get-JanitorState{
  $name='AFZ Queue Janitor v2'
  try{$t=Get-ScheduledTask -TaskName $name -ErrorAction Stop;$i=Get-ScheduledTaskInfo -TaskName $name -TaskPath $t.TaskPath -ErrorAction Stop;return [ordered]@{exists=$true;state=[string]$t.State;lastRun=$i.LastRunTime;lastResult=$i.LastTaskResult;nextRun=$i.NextRunTime}}catch{return [ordered]@{exists=$false;state='MISSING';error=$_.Exception.Message}}
}
$started=Get-Date
$artifacts=@(Find-TaskArtifacts $TaskId)
$live=@(Get-LiveExecutors $TaskId)
$terminal=@($artifacts|Where-Object{$_.classification -in @('RESULT','FAILED','COMPLETED') -and -not [string]::IsNullOrWhiteSpace([string]$_.resultStatus)})
$movable=@($artifacts|Where-Object{$_.classification -in @('HELD','QUEUED','PROCESSING')})
$janitor=Get-JanitorState
$terminalSummary=@($terminal|ForEach-Object{[ordered]@{path=$_.file.FullName;classification=$_.classification;status=$_.resultStatus;sha256=(Get-SafeHash $_.file.FullName);lastWrite=$_.file.LastWriteTime.ToString('o')}})
$movableSummary=@($movable|ForEach-Object{[ordered]@{path=$_.file.FullName;classification=$_.classification;sha256=(Get-SafeHash $_.file.FullName);length=$_.file.Length;lastWrite=$_.file.LastWriteTime.ToString('o')}})
$diagnosis='NO_MATCHING_ARTIFACT'
if($live.Count -gt 0){$diagnosis='LIVE_EXECUTOR_PRESENT_DO_NOT_RECLAIM'}elseif($terminal.Count -gt 0 -and $movable.Count -gt 0){$diagnosis='ORPHAN_AFTER_TERMINAL_RESULT'}elseif($terminal.Count -gt 0){$diagnosis='TERMINAL_RESULT_NO_ORPHAN'}elseif($movable.Count -gt 0){$diagnosis='NONTERMINAL_ARTIFACT_REQUIRES_REVIEW'}
if($Action -eq 'audit'){
  [ordered]@{ok=$true;action='audit';taskId=$TaskId;diagnosis=$diagnosis;counts=[ordered]@{liveExecutors=$live.Count;terminal=$terminal.Count;movable=$movable.Count};janitor=$janitor;liveExecutorProcesses=$live;terminalEvidence=$terminalSummary;movableArtifacts=$movableSummary;searchRoots=@(Get-SearchRoots);generatedAt=(Get-Date).ToString('o')}|ConvertTo-Json -Depth 10 -Compress
  exit 0
}
if($diagnosis -ne 'ORPHAN_AFTER_TERMINAL_RESULT'){throw "Refusing apply: diagnosis is '$diagnosis', expected ORPHAN_AFTER_TERMINAL_RESULT."}
$liveBeforeApply=@(Get-LiveExecutors $TaskId)
if($liveBeforeApply.Count -gt 0){throw 'Refusing apply: a live executor appeared before quarantine.'}
$stamp=$started.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$safeTask=($TaskId -replace '[^A-Za-z0-9._-]','_')
$destinationRoot=Join-Path (Join-Path $QuarantineRoot $safeTask) $stamp
New-Item -ItemType Directory -Force -Path $destinationRoot|Out-Null
$moved=New-Object System.Collections.Generic.List[object]
foreach($entry in $movableSummary){
  if(@(Get-LiveExecutors $TaskId).Count -gt 0){throw "Repair stopped: a live executor appeared before moving '$($entry.path)'."}
  if(-not(Test-Path -LiteralPath $entry.path -PathType Leaf)){throw "Repair stopped: source disappeared: $($entry.path)"}
  $dest=Join-Path $destinationRoot ([IO.Path]::GetFileName($entry.path))
  if(Test-Path -LiteralPath $dest){throw "Repair stopped: quarantine destination exists: $dest"}
  Move-Item -LiteralPath $entry.path -Destination $dest -ErrorAction Stop
  [void]$moved.Add([ordered]@{source=$entry.path;destination=$dest;classification=$entry.classification;sha256Before=$entry.sha256;sha256After=(Get-SafeHash $dest)})
}
$manifest=[ordered]@{schemaVersion='1.0';action='apply';taskId=$TaskId;diagnosis='ORPHAN_AFTER_TERMINAL_RESULT';repairedAt=(Get-Date).ToString('o');safety=[ordered]@{liveExecutorsInitial=$live.Count;liveExecutorsBeforeApply=$liveBeforeApply.Count;terminalEvidenceCount=$terminal.Count;deletedFiles=0;terminalResultMoved=$false};janitor=$janitor;terminalEvidence=$terminalSummary;quarantinedArtifacts=@($moved)}
$manifestPath=Join-Path $destinationRoot 'quarantine-manifest.json'
$manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8
$manifest['manifestPath']=$manifestPath;$manifest['ok']=$true
$manifest|ConvertTo-Json -Depth 10 -Compress