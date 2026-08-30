#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

# GitHub-primary H3 console-flash self-heal. Recurring short-lived tasks are
# tested after conversion. Long-running/logon workers are future-launch-only:
# their definitions may be changed, but their live processes are never stopped
# or started. Known manual interactive runners remain explicit exemptions.
$targetHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-console-flash-remediation'
$stateFile=Join-Path $root 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Save($Object){
  [IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 80 -Compress),$utf8)
  Write-Output ($Object|ConvertTo-Json -Depth 80 -Compress)
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
$remoteState='C:\ProgramData\AFZ\H3GitHubDirect\console-flash-remediation-v4.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-CONSOLE-FLASH-AUDIT-LATEST.json'
$runPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$manualInteractiveExemptions=@('AFZ H3 Qwen Ridge16K Runner')
if(-not(Test-Path -LiteralPath $wscript -PathType Leaf)){throw "wscript.exe missing: $wscript"}

$testedTargets=@(
  [pscustomobject]@{Task='AFZ H3 GitHub Direct Return Publisher';ExpectedScript='C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1';Launcher='C:\AFZ\GitHubDirect\Run-H3-GitHub-DirectReturn-Hidden.vbs';Optional=$false;TestSeconds=75},
  [pscustomobject]@{Task='AFZ H3 Ollama Cloud Telemetry Watchdog';ExpectedScript='C:\AFZ\H3Worker\Ensure-H3-OllamaCloudTelemetry.ps1';Launcher='C:\AFZ\H3Worker\Run-Ensure-H3-OllamaCloudTelemetry-Hidden.vbs';Optional=$true;TestSeconds=25},
  [pscustomobject]@{Task='AFZ Ops 35B Watchdog';ExpectedScript='C:\AFZ\Ops35B\AFZ-Ops35B-H3-Watchdog.ps1';Launcher='C:\AFZ\Ops35B\Run-AFZ-Ops35B-H3-Watchdog-Hidden.vbs';Optional=$true;TestSeconds=25}
)
$futureTargets=@(
  [pscustomobject]@{Task='AFZ H3 Direct Worker';ExpectedScript='C:\ProgramData\AFZ\H3Direct\AFZ-H3-Direct-Worker.ps1';Launcher='C:\ProgramData\AFZ\H3Direct\Run-AFZ-H3-Direct-Worker-Task-Hidden.vbs';Optional=$true},
  [pscustomobject]@{Task='AFZ H3 Generic Worker';ExpectedScript='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1';Launcher='C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Task-Hidden.vbs';Optional=$true},
  [pscustomobject]@{Task='AFZ Ops 35B Planner';ExpectedScript='C:\AFZ\Ops35B\AFZ-Ops35B-H3-Worker.ps1';Launcher='C:\AFZ\Ops35B\Run-AFZ-Ops35B-H3-Worker-Task-Hidden.vbs';Optional=$true},
  [pscustomobject]@{Task='AFZ RadioHilal35B Worker';ExpectedScript='C:\OpenWebUI\RadioHilal35B\RadioHilal35B-WorkerLoop.ps1';Launcher='C:\OpenWebUI\RadioHilal35B\Run-RadioHilal35B-Worker-Task-Hidden.vbs';Optional=$true}
)
$runTargets=@(
  [pscustomobject]@{Name='AFZ H3 Generic Worker';ExpectedScript='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1';Launcher='C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Run-Hidden.vbs';Optional=$true},
  [pscustomobject]@{Name='AFZ H3 Ollama Telemetry';ExpectedScript='C:\AFZ\H3Worker\AFZ-H3-OllamaTelemetry.ps1';Launcher='C:\AFZ\H3Worker\Run-AFZ-H3-OllamaTelemetry-Run-Hidden.vbs';Optional=$true},
  [pscustomobject]@{Name='AFZ Ops 35B Planner';ExpectedScript='C:\AFZ\Ops35B\AFZ-Ops35B-H3-Worker.ps1';Launcher='C:\AFZ\Ops35B\Run-AFZ-Ops35B-H3-Worker-Run-Hidden.vbs';Optional=$true}
)

function Fmt-Date($Value){if($null -eq $Value){return $null};try{return ([datetime]$Value).ToString('o')}catch{return [string]$Value}}
function Leaf([string]$Exe){if([string]::IsNullOrWhiteSpace($Exe)){return ''};try{return [IO.Path]::GetFileName($Exe).ToLowerInvariant()}catch{return ''}}
function Is-ConsoleExecutable([string]$Exe){return ((Leaf $Exe) -in @('powershell.exe','pwsh.exe','cmd.exe','python.exe','python3.exe','py.exe','ssh.exe','git.exe','robocopy.exe','ffmpeg.exe','node.exe','npm.cmd','npx.cmd'))}
function Task-Snapshot([string]$Name){
  $t=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if(-not $t){return $null}
  $i=Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
  $actions=@($t.Actions);$a=$(if($actions.Count -gt 0){$actions[0]}else{$null})
  return [pscustomobject]@{task=$Name;state=[string]$t.State;user=[string]$t.Principal.UserId;logonType=[string]$t.Principal.LogonType;runLevel=[string]$t.Principal.RunLevel;actionCount=$actions.Count;execute=$(if($a){[string]$a.Execute}else{$null});arguments=$(if($a){[string]$a.Arguments}else{$null});lastRunTime=$(if($i){Fmt-Date $i.LastRunTime}else{$null});nextRunTime=$(if($i){Fmt-Date $i.NextRunTime}else{$null});lastTaskResult=$(if($i){[long]$i.LastTaskResult}else{$null})}
}
function Get-ScriptPids([string]$Script){
  return @((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.CommandLine -and $_.CommandLine -like ('*'+$Script+'*')}|Select-Object -ExpandProperty ProcessId|ForEach-Object {[int]$_})|Sort-Object -Unique)
}
function Task-Audit {
  $rows=@()
  foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like 'AFZ*' -or $_.TaskName -match 'H3' -or $_.TaskName -eq 'OpenWebUI Server'})){
    $i=Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
    $triggers=@($t.Triggers|ForEach-Object {[ordered]@{type=$_.CimClass.CimClassName;startBoundary=[string]$_.StartBoundary;enabled=$(if($null -eq $_.Enabled){$null}else{[bool]$_.Enabled});repetitionInterval=$(if($_.Repetition){[string]$_.Repetition.Interval}else{$null});repetitionDuration=$(if($_.Repetition){[string]$_.Repetition.Duration}else{$null})}})
    foreach($a in @($t.Actions)){
      $interactive=([string]$t.Principal.LogonType -match 'Interactive');$console=Is-ConsoleExecutable ([string]$a.Execute)
      $rows += [pscustomobject]@{task=[string]$t.TaskName;taskPath=[string]$t.TaskPath;state=[string]$t.State;enabled=[bool]$t.Settings.Enabled;user=[string]$t.Principal.UserId;logonType=[string]$t.Principal.LogonType;runLevel=[string]$t.Principal.RunLevel;execute=[string]$a.Execute;arguments=[string]$a.Arguments;interactive=$interactive;directConsole=$console;consoleRisk=($interactive -and $console);lastRunTime=$(if($i){Fmt-Date $i.LastRunTime}else{$null});nextRunTime=$(if($i){Fmt-Date $i.NextRunTime}else{$null});lastTaskResult=$(if($i){[long]$i.LastTaskResult}else{$null});triggers=$triggers}
    }
  }
  return @($rows)
}
function Run-Audit {
  $rows=@();if(-not(Test-Path $runPath)){return @($rows)}
  $p=Get-ItemProperty -Path $runPath
  foreach($prop in @($p.PSObject.Properties|Where-Object {$_.Name -like 'AFZ *'})){
    $cmd=[string]$prop.Value;$direct=($cmd -match '(?i)^\s*"?(?:[^"\s]*\\)?(?:powershell|pwsh|cmd)\.exe\b')
    $rows += [pscustomobject]@{name=$prop.Name;command=$cmd;directConsole=$direct;consoleRisk=$direct}
  }
  return @($rows)
}
function Write-HiddenLauncher([string]$Launcher,[string]$Command){
  $parent=Split-Path $Launcher -Parent;if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
  $escaped=$Command.Replace('"','""')
  $vbs=@('Option Explicit','Dim shell, cmd, rc','Set shell = CreateObject("WScript.Shell")',('cmd = "'+$escaped+'"'),'rc = shell.Run(cmd, 0, True)','WScript.Quit rc') -join "`r`n"
  [IO.File]::WriteAllText($Launcher,$vbs,$utf8)
}
function New-CommandFromAction($Snapshot){
  $exe=[string]$Snapshot.execute;$args=[string]$Snapshot.arguments
  if($exe -match '\s' -or $exe -match '\\'){return ('"'+$exe+'" '+$args).Trim()}
  return ($exe+' '+$args).Trim()
}
function Ensure-TestedTask($Spec){
  $before=Task-Snapshot ([string]$Spec.Task)
  if(-not $before){return [pscustomobject]@{task=$Spec.Task;ok=[bool]$Spec.Optional;status=$(if($Spec.Optional){'not-installed'}else{'missing'});changed=$false}}
  if($before.actionCount -ne 1){return [pscustomobject]@{task=$Spec.Task;ok=$false;status='unexpected-action-count';changed=$false;before=$before}}
  $leaf=Leaf ([string]$before.execute)
  if($leaf -eq 'wscript.exe' -and [string]$before.arguments -like ('*'+[string]$Spec.Launcher+'*')){return [pscustomobject]@{task=$Spec.Task;ok=$true;status='already-hidden-live-verified';changed=$false;before=$before;after=$before}}
  if($leaf -notin @('powershell.exe','pwsh.exe') -or [string]$before.arguments -notlike ('*'+[string]$Spec.ExpectedScript+'*') -or [string]$before.logonType -notmatch 'Interactive'){return [pscustomobject]@{task=$Spec.Task;ok=$false;status='unexpected-contract-audit-only';changed=$false;before=$before}}
  if(-not(Test-Path -LiteralPath ([string]$Spec.ExpectedScript) -PathType Leaf)){return [pscustomobject]@{task=$Spec.Task;ok=$false;status='expected-script-missing';changed=$false;before=$before}}
  $oldAction=New-ScheduledTaskAction -Execute ([string]$before.execute) -Argument ([string]$before.arguments)
  try{
    Write-HiddenLauncher ([string]$Spec.Launcher) (New-CommandFromAction $before)
    $newAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+[string]$Spec.Launcher+'"')
    try{Stop-ScheduledTask -TaskName ([string]$Spec.Task) -ErrorAction SilentlyContinue}catch{}
    Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $newAction|Out-Null
    $afterSet=Task-Snapshot ([string]$Spec.Task)
    if(-not $afterSet -or $afterSet.user -ne $before.user -or $afterSet.logonType -ne $before.logonType -or $afterSet.runLevel -ne $before.runLevel){Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $oldAction|Out-Null;return [pscustomobject]@{task=$Spec.Task;ok=$false;status='principal-mismatch-rolled-back';changed=$false;before=$before;after=(Task-Snapshot ([string]$Spec.Task))}}
    Start-ScheduledTask -TaskName ([string]$Spec.Task)
    $deadline=(Get-Date).AddSeconds([int]$Spec.TestSeconds)
    do{Start-Sleep -Milliseconds 500;$probe=Get-ScheduledTask -TaskName ([string]$Spec.Task) -ErrorAction SilentlyContinue;if($probe -and [string]$probe.State -ne 'Running'){break}}while((Get-Date) -lt $deadline)
    $after=Task-Snapshot ([string]$Spec.Task)
    if($null -ne $before.lastTaskResult -and [long]$before.lastTaskResult -eq 0 -and $after -and $after.state -ne 'Running' -and $null -ne $after.lastTaskResult -and [long]$after.lastTaskResult -ne 0){
      try{Stop-ScheduledTask -TaskName ([string]$Spec.Task) -ErrorAction SilentlyContinue}catch{};Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $oldAction|Out-Null;Start-ScheduledTask -TaskName ([string]$Spec.Task)
      return [pscustomobject]@{task=$Spec.Task;ok=$false;status='test-regression-rolled-back';changed=$false;reason=('task-result-regressed-from-0-to-'+[string]$after.lastTaskResult);before=$before;failedAfter=$after;after=(Task-Snapshot ([string]$Spec.Task))}
    }
    return [pscustomobject]@{task=$Spec.Task;ok=$true;status='hidden-launcher-installed';changed=$true;launcher=$Spec.Launcher;before=$before;after=$after}
  }catch{return [pscustomobject]@{task=$Spec.Task;ok=$false;status='error';changed=$false;error=$_.Exception.Message;before=$before}}
}
function Ensure-NoWindowFutureTask($Spec){
  # FUTURE-LAUNCH-ONLY: this function intentionally contains no task start/stop
  # or process termination. Existing long-running worker PIDs are observational.
  $before=Task-Snapshot ([string]$Spec.Task)
  if(-not $before){return [pscustomobject]@{task=$Spec.Task;ok=[bool]$Spec.Optional;status='not-installed';changed=$false}}
  if($before.actionCount -ne 1){return [pscustomobject]@{task=$Spec.Task;ok=$false;status='unexpected-action-count';changed=$false;before=$before}}
  $pidsBefore=Get-ScriptPids ([string]$Spec.ExpectedScript);$leaf=Leaf ([string]$before.execute)
  if($leaf -eq 'wscript.exe' -and [string]$before.arguments -like ('*'+[string]$Spec.Launcher+'*')){return [pscustomobject]@{task=$Spec.Task;ok=$true;status='future-launch-already-hidden';changed=$false;before=$before;after=$before;pidsBefore=$pidsBefore;pidsAfter=(Get-ScriptPids ([string]$Spec.ExpectedScript))}}
  if($leaf -notin @('powershell.exe','pwsh.exe') -or [string]$before.arguments -notlike ('*'+[string]$Spec.ExpectedScript+'*') -or [string]$before.logonType -notmatch 'Interactive'){return [pscustomobject]@{task=$Spec.Task;ok=$false;status='unexpected-contract-audit-only';changed=$false;before=$before;pidsBefore=$pidsBefore}}
  if(-not(Test-Path -LiteralPath ([string]$Spec.ExpectedScript) -PathType Leaf)){return [pscustomobject]@{task=$Spec.Task;ok=$false;status='expected-script-missing';changed=$false;before=$before}}
  $oldAction=New-ScheduledTaskAction -Execute ([string]$before.execute) -Argument ([string]$before.arguments)
  try{
    Write-HiddenLauncher ([string]$Spec.Launcher) (New-CommandFromAction $before)
    $newAction=New-ScheduledTaskAction -Execute $wscript -Argument ('//B //Nologo "'+[string]$Spec.Launcher+'"')
    Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $newAction|Out-Null
    $after=Task-Snapshot ([string]$Spec.Task);$pidsAfter=Get-ScriptPids ([string]$Spec.ExpectedScript)
    if(-not $after -or $after.user -ne $before.user -or $after.logonType -ne $before.logonType -or $after.runLevel -ne $before.runLevel){Set-ScheduledTask -TaskName ([string]$Spec.Task) -Action $oldAction|Out-Null;return [pscustomobject]@{task=$Spec.Task;ok=$false;status='principal-mismatch-rolled-back';changed=$false;before=$before;after=(Task-Snapshot ([string]$Spec.Task));pidsBefore=$pidsBefore;pidsAfter=$pidsAfter}}
    return [pscustomobject]@{task=$Spec.Task;ok=$true;status='future-launch-hidden-live-instance-preserved';changed=$true;launcher=$Spec.Launcher;before=$before;after=$after;pidsBefore=$pidsBefore;pidsAfter=$pidsAfter;pidSetPreserved=(($pidsBefore -join ',') -eq ($pidsAfter -join ','))}
  }catch{return [pscustomobject]@{task=$Spec.Task;ok=$false;status='error';changed=$false;error=$_.Exception.Message;before=$before;pidsBefore=$pidsBefore;pidsAfter=(Get-ScriptPids ([string]$Spec.ExpectedScript))}}
}
function Ensure-NoWindowRun($Spec){
  if(-not(Test-Path $runPath)){return [pscustomobject]@{name=$Spec.Name;ok=$false;status='run-key-missing';changed=$false}}
  $props=Get-ItemProperty -Path $runPath
  $property=$props.PSObject.Properties[[string]$Spec.Name]
  if($null -eq $property){return [pscustomobject]@{name=$Spec.Name;ok=[bool]$Spec.Optional;status='not-installed';changed=$false}}
  $before=[string]$property.Value
  if($before -match '(?i)wscript\.exe' -and $before -like ('*'+[string]$Spec.Launcher+'*')){return [pscustomobject]@{name=$Spec.Name;ok=$true;status='future-login-already-hidden';changed=$false;before=$before;after=$before}}
  if($before -notmatch '(?i)^\s*"?(?:[^"\s]*\\)?(?:powershell|pwsh)\.exe\b' -or $before -notlike ('*'+[string]$Spec.ExpectedScript+'*')){return [pscustomobject]@{name=$Spec.Name;ok=$false;status='unexpected-contract-audit-only';changed=$false;before=$before}}
  try{
    Write-HiddenLauncher ([string]$Spec.Launcher) $before
    $after='"'+$wscript+'" //B //Nologo "'+[string]$Spec.Launcher+'"'
    Set-ItemProperty -Path $runPath -Name ([string]$Spec.Name) -Value $after
    $verify=[string](Get-ItemProperty -Path $runPath).PSObject.Properties[[string]$Spec.Name].Value
    if($verify -ne $after){Set-ItemProperty -Path $runPath -Name ([string]$Spec.Name) -Value $before;return [pscustomobject]@{name=$Spec.Name;ok=$false;status='verify-failed-rolled-back';changed=$false;before=$before;after=$verify}}
    return [pscustomobject]@{name=$Spec.Name;ok=$true;status='future-login-hidden';changed=$true;before=$before;after=$after;launcher=$Spec.Launcher}
  }catch{return [pscustomobject]@{name=$Spec.Name;ok=$false;status='error';changed=$false;before=$before;error=$_.Exception.Message}}
}
function Publish-Diagnostic($Object){New-Item -ItemType Directory -Force -Path (Split-Path $remoteState -Parent)|Out-Null;[IO.File]::WriteAllText($remoteState,($Object|ConvertTo-Json -Depth 80 -Compress),$utf8);try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagFile,($Object|ConvertTo-Json -Depth 80),$utf8)}}catch{}}

$beforeAudit=@(Task-Audit);$beforeRun=@(Run-Audit)
$testedResults=@();foreach($target in $testedTargets){$testedResults += Ensure-TestedTask $target}
$futureResults=@();foreach($target in $futureTargets){$futureResults += Ensure-NoWindowFutureTask $target}
$runResults=@();foreach($target in $runTargets){$runResults += Ensure-NoWindowRun $target}
$afterAudit=@(Task-Audit);$afterRun=@(Run-Audit)
$remaining=@($afterAudit|Where-Object {$_.consoleRisk -and $manualInteractiveExemptions -notcontains $_.task})
$periodicRemaining=@($remaining|Where-Object {@($_.triggers|Where-Object {[string]$_.repetitionInterval}).Count -gt 0})
$logonRemaining=@($remaining|Where-Object {@($_.triggers|Where-Object {$_.type -match 'Logon'}).Count -gt 0})
$runRemaining=@($afterRun|Where-Object {$_.consoleRisk})
$manualRows=@($afterAudit|Where-Object {$manualInteractiveExemptions -contains $_.task})
$bad=@($testedResults+$futureResults+$runResults|Where-Object {-not $_.ok})
$result=[ordered]@{schema=4;ok=($bad.Count -eq 0);status=$(if($bad.Count -eq 0){'completed'}else{'partial-or-blocked'});host=$env:COMPUTERNAME;testedTargets=$testedResults;futureTargets=$futureResults;runTargets=$runResults;beforeRiskCount=@($beforeAudit|Where-Object {$_.consoleRisk}).Count;afterRiskCount=@($afterAudit|Where-Object {$_.consoleRisk}).Count;periodicConsoleRiskCount=$periodicRemaining.Count;logonTaskConsoleRiskCount=$logonRemaining.Count;hkcuRunConsoleRiskCount=$runRemaining.Count;periodicConsoleRisks=$periodicRemaining;logonTaskConsoleRisks=$logonRemaining;hkcuRunConsoleRisks=$runRemaining;manualInteractiveExemptions=$manualRows;auditBefore=$beforeAudit;auditAfter=$afterAudit;runAuditBefore=$beforeRun;runAuditAfter=$afterRun;updatedAt=(Get-Date -Format o)}
Publish-Diagnostic $result
Write-Output ($result|ConvertTo-Json -Depth 80 -Compress)
exit 0
'@

  $stdin=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV4-In-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $stdout=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV4-Out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderr=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlashV4-Err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($stdin,$remote,[Text.Encoding]::ASCII)
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
    if(-not $p.WaitForExit(210000)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};throw 'H3 console-flash V4 remediation timed out after 210 seconds'}
    $p.WaitForExit();$exit=[int]$p.ExitCode
    $outText=$(if(Test-Path -LiteralPath $stdout){[IO.File]::ReadAllText($stdout)}else{''});$errText=$(if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''})
    $jsonLine=@(($outText -split "`r?`n")|Where-Object {$_ -match '^\{.*\}$'}|Select-Object -Last 1);$remoteResult=$null
    if($jsonLine){try{$remoteResult=$jsonLine|ConvertFrom-Json}catch{}}
    if($exit -ne 0){throw "H3 console-flash V4 remediation failed exit=$exit stdout=$outText stderr=$errText"}
    if(-not $remoteResult){throw "H3 console-flash V4 returned no JSON result: stdout=$outText stderr=$errText"}
  }finally{Remove-Item -LiteralPath $stdin,$stdout,$stderr -Force -ErrorAction SilentlyContinue}

  Save ([ordered]@{schema=4;ok=[bool]$remoteResult.ok;status=[string]$remoteResult.status;target=$targetHost;syncedSha=$SyncedSha;remote=$remoteResult;updatedAt=(Get-Date -Format o)})
}catch{
  Save ([ordered]@{schema=4;ok=$false;status='failed';target=$targetHost;syncedSha=$SyncedSha;error=$_.Exception.Message;updatedAt=(Get-Date -Format o)})
  exit 1
}
