#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

# Live-rechecking remediation for DESKTOP-H3R6CQN. Never trust an old success
# marker: legacy installers can recreate a visible Interactive console action.
# This helper only mutates the known Direct Return Publisher when its action
# exactly matches the old visible PowerShell form. All other tasks are audited
# read-only and reported as remaining console risks.
$targetHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-console-flash-remediation'
$stateFile=Join-Path $root 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Save($Object){
  [IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 50 -Compress),$utf8)
  Write-Output ($Object|ConvertTo-Json -Depth 50 -Compress)
}

try{
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "SYSTEM H3 SSH key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source

  $remote=@'
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: $env:COMPUTERNAME"}
$taskName='AFZ H3 GitHub Direct Return Publisher'
$publisher='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
$launcher='C:\AFZ\GitHubDirect\Run-H3-GitHub-DirectReturn-Hidden.vbs'
$remoteState='C:\ProgramData\AFZ\H3GitHubDirect\console-flash-remediation-v2.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-CONSOLE-FLASH-AUDIT-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Fmt-Date($v){if($null -eq $v){return $null};try{return ([datetime]$v).ToString('o')}catch{return [string]$v}}
function Is-ConsoleExecutable([string]$Exe){
  if([string]::IsNullOrWhiteSpace($Exe)){return $false}
  $leaf=[IO.Path]::GetFileName($Exe).ToLowerInvariant()
  return ($leaf -in @('powershell.exe','pwsh.exe','cmd.exe','python.exe','python3.exe','py.exe','ssh.exe','git.exe','robocopy.exe','ffmpeg.exe','node.exe','npm.cmd','npx.cmd'))
}
function Task-Audit {
  $rows=@()
  foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like 'AFZ*' -or $_.TaskName -match 'H3' -or $_.TaskName -eq 'OpenWebUI Server'
  })){
    $info=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
    $triggerSummary=@($t.Triggers|ForEach-Object {
      [ordered]@{
        type=$_.CimClass.CimClassName
        startBoundary=[string]$_.StartBoundary
        enabled=$(if($null -eq $_.Enabled){$null}else{[bool]$_.Enabled})
        repetitionInterval=$(if($_.Repetition){[string]$_.Repetition.Interval}else{$null})
        repetitionDuration=$(if($_.Repetition){[string]$_.Repetition.Duration}else{$null})
      }
    })
    foreach($a in @($t.Actions)){
      $interactive=([string]$t.Principal.LogonType -match 'Interactive')
      $console=Is-ConsoleExecutable ([string]$a.Execute)
      $rows += [pscustomobject]@{
        task=[string]$t.TaskName
        taskPath=[string]$t.TaskPath
        state=[string]$t.State
        enabled=[bool]$t.Settings.Enabled
        user=[string]$t.Principal.UserId
        logonType=[string]$t.Principal.LogonType
        runLevel=[string]$t.Principal.RunLevel
        execute=[string]$a.Execute
        arguments=[string]$a.Arguments
        interactive=$interactive
        directConsole=$console
        consoleRisk=($interactive -and $console)
        lastRunTime=$(if($info){Fmt-Date $info.LastRunTime}else{$null})
        nextRunTime=$(if($info){Fmt-Date $info.NextRunTime}else{$null})
        lastTaskResult=$(if($info){[int]$info.LastTaskResult}else{$null})
        triggers=$triggerSummary
      }
    }
  }
  return @($rows)
}
function Publish-Diagnostic($Object){
  New-Item -ItemType Directory -Force -Path (Split-Path $remoteState -Parent)|Out-Null
  [IO.File]::WriteAllText($remoteState,($Object|ConvertTo-Json -Depth 50 -Compress),$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagFile,($Object|ConvertTo-Json -Depth 50),$utf8)}}catch{}
}
function Emit($Object){Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 50 -Compress)}

$beforeAudit=@(Task-Audit)
$beforeRisks=@($beforeAudit|Where-Object {$_.consoleRisk})
$t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $t){
  Emit ([ordered]@{schema=2;ok=$false;status='target-task-missing';host=$env:COMPUTERNAME;targetTask=$taskName;changed=$false;auditBefore=$beforeAudit;remainingRiskTasks=$beforeRisks;updatedAt=(Get-Date -Format o)})
  exit 0
}
$actions=@($t.Actions)
if($actions.Count -ne 1){
  Emit ([ordered]@{schema=2;ok=$false;status='unexpected-target-action-count';host=$env:COMPUTERNAME;targetTask=$taskName;changed=$false;actionCount=$actions.Count;auditBefore=$beforeAudit;remainingRiskTasks=$beforeRisks;updatedAt=(Get-Date -Format o)})
  exit 0
}
$a=$actions[0]
$execute=[string]$a.Execute
$args=[string]$a.Arguments
$leaf=[IO.Path]::GetFileName($execute).ToLowerInvariant()
$principalBefore=[ordered]@{user=[string]$t.Principal.UserId;logonType=[string]$t.Principal.LogonType;runLevel=[string]$t.Principal.RunLevel}
$changed=$false
$restored=$false
$parityFailure=$null
$infoBefore=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
$publisherStatePath='C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-v3.json'
$publisherBefore=Read-Json $publisherStatePath

if($leaf -eq 'wscript.exe' -and $args -like "*$launcher*"){
  $status='already-remediated-live-verified'
}elseif($leaf -eq 'powershell.exe' -and $args -like '*Publish-H3-GitHub-DirectReturn-V3.ps1*' -and ([string]$t.Principal.LogonType) -match 'Interactive'){
  if(-not(Test-Path -LiteralPath $publisher -PathType Leaf)){throw "Publisher missing: $publisher"}
  $oldAction=New-ScheduledTaskAction -Execute $execute -Argument $args
  $ps="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $cmd='"'+$ps+'" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$publisher+'"'
  $escaped=$cmd.Replace('"','""')
  $vbsLines=@(
    'Option Explicit',
    'Dim shell, cmd, rc',
    'Set shell = CreateObject("WScript.Shell")',
    ('cmd = "'+$escaped+'"'),
    'rc = shell.Run(cmd, 0, True)',
    'WScript.Quit rc'
  )
  [IO.File]::WriteAllText($launcher,($vbsLines -join "`r`n"),$utf8)
  $wscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
  if(-not(Test-Path -LiteralPath $wscript -PathType Leaf)){throw "wscript.exe missing: $wscript"}
  $newAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+$launcher+'"')
  try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
  Set-ScheduledTask -TaskName $taskName -Action $newAction|Out-Null
  $changed=$true

  $afterSet=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $principalAfter=[ordered]@{user=[string]$afterSet.Principal.UserId;logonType=[string]$afterSet.Principal.LogonType;runLevel=[string]$afterSet.Principal.RunLevel}
  if($principalBefore.user -ne $principalAfter.user -or $principalBefore.logonType -ne $principalAfter.logonType -or $principalBefore.runLevel -ne $principalAfter.runLevel){
    Set-ScheduledTask -TaskName $taskName -Action $oldAction|Out-Null
    throw 'Principal changed unexpectedly; original action restored.'
  }

  Start-ScheduledTask -TaskName $taskName
  $deadline=(Get-Date).AddSeconds(75)
  do{Start-Sleep -Milliseconds 750;$current=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;if($current -and [string]$current.State -ne 'Running'){break}}while((Get-Date) -lt $deadline)
  $infoAfter=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
  $publisherAfter=Read-Json $publisherStatePath
  if($infoBefore -and [int]$infoBefore.LastTaskResult -eq 0 -and $infoAfter -and [string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and [int]$infoAfter.LastTaskResult -ne 0){$parityFailure="Task exit changed from 0 to $([int]$infoAfter.LastTaskResult)"}
  if(-not $parityFailure -and $publisherBefore -and [bool]$publisherBefore.ok -and $publisherAfter -and -not [bool]$publisherAfter.ok){$parityFailure='Publisher state regressed from ok=true to ok=false.'}
  if($parityFailure){
    try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
    Set-ScheduledTask -TaskName $taskName -Action $oldAction|Out-Null
    Start-ScheduledTask -TaskName $taskName
    $restored=$true
    $changed=$false
    $status='rollback-parity-failure'
  }else{$status='remediated-live'}
}else{
  $status='unexpected-target-action-audit-only'
}

$afterAudit=@(Task-Audit)
$remaining=@($afterAudit|Where-Object {$_.consoleRisk})
$currentTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$currentAction=$(if($currentTask){@($currentTask.Actions)[0]}else{$null})
$result=[ordered]@{
  schema=2
  ok=($status -in @('already-remediated-live-verified','remediated-live'))
  status=$status
  host=$env:COMPUTERNAME
  targetTask=$taskName
  changed=$changed
  restored=$restored
  parityFailure=$parityFailure
  principalPreserved=$true
  targetExecute=$(if($currentAction){[string]$currentAction.Execute}else{$null})
  targetArguments=$(if($currentAction){[string]$currentAction.Arguments}else{$null})
  auditBefore=$beforeAudit
  auditAfter=$afterAudit
  remainingRiskCount=$remaining.Count
  remainingRiskTasks=$remaining
  updatedAt=(Get-Date -Format o)
}
Emit $result
exit 0
'@

  $stdin=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV2-In-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $stdout=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV2-Out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderr=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV2-Err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($stdin,$remote,[Text.Encoding]::ASCII)
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
    if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};throw 'H3 console-flash V2 remediation timed out after 120 seconds'}
    $p.WaitForExit()
    $exit=[int]$p.ExitCode
    $outText=$(if(Test-Path -LiteralPath $stdout){[IO.File]::ReadAllText($stdout)}else{''})
    $errText=$(if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''})
    $jsonLine=@(($outText -split "`r?`n")|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    $remoteResult=$null
    if($jsonLine){try{$remoteResult=$jsonLine|ConvertFrom-Json}catch{}}
    if($exit -ne 0){throw "H3 console-flash V2 remediation failed exit=$exit stdout=$outText stderr=$errText"}
    if(-not $remoteResult){throw "H3 console-flash V2 returned no JSON result: stdout=$outText stderr=$errText"}
  }finally{Remove-Item -LiteralPath $stdin,$stdout,$stderr -Force -ErrorAction SilentlyContinue}

  $result=[ordered]@{schema=2;ok=[bool]$remoteResult.ok;status=[string]$remoteResult.status;target=$targetHost;syncedSha=$SyncedSha;remote=$remoteResult;updatedAt=(Get-Date -Format o)}
  Save $result
}catch{
  $failed=[ordered]@{schema=2;ok=$false;status='failed';target=$targetHost;syncedSha=$SyncedSha;error=$_.Exception.Message;updatedAt=(Get-Date -Format o)}
  Save $failed
  exit 1
}
