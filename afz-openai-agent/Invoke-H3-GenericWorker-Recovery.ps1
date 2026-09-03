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
$sharedMirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$sharedMirrorPath=Join-Path $sharedMirrorRoot 'AFZ-H3-OLLAMA-WATCHDOG-AUDIT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-Result($o){
  $json=$o|ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  try{if(Test-Path -LiteralPath $sharedMirrorRoot -PathType Container){[IO.File]::WriteAllText($sharedMirrorPath,$json,$utf8)}}catch{}
  Write-Output $json
}

function Invoke-H3ReadOnly([string]$RemoteScript){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 read-only probe stdin was empty.''};Invoke-Expression $script'
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
  $inFile=Join-Path $env:TEMP ('afz-h3-generic-readonly-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-generic-readonly-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-h3-generic-readonly-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(60000)){
      try{$p.Kill()}catch{}
      throw 'H3 read-only SSH probe timed out after 60 seconds.'
    }
    $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile)}else{''})
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
  $tmpPub=Join-Path $env:TEMP ('afz-h3-generic-readonly-'+[guid]::NewGuid().ToString('n')+'.pub')
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
$heartbeat='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Heartbeat\h3.txt'
$utf8=New-Object Text.UTF8Encoding($false)

function Get-ShaSafe([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}catch{return $null}
}
function Get-WorkerProcesses {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like ('*'+$workerScript+'*') } |
    Select-Object ProcessId,ParentProcessId,Name,CommandLine)
}

# HERMES_OLLAMA_WATCHDOG_READONLY_AUDIT_V1
function Get-OllamaWatchdogReadOnlyAudit {
  $watchdogTaskName='AFZ H3 Ollama Liveness'
  $taskO=Get-ScheduledTask -TaskName $watchdogTaskName -ErrorAction SilentlyContinue
  $taskInfoO=$(if($taskO){Get-ScheduledTaskInfo -TaskName $watchdogTaskName -ErrorAction SilentlyContinue}else{$null})
  $actionsO=@()
  $triggersO=@()
  $principalO=$null
  if($taskO){
    $actionsO=@($taskO.Actions|ForEach-Object{[ordered]@{execute=[string]$_.Execute;arguments=[string]$_.Arguments;workingDirectory=[string]$_.WorkingDirectory}})
    $triggersO=@($taskO.Triggers|ForEach-Object{[ordered]@{enabled=[bool]$_.Enabled;startBoundary=[string]$_.StartBoundary;endBoundary=[string]$_.EndBoundary;repetitionInterval=[string]$_.Repetition.Interval;repetitionDuration=[string]$_.Repetition.Duration;executionTimeLimit=[string]$_.ExecutionTimeLimit}})
    $principalO=[ordered]@{userId=[string]$taskO.Principal.UserId;logonType=[string]$taskO.Principal.LogonType;runLevel=[string]$taskO.Principal.RunLevel}
  }

  $ollamaProcesses=@(Get-CimInstance Win32_Process -Filter "Name='ollama.exe'" -ErrorAction SilentlyContinue|ForEach-Object{
    [ordered]@{processId=[int]$_.ProcessId;parentProcessId=[int]$_.ParentProcessId;commandLine=[string]$_.CommandLine;creationDate=[string]$_.CreationDate;executablePath=[string]$_.ExecutablePath}
  })

  $listeners=@()
  try{$listeners=@(Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction Stop|ForEach-Object{[ordered]@{localAddress=[string]$_.LocalAddress;localPort=[int]$_.LocalPort;owningProcess=[int]$_.OwningProcess;state=[string]$_.State}})}catch{}

  $modelsReachable=$false
  $modelListed=$false
  $modelIds=@()
  $modelsError=$null
  try{
    $m=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -Method Get -TimeoutSec 4
    $modelIds=@($m.data|ForEach-Object{[string]$_.id})
    $modelsReachable=$true
    $modelListed=('qwen3.6:35b-a3b' -in $modelIds)
  }catch{$modelsError=$_.Exception.GetType().FullName}

  $nativePsReachable=$false
  $loadedModels=@()
  $nativePsError=$null
  try{
    $ps=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -Method Get -TimeoutSec 4
    $loadedModels=@($ps.models|ForEach-Object{[ordered]@{name=[string]$_.name;model=[string]$_.model;size=[int64]$_.size;sizeVram=[int64]$_.size_vram;expiresAt=[string]$_.expires_at}})
    $nativePsReachable=$true
  }catch{$nativePsError=$_.Exception.GetType().FullName}

  $recentEvents=@()
  $eventReadError=$null
  try{
    $since=(Get-Date).AddHours(-3)
    $recentEvents=@(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$since} -MaxEvents 150 -ErrorAction Stop |
      Where-Object {([string]$_.ProviderName -match '(?i)ollama|nvidia|cuda') -or ([string]$_.Message -match '(?i)ollama|nvidia|cuda|llama')} |
      Select-Object -First 20 |
      ForEach-Object{
        $msg=[string]$_.Message
        if($msg.Length -gt 800){$msg=$msg.Substring(0,800)}
        [ordered]@{timeCreated=$(if($_.TimeCreated){$_.TimeCreated.ToString('o')}else{$null});providerName=[string]$_.ProviderName;id=[int]$_.Id;levelDisplayName=[string]$_.LevelDisplayName;message=$msg}
      })
  }catch{$eventReadError=$_.Exception.GetType().FullName}

  [ordered]@{
    readOnly=$true;remoteMutation='NONE';taskName=$watchdogTaskName;taskExists=[bool]$taskO;taskState=$(if($taskO){[string]$taskO.State}else{$null});
    lastTaskResult=$(if($taskInfoO){[int64]$taskInfoO.LastTaskResult}else{$null});lastRunTime=$(if($taskInfoO){$taskInfoO.LastRunTime.ToString('o')}else{$null});nextRunTime=$(if($taskInfoO){$taskInfoO.NextRunTime.ToString('o')}else{$null});numberOfMissedRuns=$(if($taskInfoO){[int64]$taskInfoO.NumberOfMissedRuns}else{$null});
    principal=$principalO;actions=$actionsO;triggers=$triggersO;ollamaProcessCount=$ollamaProcesses.Count;ollamaProcesses=$ollamaProcesses;listenerCount=$listeners.Count;listeners=$listeners;
    modelsReachable=$modelsReachable;modelListed=$modelListed;modelIds=$modelIds;modelsError=$modelsError;nativePsReachable=$nativePsReachable;loadedModels=$loadedModels;nativePsError=$nativePsError;
    recentApplicationEvents=$recentEvents;eventReadError=$eventReadError;capturedAt=(Get-Date -Format o)
  }
}

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
$shaAlg=[Security.Cryptography.SHA256]::Create()
try{$canonicalLauncherSha=([BitConverter]::ToString($shaAlg.ComputeHash($utf8.GetBytes($canonicalLauncher)))).Replace('-','').ToLowerInvariant()}finally{$shaAlg.Dispose()}

$workers=@(Get-WorkerProcesses)
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskInfo=$(if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null})
$actions=@()
$principal=$null
$hiddenActionOk=$false
$principalOk=$false
if($task){
  $actions=@($task.Actions|ForEach-Object{[ordered]@{execute=[string]$_.Execute;arguments=[string]$_.Arguments}})
  $principal=[ordered]@{userId=[string]$task.Principal.UserId;logonType=[string]$task.Principal.LogonType;runLevel=[string]$task.Principal.RunLevel}
  foreach($a in $actions){
    $exe=[IO.Path]::GetFileName([string]$a.execute)
    $argText=[string]$a.arguments
    if($exe -ieq 'wscript.exe' -and $argText -match '(?i)(?:^|\s)//B(?:\s|$)' -and $argText -match '(?i)(?:^|\s)//Nologo(?:\s|$)' -and $argText -match [regex]::Escape($expectedLauncher)){$hiddenActionOk=$true}
  }
  $principalOk=([string]$task.Principal.UserId -match '(?i)(^|\\)Faiz$' -and [string]$task.Principal.LogonType -eq 'Interactive')
}

$launcherExists=Test-Path -LiteralPath $expectedLauncher -PathType Leaf
$workerScriptExists=Test-Path -LiteralPath $workerScript -PathType Leaf
$launcherSha=Get-ShaSafe $expectedLauncher
$workerSha=Get-ShaSafe $workerScript
$launcherState=$(if(-not $launcherExists){'missing'}elseif($launcherSha -eq $canonicalLauncherSha){'canonical'}elseif($launcherSha -eq $knownCorruptLauncherSha){'known-corrupt'}else{'unexpected'})
$heartbeatLastWrite=$null
$heartbeatAgeSeconds=$null
if(Test-Path -LiteralPath $heartbeat -PathType Leaf){
  $hi=Get-Item -LiteralPath $heartbeat -ErrorAction SilentlyContinue
  if($hi){$heartbeatLastWrite=$hi.LastWriteTime.ToString('o');$heartbeatAgeSeconds=[math]::Round(((Get-Date)-$hi.LastWriteTime).TotalSeconds,1)}
}
$ollamaWatchdog=Get-OllamaWatchdogReadOnlyAudit

$classification='H3_GENERIC_WORKER_READONLY_UNKNOWN'
if($workers.Count -gt 0){$classification='H3_GENERIC_WORKER_RUNNING'}
elseif(-not $task){$classification='H3_GENERIC_WORKER_TASK_MISSING'}
elseif(-not $hiddenActionOk -or -not $principalOk){$classification='H3_GENERIC_WORKER_TASK_GUARD_MISMATCH'}
elseif(-not $workerScriptExists){$classification='H3_GENERIC_WORKER_SCRIPT_MISSING'}
elseif($workerSha -ne $expectedWorkerSha){$classification='H3_GENERIC_WORKER_SCRIPT_HASH_MISMATCH'}
elseif($launcherState -eq 'missing'){$classification='H3_GENERIC_WORKER_LAUNCHER_MISSING'}
elseif($launcherState -eq 'known-corrupt'){$classification='H3_GENERIC_WORKER_LAUNCHER_CORRUPT_REPAIR_REQUIRED'}
elseif($launcherState -ne 'canonical'){$classification='H3_GENERIC_WORKER_LAUNCHER_UNEXPECTED'}
elseif([string]$task.State -eq 'Running'){$classification='H3_GENERIC_WORKER_STALE_TASK_RUNNING_AUTHORIZATION_REQUIRED'}
else{$classification='H3_GENERIC_WORKER_TASK_NOT_RUNNING_START_ELIGIBLE'}

[ordered]@{
  schema=1;host=$env:COMPUTERNAME;classification=$classification;readOnly=$true;remoteMutation='NONE';
  taskName=$taskName;taskExists=[bool]$task;taskState=$(if($task){[string]$task.State}else{$null});
  lastTaskResult=$(if($taskInfo){[int64]$taskInfo.LastTaskResult}else{$null});lastRunTime=$(if($taskInfo){$taskInfo.LastRunTime.ToString('o')}else{$null});
  actions=$actions;principal=$principal;hiddenActionVerified=$hiddenActionOk;principalVerified=$principalOk;
  workerProcessCount=$workers.Count;workerProcesses=$workers;workerScriptExists=$workerScriptExists;workerSha=$workerSha;expectedWorkerSha=$expectedWorkerSha;
  launcherExists=$launcherExists;launcherSha=$launcherSha;canonicalLauncherSha=$canonicalLauncherSha;knownCorruptLauncherSha=$knownCorruptLauncherSha;launcherState=$launcherState;
  heartbeatPath=$heartbeat;heartbeatLastWrite=$heartbeatLastWrite;heartbeatAgeSeconds=$heartbeatAgeSeconds;ollamaWatchdog=$ollamaWatchdog;capturedAt=(Get-Date -Format o)
}|ConvertTo-Json -Depth 12 -Compress
'@

  $remoteResult=Invoke-H3ReadOnly $remote
  $jsonLine=@(([string]$remoteResult.stdout -split "`r?`n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if([int]$remoteResult.exit -ne 0 -and -not $jsonLine){
    Save-Result ([ordered]@{schema=1;status='failed';classification='H3_GENERIC_WORKER_READONLY_SSH_FAILED';syncedSha=$SyncedSha;systemIdentity=[string]$identity.Name;systemKeyFingerprint=$fingerprint;sshExit=[int]$remoteResult.exit;sshStderr=[string]$remoteResult.stderr;remoteMutation='NONE';capturedAt=(Get-Date -Format o)})
    exit 20
  }
  if(-not $jsonLine){throw "H3 read-only probe returned no JSON. exit=$($remoteResult.exit) stdout=$($remoteResult.stdout) stderr=$($remoteResult.stderr)"}
  $payload=$jsonLine|ConvertFrom-Json -ErrorAction Stop
  if([string]$payload.host -ne $expectedHost){throw "Unexpected H3 host: $($payload.host)"}

  Save-Result ([ordered]@{schema=1;status='completed';classification=[string]$payload.classification;syncedSha=$SyncedSha;systemIdentity=[string]$identity.Name;systemKeyFingerprint=$fingerprint;readOnly=$true;remoteMutation='NONE';remote=$payload;capturedAt=(Get-Date -Format o)})
  exit 0
}catch{
  Save-Result ([ordered]@{schema=1;status='failed';classification='H3_GENERIC_WORKER_READONLY_PREFLIGHT_FAILED';syncedSha=$SyncedSha;error=$_.Exception.Message;readOnly=$true;remoteMutation='NONE';capturedAt=(Get-Date -Format o)})
  exit 20
}
