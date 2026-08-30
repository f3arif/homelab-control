#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

# Narrow one-time launcher remediation for DESKTOP-H3R6CQN. This does not
# migrate the worker language, change queue ownership, change the task user,
# launch Qwen, or touch unrelated scheduled tasks.
$targetHost='DESKTOP-H3R6CQN'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$h3='Faiz@100.106.186.118'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-console-flash-remediation'
$stateFile=Join-Path $root 'latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}
}
function Save($Object){
  [IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 40 -Compress),$utf8)
  Write-Output ($Object|ConvertTo-Json -Depth 40 -Compress)
}

$prior=Read-Json $stateFile
if($prior -and [int]$prior.schema -eq 1 -and [bool]$prior.ok -and [string]$prior.status -in @('completed','already-remediated')){
  $cached=[ordered]@{schema=1;ok=$true;status='cached-completed';target=$targetHost;remediationVersion=1;syncedSha=$SyncedSha;prior=$prior;updatedAt=(Get-Date -Format o)}
  Write-Output ($cached|ConvertTo-Json -Depth 40 -Compress)
  exit 0
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
$remoteState='C:\ProgramData\AFZ\H3GitHubDirect\console-flash-remediation.json'
$utf8=New-Object Text.UTF8Encoding($false)

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Task-Audit {
  $rows=@()
  foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {$_.TaskName -like 'AFZ*' -or $_.TaskName -match 'H3'})){
    foreach($a in @($t.Actions)){
      $exe=[string]$a.Execute
      $leaf=[IO.Path]::GetFileName($exe).ToLowerInvariant()
      $interactive=([string]$t.Principal.LogonType -match 'Interactive')
      $directConsole=($leaf -in @('powershell.exe','pwsh.exe','cmd.exe','python.exe','ssh.exe','git.exe','robocopy.exe','ffmpeg.exe'))
      $rows += [pscustomobject]@{
        task=[string]$t.TaskName
        state=[string]$t.State
        user=[string]$t.Principal.UserId
        logonType=[string]$t.Principal.LogonType
        execute=$exe
        arguments=[string]$a.Arguments
        consoleRisk=($interactive -and $directConsole)
      }
    }
  }
  return @($rows)
}
function Save-Remote($Object){
  New-Item -ItemType Directory -Force -Path (Split-Path $remoteState -Parent)|Out-Null
  [IO.File]::WriteAllText($remoteState,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8)
}
function Emit($Object){Save-Remote $Object;Write-Output ($Object|ConvertTo-Json -Depth 30 -Compress)}

$beforeAudit=@(Task-Audit)
$t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $t){
  Emit ([ordered]@{schema=1;ok=$false;status='blocked-target-task-missing';host=$env:COMPUTERNAME;targetTask=$taskName;auditBefore=$beforeAudit;updatedAt=(Get-Date -Format o)})
  exit 3
}
$actions=@($t.Actions)
if($actions.Count -ne 1){
  Emit ([ordered]@{schema=1;ok=$false;status='blocked-unexpected-action-count';host=$env:COMPUTERNAME;targetTask=$taskName;actionCount=$actions.Count;auditBefore=$beforeAudit;updatedAt=(Get-Date -Format o)})
  exit 3
}
$a=$actions[0]
$execute=[string]$a.Execute
$args=[string]$a.Arguments
$principalBefore=[ordered]@{user=[string]$t.Principal.UserId;logonType=[string]$t.Principal.LogonType;runLevel=[string]$t.Principal.RunLevel}
$leaf=[IO.Path]::GetFileName($execute).ToLowerInvariant()

if($leaf -eq 'wscript.exe' -and $args -like "*$launcher*"){
  $afterAudit=@(Task-Audit)
  Emit ([ordered]@{schema=1;ok=$true;status='already-remediated';host=$env:COMPUTERNAME;targetTask=$taskName;principalPreserved=$true;launcher=$launcher;auditBefore=$beforeAudit;auditAfter=$afterAudit;updatedAt=(Get-Date -Format o)})
  exit 0
}

if($leaf -ne 'powershell.exe' -or $args -notlike '*Publish-H3-GitHub-DirectReturn-V3.ps1*'){
  Emit ([ordered]@{schema=1;ok=$false;status='blocked-unexpected-target-action';host=$env:COMPUTERNAME;targetTask=$taskName;execute=$execute;arguments=$args;auditBefore=$beforeAudit;updatedAt=(Get-Date -Format o)})
  exit 3
}
if(([string]$t.Principal.LogonType) -notmatch 'Interactive'){
  Emit ([ordered]@{schema=1;ok=$false;status='blocked-unexpected-principal';host=$env:COMPUTERNAME;targetTask=$taskName;principal=$principalBefore;auditBefore=$beforeAudit;updatedAt=(Get-Date -Format o)})
  exit 3
}
if(-not(Test-Path -LiteralPath $publisher -PathType Leaf)){
  Emit ([ordered]@{schema=1;ok=$false;status='blocked-publisher-missing';host=$env:COMPUTERNAME;targetTask=$taskName;publisher=$publisher;auditBefore=$beforeAudit;updatedAt=(Get-Date -Format o)})
  exit 3
}

$infoBefore=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
$publisherStatePath='C:\ProgramData\AFZ\H3GitHubDirect\return-publisher-v3.json'
$publisherBefore=Read-Json $publisherStatePath
$oldAction=New-ScheduledTaskAction -Execute $execute -Argument $args

# Do not nest a here-string inside the SSH payload here-string. Keep the
# remote payload parseable by Windows PowerShell 5.1.
$vbs=@(
  'Option Explicit',
  'Dim shell, ps, cmd, rc',
  'Set shell = CreateObject("WScript.Shell")',
  'ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")',
  'cmd = Chr(34) & ps & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Chr(34) & "C:\AFZ\GitHubDirect\Publish-H3-GitHub-DirectReturn-V3.ps1" & Chr(34)',
  'rc = shell.Run(cmd, 0, True)',
  'WScript.Quit rc'
) -join [Environment]::NewLine
[IO.File]::WriteAllText($launcher,$vbs,$utf8)

$wscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
if(-not(Test-Path -LiteralPath $wscript -PathType Leaf)){throw "wscript.exe missing: $wscript"}
$newAction=New-ScheduledTaskAction -Execute $wscript -Argument '//B //Nologo "C:\AFZ\GitHubDirect\Run-H3-GitHub-DirectReturn-Hidden.vbs"'
try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
Set-ScheduledTask -TaskName $taskName -Action $newAction | Out-Null

$tAfterSet=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$principalAfter=[ordered]@{user=[string]$tAfterSet.Principal.UserId;logonType=[string]$tAfterSet.Principal.LogonType;runLevel=[string]$tAfterSet.Principal.RunLevel}
$principalPreserved=($principalBefore.user -eq $principalAfter.user -and $principalBefore.logonType -eq $principalAfter.logonType -and $principalBefore.runLevel -eq $principalAfter.runLevel)
if(-not $principalPreserved){
  Set-ScheduledTask -TaskName $taskName -Action $oldAction | Out-Null
  throw 'Scheduled-task principal changed unexpectedly; original action restored.'
}

Start-ScheduledTask -TaskName $taskName
$deadline=(Get-Date).AddSeconds(75)
do{
  Start-Sleep -Milliseconds 750
  $now=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($now -and [string]$now.State -ne 'Running'){break}
}while((Get-Date) -lt $deadline)

$infoAfter=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
$publisherAfter=Read-Json $publisherStatePath
$parityFailure=$null
if($infoBefore -and [int]$infoBefore.LastTaskResult -eq 0 -and $infoAfter -and [string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and [int]$infoAfter.LastTaskResult -ne 0){
  $parityFailure="Task exit changed from 0 to $([int]$infoAfter.LastTaskResult)"
}
if(-not $parityFailure -and $publisherBefore -and [bool]$publisherBefore.ok -and $publisherAfter -and -not [bool]$publisherAfter.ok){
  $parityFailure='Publisher state regressed from ok=true to ok=false.'
}
if($parityFailure){
  try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{}
  Set-ScheduledTask -TaskName $taskName -Action $oldAction | Out-Null
  Start-ScheduledTask -TaskName $taskName
  throw "No-window launcher parity check failed and original action was restored: $parityFailure"
}

$afterAudit=@(Task-Audit)
$current=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$currentAction=@($current.Actions)[0]
$result=[ordered]@{
  schema=1
  ok=$true
  status='completed'
  host=$env:COMPUTERNAME
  targetTask=$taskName
  diagnosis='interactive-principal-direct-console-action'
  remediation='preserve-interactive-user-and-replace-direct-powershell-action-with-wscript-hidden-launcher'
  principalPreserved=$principalPreserved
  beforeAction=[ordered]@{execute=$execute;arguments=$args;lastTaskResult=$(if($infoBefore){[int]$infoBefore.LastTaskResult}else{$null})}
  afterAction=[ordered]@{execute=[string]$currentAction.Execute;arguments=[string]$currentAction.Arguments;state=[string]$current.State;lastTaskResult=$(if($infoAfter){[int]$infoAfter.LastTaskResult}else{$null})}
  publisherBefore=$publisherBefore
  publisherAfter=$publisherAfter
  launcher=$launcher
  auditBefore=$beforeAudit
  auditAfter=$afterAudit
  updatedAt=(Get-Date -Format o)
}
Emit $result
exit 0
'@

  $stdin=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlash-In-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $stdout=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlash-Out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $stderr=Join-Path $env:TEMP ('AFZ-H3-ConsoleFlash-Err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($stdin,$remote,[Text.Encoding]::ASCII)
    $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','StrictHostKeyChecking=yes','-o',("UserKnownHostsFile="+$known),$h3,'powershell.exe','-NoProfile','-NonInteractive','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
    if(-not $p.WaitForExit(120000)){
      try{$p.Kill()}catch{}
      try{$p.WaitForExit()}catch{}
      throw 'H3 console-flash remediation timed out after 120 seconds'
    }
    $p.WaitForExit()
    $exit=[int]$p.ExitCode
    $outText=$(if(Test-Path -LiteralPath $stdout){[IO.File]::ReadAllText($stdout)}else{''})
    $errText=$(if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''})
    $jsonLine=@(($outText -split "`r?`n") | Where-Object {$_ -match '^\{.*\}$'} | Select-Object -Last 1)
    $remoteResult=$null
    if($jsonLine){try{$remoteResult=$jsonLine|ConvertFrom-Json}catch{}}
    if($exit -ne 0){throw "H3 console-flash remediation failed exit=$exit stdout=$outText stderr=$errText"}
    if(-not $remoteResult -or -not [bool]$remoteResult.ok){throw "H3 console-flash remediation returned no successful result: stdout=$outText stderr=$errText"}
  }finally{
    Remove-Item -LiteralPath $stdin,$stdout,$stderr -Force -ErrorAction SilentlyContinue
  }

  $result=[ordered]@{schema=1;ok=$true;status=[string]$remoteResult.status;target=$targetHost;remediationVersion=1;syncedSha=$SyncedSha;remote=$remoteResult;updatedAt=(Get-Date -Format o)}
  Save $result
}catch{
  $failed=[ordered]@{schema=1;ok=$false;status='failed';target=$targetHost;remediationVersion=1;syncedSha=$SyncedSha;error=$_.Exception.Message;updatedAt=(Get-Date -Format o)}
  Save $failed
  exit 1
}
