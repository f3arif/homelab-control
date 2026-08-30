#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

# GitHub-primary live recheck for H3 console flashes. This helper never trusts
# prior success markers. On every source sync it verifies the three known
# Interactive recurring/return tasks and changes only an exact legacy direct
# PowerShell action to a wscript.exe hidden launcher. Principals, triggers,
# settings, script paths and task names are preserved. Unexpected contracts are
# audit-only, and a previously-successful task is rolled back on test failure.
$targetHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-console-flash-remediation'
$stateFile=Join-Path $root 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Save($Object){
  [IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 60 -Compress),$utf8)
  Write-Output ($Object|ConvertTo-Json -Depth 60 -Compress)
}

try{
  if(-not(Test-Path -LiteralPath $key -PathType Leaf)){throw "SYSTEM H3 SSH key missing: $key"}
  if(-not(Test-Path -LiteralPath $known -PathType Leaf)){throw "H3 known-hosts file missing: $known"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source

  $remote=@'
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong host: $env:COMPUTERNAME"}
$utf8=New-Object Text.UTF8Encoding($false)
$wscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
$powerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$remoteState='C:\ProgramData\AFZ\H3GitHubDirect\console-flash-remediation-v3.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-CONSOLE-FLASH-AUDIT-LATEST.json'
if(-not(Test-Path -LiteralPath $wscript -PathType Leaf)){throw "wscript.exe missing: $wscript"}
if(-not(Test-Path -LiteralPath $powerShell -PathType Leaf)){throw "Windows PowerShell missing: $powerShell"}

$targets=@(
  [pscustomobject]@{
    Task='AFZ H3 GitHub Direct Return Publisher'
    ExpectedScript='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1'
    Launcher='C:\AFZ\GitHubDirect\Run-H3-GitHub-DirectReturn-Hidden.vbs'
    Optional=$false
    TestSeconds=75
  },
  [pscustomobject]@{
    Task='AFZ H3 Ollama Cloud Telemetry Watchdog'
    ExpectedScript='C:\AFZ\H3Worker\Ensure-H3-OllamaCloudTelemetry.ps1'
    Launcher='C:\AFZ\H3Worker\Run-Ensure-H3-OllamaCloudTelemetry-Hidden.vbs'
    Optional=$true
    TestSeconds=25
  },
  [pscustomobject]@{
    Task='AFZ Ops 35B Watchdog'
    ExpectedScript='C:\AFZ\Ops35B\AFZ-Ops35B-H3-Watchdog.ps1'
    Launcher='C:\AFZ\Ops35B\Run-AFZ-Ops35B-H3-Watchdog-Hidden.vbs'
    Optional=$true
    TestSeconds=25
  }
)

function Fmt-Date($Value){
  if($null -eq $Value){return $null}
  try{return ([datetime]$Value).ToString('o')}catch{return [string]$Value}
}
function Leaf([string]$Exe){
  if([string]::IsNullOrWhiteSpace($Exe)){return ''}
  try{return [IO.Path]::GetFileName($Exe).ToLowerInvariant()}catch{return ''}
}
function Is-ConsoleExecutable([string]$Exe){
  return ((Leaf $Exe) -in @('powershell.exe','pwsh.exe','cmd.exe','python.exe','python3.exe','py.exe','ssh.exe','git.exe','robocopy.exe','ffmpeg.exe','node.exe','npm.cmd','npx.cmd'))
}
function Snapshot([string]$Name){
  $t=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if(-not $t){return $null}
  $i=Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
  $actions=@($t.Actions)
  $a=$(if($actions.Count -gt 0){$actions[0]}else{$null})
  return [pscustomobject]@{
    task=$Name
    state=[string]$t.State
    user=[string]$t.Principal.UserId
    logonType=[string]$t.Principal.LogonType
    runLevel=[string]$t.Principal.RunLevel
    actionCount=$actions.Count
    execute=$(if($a){[string]$a.Execute}else{$null})
    arguments=$(if($a){[string]$a.Arguments}else{$null})
    lastRunTime=$(if($i){Fmt-Date $i.LastRunTime}else{$null})
    nextRunTime=$(if($i){Fmt-Date $i.NextRunTime}else{$null})
    lastTaskResult=$(if($i){[int]$i.LastTaskResult}else{$null})
  }
}
function Task-Audit {
  $rows=@()
  foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -like 'AFZ*' -or $_.TaskName -match 'H3' -or $_.TaskName -eq 'OpenWebUI Server'
  })){
    $i=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
    $triggers=@($t.Triggers|ForEach-Object {
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
        lastRunTime=$(if($i){Fmt-Date $i.LastRunTime}else{$null})
        nextRunTime=$(if($i){Fmt-Date $i.NextRunTime}else{$null})
        lastTaskResult=$(if($i){[int]$i.LastTaskResult}else{$null})
        triggers=$triggers
      }
    }
  }
  return @($rows)
}
function Write-HiddenLauncher([string]$Launcher,[string]$Arguments){
  $parent=Split-Path $Launcher -Parent
  if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  $cmd='"'+$powerShell+'" '+$Arguments
  $escaped=$cmd.Replace('"','""')
  $vbs=@(
    'Option Explicit',
    'Dim shell, cmd, rc',
    'Set shell = CreateObject("WScript.Shell")',
    ('cmd = "'+$escaped+'"'),
    'rc = shell.Run(cmd, 0, True)',
    'WScript.Quit rc'
  ) -join "`r`n"
  [IO.File]::WriteAllText($Launcher,$vbs,$utf8)
}
function Ensure-NoWindowTask($Spec){
  $before=Snapshot ([string]$Spec.Task)
  if(-not $before){
    return [pscustomobject]@{task=$Spec.Task;ok=[bool]$Spec.Optional;status=$(if($Spec.Optional){'not-installed'}else{'missing'});changed=$false;before=$null;after=$null}
  }
  if($before.actionCount -ne 1){
    return [pscustomobject]@{task=$Spec.Task;ok=$false;status='unexpected-action-count';changed=$false;before=$before;after=$before}
  }
  $leaf=Leaf ([string]$before.execute)
  if($leaf -eq 'wscript.exe' -and [string]$before.arguments -like ('*'+[string]$Spec.Launcher+'*')){
    return [pscustomobject]@{task=$Spec.Task;ok=$true;status='already-hidden-live-verified';changed=$false;before=$before;after=$before}
  }
  if($leaf -notin @('powershell.exe','pwsh.exe') -or [string]$before.arguments -notlike ('*'+[string]$Spec.ExpectedScript+'*') -or [string]$before.logonType -notmatch 'Interactive'){
    return [pscustomobject]@{task=$Spec.Task;ok=$false;status='unexpected-contract-audit-only';changed=$false;before=$before;after=$before}
  }
  if(-not(Test-Path -LiteralPath ([string]$Spec.ExpectedScript) -PathType Leaf)){
    return [pscustomobject]@{task=$Spec.Task;ok=$false;status='expected-script-missing';changed=$false;before=$before;after=$before}
  }

  $oldAction=New-ScheduledTaskAction -Execute ([string]$before.execute) -Argument ([string]$before.arguments)
  Write-HiddenLauncher -Launcher ([string]$Spec.Launcher) -Arguments ([string]$before.arguments)
  $newAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+[string]$Spec.Launcher+'"')
  try{Stop-ScheduledTask -TaskName ([string]$Spec.Task) -ErrorAction SilentlyContinue}catch{}
  Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $newAction|Out-Null

  $afterSet=Snapshot ([string]$Spec.Task)
  if(-not $afterSet -or $afterSet.user -ne $before.user -or $afterSet.logonType -ne $before.logonType -or $afterSet.runLevel -ne $before.runLevel){
    Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $oldAction|Out-Null
    return [pscustomobject]@{task=$Spec.Task;ok=$false;status='principal-mismatch-rolled-back';changed=$false;before=$before;after=(Snapshot ([string]$Spec.Task))}
  }

  Start-ScheduledTask -TaskName ([string]$Spec.Task)
  $deadline=(Get-Date).AddSeconds([int]$Spec.TestSeconds)
  do{
    Start-Sleep -Milliseconds 500
    $probe=Get-ScheduledTask -TaskName ([string]$Spec.Task) -ErrorAction SilentlyContinue
    if($probe -and [string]$probe.State -ne 'Running'){break}
  }while((Get-Date) -lt $deadline)
  $after=Snapshot ([string]$Spec.Task)

  $regression=$false
  $reason=$null
  if($null -ne $before.lastTaskResult -and [int]$before.lastTaskResult -eq 0 -and $after -and $after.state -ne 'Running' -and $null -ne $after.lastTaskResult -and [int]$after.lastTaskResult -ne 0){
    $regression=$true
    $reason='task-result-regressed-from-0-to-'+[string]$after.lastTaskResult
  }
  if($regression){
    try{Stop-ScheduledTask -TaskName ([string]$Spec.Task) -ErrorAction SilentlyContinue}catch{}
    Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $oldAction|Out-Null
    Start-ScheduledTask -TaskName ([string]$Spec.Task)
    return [pscustomobject]@{task=$Spec.Task;ok=$false;status='test-regression-rolled-back';changed=$false;reason=$reason;before=$before;failedAfter=$after;after=(Snapshot ([string]$Spec.Task))}
  }
  return [pscustomobject]@{task=$Spec.Task;ok=$true;status='hidden-launcher-installed';changed=$true;launcher=$Spec.Launcher;before=$before;after=$after}
}
function Publish-Diagnostic($Object){
  New-Item -ItemType Directory -Force -Path (Split-Path $remoteState -Parent)|Out-Null
  [IO.File]::WriteAllText($remoteState,($Object|ConvertTo-Json -Depth 60 -Compress),$utf8)
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagFile,($Object|ConvertTo-Json -Depth 60),$utf8)}}catch{}
}

$beforeAudit=@(Task-Audit)
$results=@()
foreach($target in $targets){$results += Ensure-NoWindowTask $target}
$afterAudit=@(Task-Audit)
$remaining=@($afterAudit|Where-Object {$_.consoleRisk})
$periodicRemaining=@($remaining|Where-Object {
  $hasRepeat=$false
  foreach($tr in @($_.triggers)){if([string]$tr.repetitionInterval){$hasRepeat=$true;break}}
  $hasRepeat
})
$bad=@($results|Where-Object {-not $_.ok})
$result=[ordered]@{
  schema=3
  ok=($bad.Count -eq 0)
  status=$(if($bad.Count -eq 0){'completed'}else{'partial-or-blocked'})
  host=$env:COMPUTERNAME
  targets=$results
  beforeRiskCount=@($beforeAudit|Where-Object {$_.consoleRisk}).Count
  afterRiskCount=$remaining.Count
  periodicConsoleRiskCount=$periodicRemaining.Count
  periodicConsoleRisks=$periodicRemaining
  auditBefore=$beforeAudit
  auditAfter=$afterAudit
  updatedAt=(Get-Date -Format o)
}
Publish-Diagnostic $result
Write-Output ($result|ConvertTo-Json -Depth 60 -Compress)
exit 0
'@

  $stdin=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV3-In-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $stdout=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV3-Out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderr=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV3-Err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($stdin,$remote,[Text.Encoding]::ASCII)
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
    if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};throw 'H3 console-flash V3 remediation timed out after 180 seconds'}
    $p.WaitForExit()
    $exit=[int]$p.ExitCode
    $outText=$(if(Test-Path -LiteralPath $stdout){[IO.File]::ReadAllText($stdout)}else{''})
    $errText=$(if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''})
    $jsonLine=@(($outText -split "`r?`n")|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    $remoteResult=$null
    if($jsonLine){try{$remoteResult=$jsonLine|ConvertFrom-Json}catch{}}
    if($exit -ne 0){throw "H3 console-flash V3 remediation failed exit=$exit stdout=$outText stderr=$errText"}
    if(-not $remoteResult){throw "H3 console-flash V3 returned no JSON result: stdout=$outText stderr=$errText"}
  }finally{Remove-Item -LiteralPath $stdin,$stdout,$stderr -Force -ErrorAction SilentlyContinue}

  Save ([ordered]@{schema=3;ok=[bool]$remoteResult.ok;status=[string]$remoteResult.status;target=$targetHost;syncedSha=$SyncedSha;remote=$remoteResult;updatedAt=(Get-Date -Format o)})
}catch{
  Save ([ordered]@{schema=3;ok=$false;status='failed';target=$targetHost;syncedSha=$SyncedSha;error=$_.Exception.Message;updatedAt=(Get-Date -Format o)})
  exit 1
}
