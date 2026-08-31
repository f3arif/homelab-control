#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$keygen=Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$target='Faiz@100.106.186.118'
$expectedHost='DESKTOP-H3R6CQN'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-generic-worker-recovery'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'H3-GENERIC-WORKER-RECOVERY-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-Result($o){
  $json=$o|ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output $json
}

function Invoke-H3([string]$RemoteScript){
  # Keep the full recovery body off the Windows process command line. Windows
  # PowerShell's special `-Command -` stdin mode proved unreliable through the
  # OpenSSH server (exit 0 with blank stdout/stderr), so use a tiny encoded
  # bootstrap that explicitly consumes stdin and invokes exactly that body.
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 recovery stdin was empty.''};Invoke-Expression $script'
  $bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@(
    '-i',$key,
    '-o','IdentitiesOnly=yes',
    '-o','BatchMode=yes',
    '-o','ConnectTimeout=8',
    '-o','StrictHostKeyChecking=yes',
    '-o',('UserKnownHostsFile='+$known),
    $target,
    'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded
  )
  $inFile=Join-Path $env:TEMP ('afz-h3-generic-recovery-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-generic-recovery-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-h3-generic-recovery-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(60000)){
      try{$p.Kill()}catch{}
      throw 'H3 SSH recovery command timed out after 60 seconds.'
    }
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    return [ordered]@{exit=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr}
  }finally{
    Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

try{
  foreach($p in @($key,$known,$ssh,$keygen)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){
    throw "SYSTEM execution required. Actual identity: $($identity.Name) [$($identity.User.Value)]"
  }

  $derived=(& $keygen -y -f $key 2>&1 | Select-Object -First 1);$deriveExit=$LASTEXITCODE
  if($deriveExit -ne 0 -or [string]::IsNullOrWhiteSpace([string]$derived)){throw 'SYSTEM cannot read dedicated H3 system key.'}
  $tmpPub=Join-Path $env:TEMP ('afz-h3-generic-recovery-'+[guid]::NewGuid().ToString('n')+'.pub')
  try{
    ([string]$derived).Trim()|Set-Content -LiteralPath $tmpPub -Encoding ascii
    $fingerprint=((& $keygen -lf $tmpPub 2>&1)-join ' ').Trim();$fpExit=$LASTEXITCODE
  }finally{Remove-Item -LiteralPath $tmpPub -Force -ErrorAction SilentlyContinue}
  if($fpExit -ne 0 -or [string]::IsNullOrWhiteSpace($fingerprint)){throw 'Could not derive H3 SYSTEM key fingerprint.'}

  $remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$taskName='AFZ H3 Generic Worker'
$workerScript='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1'
$expectedWorkerSha='b61d8eb4e625549836c504d102bc0139d1c97786447e2ea071ac9dbc8f02795e'
$expectedLauncher='C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Task-Hidden.vbs'
$knownCorruptLauncherSha='a09e67601c7261dc38d430c62f01395df4649cb10a487a7ae9aa74e0d06e7d55'
$launcherBackup=$expectedLauncher+'.bak-corrupt-a09e6760'
$heartbeat='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Heartbeat\h3.txt'
$utf8=New-Object Text.UTF8Encoding($false)
$staleResetMinSeconds=120

# Reconstruct exactly the command the console-flash remediation was meant to
# preserve from the original known-good Generic Worker task action.
$canonicalWorkerCommand='"C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\AFZ\H3Worker\AFZ-H3-Worker.ps1"'
$canonicalEscaped=$canonicalWorkerCommand.Replace('"','""')
$canonicalLauncher=@(
  'Option Explicit',
  'Dim shell, cmd, rc',
  'Set shell = CreateObject("WScript.Shell")',
  ('cmd = "'+$canonicalEscaped+'"'),
  'rc = shell.Run(cmd, 0, True)',
  'WScript.Quit rc'
) -join "`r`n"
$knownCorruptLauncher=@(
  'Option Explicit',
  'Dim shell, cmd, rc',
  'Set shell = CreateObject("WScript.Shell")',
  'cmd = """C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe"" "',
  'rc = shell.Run(cmd, 0, True)',
  'WScript.Quit rc'
) -join "`r`n"

function Get-WorkerProcesses {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
    Where-Object { [string]$_.CommandLine -like ('*'+$workerScript+'*') } |
    Select-Object ProcessId,ParentProcessId,Name,CommandLine)
}
function Get-LauncherProcesses {
  @(Get-CimInstance Win32_Process -Filter "Name='wscript.exe' OR Name='cscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like ('*'+$expectedLauncher+'*') } |
    Select-Object ProcessId,ParentProcessId,Name,CommandLine)
}
function Get-Sha([string]$Path){
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

$before=@(Get-WorkerProcesses)
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$taskInfo=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
$actions=@($task.Actions|ForEach-Object{[ordered]@{execute=[string]$_.Execute;arguments=[string]$_.Arguments}})
$principal=[ordered]@{userId=[string]$task.Principal.UserId;logonType=[string]$task.Principal.LogonType;runLevel=[string]$task.Principal.RunLevel}

$hiddenActionOk=$false
foreach($a in $actions){
  $exe=[IO.Path]::GetFileName([string]$a.execute)
  $argText=[string]$a.arguments
  if(
    $exe -ieq 'wscript.exe' -and
    $argText -match '(?i)(?:^|\s)//B(?:\s|$)' -and
    $argText -match '(?i)(?:^|\s)//Nologo(?:\s|$)' -and
    $argText -match [regex]::Escape($expectedLauncher)
  ){$hiddenActionOk=$true}
}
$principalOk=([string]$task.Principal.UserId -match '(?i)(^|\\)Faiz$' -and [string]$task.Principal.LogonType -eq 'Interactive')

$launcherRepaired=$false
$launcherRepairBackup=$null
$launcherShaBefore=$null
$launcherShaAfter=$null
$canonicalLauncherSha=$null
$workerSha=$null
$started=$false
$staleTaskReset=$false
$taskRunAgeSeconds=$null
$heartbeatAgeBeforeSeconds=$null
$heartbeatBeforeWrite=$null
$heartbeatFreshAfterStart=$false
$classification=''

if(Test-Path -LiteralPath $heartbeat -PathType Leaf){
  $heartbeatBeforeItem=Get-Item -LiteralPath $heartbeat -ErrorAction Stop
  $heartbeatBeforeWrite=$heartbeatBeforeItem.LastWriteTime
  $heartbeatAgeBeforeSeconds=[math]::Round(((Get-Date)-$heartbeatBeforeWrite).TotalSeconds,1)
}

if($before.Count -gt 0){
  $classification='H3_GENERIC_WORKER_ALREADY_RUNNING'
}else{
  if(-not $hiddenActionOk){throw "Generic Worker is absent but task action does not match exact hidden launcher $expectedLauncher; refusing to start."}
  if(-not $principalOk){throw 'Generic Worker is absent but task principal is not the expected Faiz/Interactive principal; refusing to start.'}
  if(-not(Test-Path -LiteralPath $workerScript -PathType Leaf)){throw "Expected Generic Worker script is missing: $workerScript"}
  $workerSha=Get-Sha $workerScript
  if($workerSha -ne $expectedWorkerSha){throw "Generic Worker script hash mismatch; refusing launcher repair/start. actual=$workerSha expected=$expectedWorkerSha"}
  if(-not(Test-Path -LiteralPath $expectedLauncher -PathType Leaf)){throw "Expected hidden launcher is missing; refusing reconstruction without the known corrupt source file: $expectedLauncher"}

  $launcherShaBefore=Get-Sha $expectedLauncher
  $launcherContentBefore=[IO.File]::ReadAllText($expectedLauncher)
  $canonicalBytes=$utf8.GetBytes($canonicalLauncher)
  $shaAlg=[Security.Cryptography.SHA256]::Create()
  try{$canonicalLauncherSha=([BitConverter]::ToString($shaAlg.ComputeHash($canonicalBytes))).Replace('-','').ToLowerInvariant()}finally{$shaAlg.Dispose()}

  if($launcherShaBefore -eq $knownCorruptLauncherSha){
    if($launcherContentBefore -cne $knownCorruptLauncher){throw 'Known corrupt launcher hash matched but content did not match the audited truncated launcher; refusing write.'}
    if(Test-Path -LiteralPath $launcherBackup -PathType Leaf){
      $backupSha=Get-Sha $launcherBackup
      if($backupSha -ne $knownCorruptLauncherSha){throw "Launcher backup already exists with unexpected hash: $launcherBackup sha=$backupSha"}
    }else{
      [IO.File]::WriteAllBytes($launcherBackup,[IO.File]::ReadAllBytes($expectedLauncher))
    }
    $launcherRepairBackup=$launcherBackup
    $tmpLauncher=$expectedLauncher+'.repair-'+[guid]::NewGuid().ToString('n')+'.tmp'
    try{
      [IO.File]::WriteAllText($tmpLauncher,$canonicalLauncher,$utf8)
      $tmpSha=Get-Sha $tmpLauncher
      if($tmpSha -ne $canonicalLauncherSha){throw "Temporary canonical launcher hash mismatch: $tmpSha"}
      Move-Item -LiteralPath $tmpLauncher -Destination $expectedLauncher -Force
    }finally{
      if(Test-Path -LiteralPath $tmpLauncher){Remove-Item -LiteralPath $tmpLauncher -Force -ErrorAction SilentlyContinue}
    }
    $launcherShaAfter=Get-Sha $expectedLauncher
    if($launcherShaAfter -ne $canonicalLauncherSha){throw "Repaired launcher verification failed: $launcherShaAfter"}
    if([IO.File]::ReadAllText($expectedLauncher) -cne $canonicalLauncher){throw 'Repaired launcher content verification failed.'}
    $launcherRepaired=$true
  }elseif($launcherShaBefore -eq $canonicalLauncherSha){
    if($launcherContentBefore -cne $canonicalLauncher){throw 'Canonical launcher hash matched but content verification failed.'}
    $launcherShaAfter=$launcherShaBefore
  }else{
    throw "Hidden launcher is neither the audited corrupt file nor the canonical repaired file; refusing write/start. sha=$launcherShaBefore"
  }

  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if([string]$task.State -eq 'Running'){
    if(-not $heartbeatBeforeWrite){throw 'Generic Worker task is Running with no worker process, but heartbeat file is missing; refusing stale-task reset without age proof.'}
    $taskRunAgeSeconds=[math]::Round(((Get-Date)-$taskInfo.LastRunTime).TotalSeconds,1)
    if($taskRunAgeSeconds -lt $staleResetMinSeconds){throw "Generic Worker task is Running with no worker process but is too recent for reset. runAgeSeconds=$taskRunAgeSeconds minimum=$staleResetMinSeconds"}
    if($heartbeatAgeBeforeSeconds -lt $staleResetMinSeconds){throw "Generic Worker task is Running with no worker process but heartbeat is too recent for reset. heartbeatAgeSeconds=$heartbeatAgeBeforeSeconds minimum=$staleResetMinSeconds"}

    Stop-ScheduledTask -TaskName $taskName
    $staleTaskReset=$true
    $stopDeadline=(Get-Date).AddSeconds(10)
    do{
      Start-Sleep -Milliseconds 250
      $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
      if([string]$task.State -ne 'Running'){break}
    }while((Get-Date) -lt $stopDeadline)
    if([string]$task.State -eq 'Running'){throw 'Generic Worker stale task did not leave Running state after bounded Stop-ScheduledTask.'}

    Start-ScheduledTask -TaskName $taskName
    $started=$true
    $classification=$(if($launcherRepaired){'H3_GENERIC_WORKER_LAUNCHER_REPAIRED_STALE_TASK_RESET_AND_STARTED'}else{'H3_GENERIC_WORKER_STALE_TASK_RESET_AND_STARTED'})
  }else{
    Start-ScheduledTask -TaskName $taskName
    $started=$true
    $classification='H3_GENERIC_WORKER_STARTED_EXISTING_HIDDEN_TASK'
  }
}

$after=@()
if($started){
  $deadline=(Get-Date).AddSeconds(35)
  do{
    Start-Sleep -Milliseconds 750
    $after=@(Get-WorkerProcesses)
    if($after.Count -gt 0){break}
  }while((Get-Date) -lt $deadline)
}else{
  $after=@(Get-WorkerProcesses)
}

if($started -and $after.Count -gt 0 -and $heartbeatBeforeWrite){
  $heartbeatDeadline=(Get-Date).AddSeconds(45)
  do{
    if(Test-Path -LiteralPath $heartbeat -PathType Leaf){
      $heartbeatNow=Get-Item -LiteralPath $heartbeat -ErrorAction Stop
      if($heartbeatNow.LastWriteTime -gt $heartbeatBeforeWrite){
        $heartbeatFreshAfterStart=$true
        break
      }
    }
    Start-Sleep -Milliseconds 750
  }while((Get-Date) -lt $heartbeatDeadline)
}

$postTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$postTaskInfo=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
$launcherProcesses=@(Get-LauncherProcesses)
$launcherExists=Test-Path -LiteralPath $expectedLauncher -PathType Leaf
$workerScriptExists=Test-Path -LiteralPath $workerScript -PathType Leaf
$launcherMeta=$null
if($launcherExists){
  try{
    $li=Get-Item -LiteralPath $expectedLauncher -ErrorAction Stop
    $launcherMeta=[ordered]@{
      length=[int64]$li.Length
      lastWrite=$li.LastWriteTime.ToString('o')
      sha256=(Get-FileHash -LiteralPath $expectedLauncher -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
      content=[IO.File]::ReadAllText($expectedLauncher)
    }
  }catch{$launcherMeta=[ordered]@{error=$_.Exception.Message}}
}
$workerMeta=$null
if($workerScriptExists){
  try{
    $wi=Get-Item -LiteralPath $workerScript -ErrorAction Stop
    $workerMeta=[ordered]@{
      length=[int64]$wi.Length
      lastWrite=$wi.LastWriteTime.ToString('o')
      sha256=(Get-FileHash -LiteralPath $workerScript -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
  }catch{$workerMeta=[ordered]@{error=$_.Exception.Message}}
}
$taskEvents=@()
try{
  $since=(Get-Date).AddMinutes(-5)
  $taskEvents=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational';StartTime=$since} -ErrorAction Stop |
    Where-Object { [string]$_.Message -like ('*'+$taskName+'*') } |
    Select-Object -First 20 @{n='time';e={$_.TimeCreated.ToString('o')}},Id,LevelDisplayName,Message)
}catch{}

$heartbeatWrite=$null;$heartbeatAgeSec=$null
if(Test-Path -LiteralPath $heartbeat -PathType Leaf){
  $item=Get-Item -LiteralPath $heartbeat -ErrorAction Stop
  $heartbeatWrite=$item.LastWriteTime.ToString('o')
  $heartbeatAgeSec=[math]::Round(((Get-Date)-$item.LastWriteTime).TotalSeconds,1)
}

$mutation=$(
  if($launcherRepaired -and $staleTaskReset){'REPAIR_KNOWN_CORRUPT_LAUNCHER+RESET_STALE_RUNNING_TASK+START_EXISTING_TASK_ONLY'}
  elseif($staleTaskReset){'RESET_STALE_RUNNING_TASK+START_EXISTING_TASK_ONLY'}
  elseif($launcherRepaired -and $started){'REPAIR_KNOWN_CORRUPT_LAUNCHER+START_EXISTING_TASK_ONLY'}
  elseif($launcherRepaired){'REPAIR_KNOWN_CORRUPT_LAUNCHER_ONLY'}
  elseif($started){'START_EXISTING_TASK_ONLY'}
  else{'NONE'}
)
$result=[ordered]@{
  schema=1;host=$env:COMPUTERNAME;taskName=$taskName;taskState=[string]$taskInfo.TaskName;
  lastTaskResult=[int64]$taskInfo.LastTaskResult;lastRunTime=$taskInfo.LastRunTime.ToString('o');
  postTaskState=$(if($postTask){[string]$postTask.State}else{$null});
  postLastTaskResult=$(if($postTaskInfo){[int64]$postTaskInfo.LastTaskResult}else{$null});
  postLastRunTime=$(if($postTaskInfo){$postTaskInfo.LastRunTime.ToString('o')}else{$null});
  expectedLauncher=$expectedLauncher;actions=$actions;principal=$principal;
  hiddenActionVerified=$hiddenActionOk;principalVerified=$principalOk;
  launcherRepaired=$launcherRepaired;launcherRepairBackup=$launcherRepairBackup;
  knownCorruptLauncherSha=$knownCorruptLauncherSha;launcherShaBefore=$launcherShaBefore;launcherShaAfter=$launcherShaAfter;canonicalLauncherSha=$canonicalLauncherSha;
  launcherExists=$launcherExists;launcher=$launcherMeta;launcherProcessCount=$launcherProcesses.Count;launcherProcesses=$launcherProcesses;
  workerScriptExists=$workerScriptExists;workerScript=$workerMeta;expectedWorkerSha=$expectedWorkerSha;workerSha=$workerSha;
  beforeProcessCount=$before.Count;beforeProcesses=$before;taskStartIssued=$started;staleTaskReset=$staleTaskReset;
  staleResetMinSeconds=$staleResetMinSeconds;taskRunAgeSeconds=$taskRunAgeSeconds;heartbeatAgeBeforeSeconds=$heartbeatAgeBeforeSeconds;
  afterProcessCount=$after.Count;afterProcesses=$after;heartbeatPath=$heartbeat;
  heartbeatBeforeWrite=$(if($heartbeatBeforeWrite){$heartbeatBeforeWrite.ToString('o')}else{$null});
  heartbeatLastWrite=$heartbeatWrite;heartbeatAgeSeconds=$heartbeatAgeSec;heartbeatFreshAfterStart=$heartbeatFreshAfterStart;taskEvents=$taskEvents;
  classification=$classification;mutation=$mutation;
  capturedAt=(Get-Date).ToString('o')
}
if($after.Count -eq 0){
  if([string]::IsNullOrWhiteSpace([string]$result.classification)){$result.classification='H3_GENERIC_WORKER_RECOVERY_FAILED_NO_PROCESS'}
  $result|ConvertTo-Json -Depth 14 -Compress
  exit 12
}
if($started -and -not $heartbeatFreshAfterStart){
  $result.classification='H3_GENERIC_WORKER_RECOVERY_FAILED_NO_FRESH_HEARTBEAT'
  $result|ConvertTo-Json -Depth 14 -Compress
  exit 13
}
$result|ConvertTo-Json -Depth 14 -Compress
exit 0
'@

  $remoteResult=Invoke-H3 $remote
  $jsonLine=@(([string]$remoteResult.stdout -split "`r?`n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  $payload=$null
  if($jsonLine){$payload=$jsonLine|ConvertFrom-Json -ErrorAction Stop}
  if([int]$remoteResult.exit -ne 0 -and -not $payload){throw "H3 recovery failed exit=$($remoteResult.exit) stdout=$($remoteResult.stdout) stderr=$($remoteResult.stderr)"}
  if(-not $payload){throw "H3 recovery returned no JSON. exit=$($remoteResult.exit) stdout=$($remoteResult.stdout) stderr=$($remoteResult.stderr)"}
  if([string]$payload.host -ne $expectedHost){throw "Unexpected H3 host: $($payload.host)"}
  if([int]$payload.afterProcessCount -lt 1 -or ([bool]$payload.taskStartIssued -and -not [bool]$payload.heartbeatFreshAfterStart)){
    Save-Result ([ordered]@{
      schema=1;status='failed';classification=[string]$payload.classification;syncedSha=$SyncedSha;
      error=$(if([int]$payload.afterProcessCount -lt 1){'H3 Generic Worker remains absent after recovery.'}else{'H3 Generic Worker process started but did not publish a fresh heartbeat within the bounded proof window.'});
      systemIdentity=[string]$identity.Name;systemKeyPath=$key;systemKeyFingerprint=$fingerprint;
      remoteHost=[string]$payload.host;taskStartIssued=[bool]$payload.taskStartIssued;staleTaskReset=[bool]$payload.staleTaskReset;
      hiddenActionVerified=[bool]$payload.hiddenActionVerified;principalVerified=[bool]$payload.principalVerified;
      launcherRepaired=[bool]$payload.launcherRepaired;launcherRepairBackup=$payload.launcherRepairBackup;
      expectedLauncher=$payload.expectedLauncher;beforeProcessCount=[int]$payload.beforeProcessCount;
      afterProcessCount=[int]$payload.afterProcessCount;heartbeatBeforeWrite=$payload.heartbeatBeforeWrite;heartbeatLastWrite=$payload.heartbeatLastWrite;
      heartbeatAgeSeconds=$payload.heartbeatAgeSeconds;heartbeatFreshAfterStart=[bool]$payload.heartbeatFreshAfterStart;remoteMutation=[string]$payload.mutation;
      sshExit=[int]$remoteResult.exit;sshStderr=[string]$remoteResult.stderr;
      remote=$payload;capturedAt=(Get-Date -Format o)
    })
    exit 20
  }

  Save-Result ([ordered]@{
    schema=1;status='completed';classification=[string]$payload.classification;syncedSha=$SyncedSha;
    systemIdentity=[string]$identity.Name;systemKeyPath=$key;systemKeyFingerprint=$fingerprint;
    remoteHost=[string]$payload.host;taskStartIssued=[bool]$payload.taskStartIssued;staleTaskReset=[bool]$payload.staleTaskReset;
    hiddenActionVerified=[bool]$payload.hiddenActionVerified;principalVerified=[bool]$payload.principalVerified;
    launcherRepaired=[bool]$payload.launcherRepaired;launcherRepairBackup=$payload.launcherRepairBackup;
    expectedLauncher=$payload.expectedLauncher;beforeProcessCount=[int]$payload.beforeProcessCount;
    afterProcessCount=[int]$payload.afterProcessCount;heartbeatBeforeWrite=$payload.heartbeatBeforeWrite;heartbeatLastWrite=$payload.heartbeatLastWrite;
    heartbeatAgeSeconds=$payload.heartbeatAgeSeconds;heartbeatFreshAfterStart=[bool]$payload.heartbeatFreshAfterStart;remoteMutation=[string]$payload.mutation;
    remote=$payload;capturedAt=(Get-Date -Format o)
  })
  exit 0
}catch{
  Save-Result ([ordered]@{schema=1;status='failed';classification='H3_GENERIC_WORKER_SYSTEM_RECOVERY_FAILED';syncedSha=$SyncedSha;error=$_.Exception.Message;remoteMutation='NONE_OR_FAILED_BEFORE_CONFIRMATION';capturedAt=(Get-Date -Format o)})
  exit 20
}