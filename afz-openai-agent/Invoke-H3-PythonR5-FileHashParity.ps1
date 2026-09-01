#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='h3-python-r5-live-parity-20260831-r1'
$candidateCommit='278e927cec726ad86535ef06039c2d3e9c6082cf'
$targetPath='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1'
$expectedWorkerSha='b61d8eb4e625549836c504d102bc0139d1c97786447e2ea071ac9dbc8f02795e'
$expectedLauncherSha='f8007a26f62831b515849dc9643399fac253ae23cac058db41cca83e4e80640e'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-python-r5-filehash'
$latestPath=Join-Path $stateRoot 'latest.json'
$passPath=Join-Path $stateRoot 'pass-v1.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'H3-R5-FILEHASH-PARITY-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Publish-Result($o,[bool]$Passed=$false){
  $json=$o|ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($latestPath,$json,$utf8)
  if($Passed){[IO.File]::WriteAllText($passPath,$json,$utf8)}
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output $json
}

if(Test-Path -LiteralPath $passPath -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $passPath -Raw|ConvertFrom-Json
    if([string]$prior.classification -eq 'H3_R5_FILEHASH_PARITY_PASS' -and [string]$prior.jobId -eq $jobId -and [string]$prior.candidateCommit -eq $candidateCommit){
      Publish-Result ([ordered]@{schema=1;status='completed';classification='H3_R5_FILEHASH_PARITY_ALREADY_PASSED';jobId=$jobId;candidateCommit=$candidateCommit;readOnlyCandidate=$true;legacyMutation='NONE_ALREADY_COMPLETED';prior=$prior;observedAt=(Get-Date -Format o)}) $true
      exit 0
    }
  }catch{}
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if([string]$identity.User.Value -ne 'S-1-5-18'){
  Publish-Result ([ordered]@{schema=1;status='failed';classification='H3_R5_PARITY_SYSTEM_REQUIRED';jobId=$jobId;candidateCommit=$candidateCommit;identity=[string]$identity.Name;remoteMutation='NONE';observedAt=(Get-Date -Format o)})
  exit 20
}
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){Publish-Result ([ordered]@{schema=1;status='failed';classification='H3_R5_PARITY_LOCAL_PREREQUISITE_MISSING';jobId=$jobId;candidateCommit=$candidateCommit;path=$p;remoteMutation='NONE';observedAt=(Get-Date -Format o)});exit 20}}

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''R5 parity stdin empty.''};& ([scriptblock]::Create($script))'
$bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$jobId='h3-python-r5-live-parity-20260831-r1'
$project='AFZ-H3-Python-Migration'
$action='h3-file-hash'
$candidateCommit='278e927cec726ad86535ef06039c2d3e9c6082cf'
$targetPath='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1'
$workerScript='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1'
$launcher='C:\AFZ\H3Worker\Run-AFZ-H3-Worker-Task-Hidden.vbs'
$expectedWorkerSha='b61d8eb4e625549836c504d102bc0139d1c97786447e2ea071ac9dbc8f02795e'
$expectedLauncherSha='f8007a26f62831b515849dc9643399fac253ae23cac058db41cca83e4e80640e'
$taskName='AFZ H3 Generic Worker'
$utf8=New-Object Text.UTF8Encoding($false)
$tempRoot=Join-Path $env:TEMP ('afz-h3-r5-filehash-'+$jobId)

function Get-Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
function Get-Workers {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop | Where-Object {[string]$_.CommandLine -like ('*'+$workerScript+'*')} | Select-Object ProcessId,ParentProcessId,Name,CommandLine)
}
function Find-OneDriveRoot {
  $candidates=@()
  if(-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial)){$candidates+=$env:OneDriveCommercial}
  $candidates+=@('G:\Engineering\OneDrive - AFZ Engineering Inc',(Join-Path $env:USERPROFILE 'OneDrive - AFZ Engineering Inc'))
  foreach($c in $candidates){if($c -and (Test-Path -LiteralPath $c -PathType Container)){return [IO.Path]::GetFullPath($c)}}
  throw 'H3 OneDrive root not found.'
}
function Read-Heartbeat([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Heartbeat missing: $Path"}
  $m=@{}
  foreach($line in Get-Content -LiteralPath $Path -ErrorAction Stop){if($line -match '^([^=]+)=(.*)$'){$m[$matches[1]]=$matches[2]}}
  if(-not $m.ContainsKey('Timestamp') -or -not $m.ContainsKey('PID')){throw 'Heartbeat missing Timestamp/PID.'}
  [ordered]@{timestamp=[datetimeoffset]::Parse([string]$m.Timestamp);pid=[int]$m.PID;state=[string]$m.State;queueCount=$(if($m.ContainsKey('QueueCount')){[int]$m.QueueCount}else{$null})}
}
function Assert-FreshHeartbeat($Heartbeat,[int]$Pid){
  $age=((Get-Date)-$Heartbeat.timestamp.LocalDateTime).TotalSeconds
  if($age -lt -5 -or $age -gt 120){throw "H3 heartbeat stale: age=$([math]::Round($age,1))"}
  if([int]$Heartbeat.pid -ne $Pid){throw "H3 heartbeat PID mismatch: heartbeat=$($Heartbeat.pid) worker=$Pid"}
  if([string]$Heartbeat.state -ne 'READY'){throw "H3 heartbeat not READY: $($Heartbeat.state)"}
}
function Get-ExistingJobPath([string[]]$Dirs,[string]$SafeId){
  foreach($d in $Dirs){
    foreach($ext in @('.json','.txt')){
      $p=Join-Path $d ($SafeId+$ext)
      if(Test-Path -LiteralPath $p -PathType Leaf){return $p}
    }
  }
  return $null
}

$mutation='NONE'
$pythonSummary=$null
$legacySummary=$null
$legacyResult=$null
$submitted=$false
$reusedExisting=$false
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Wrong H3 host: $env:COMPUTERNAME"}
  foreach($p in @($workerScript,$launcher)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 path missing: $p"}}
  $workerSha=Get-Sha $workerScript
  $launcherSha=Get-Sha $launcher
  if($workerSha -ne $expectedWorkerSha){throw "Worker SHA mismatch: $workerSha"}
  if($launcherSha -ne $expectedLauncherSha){throw "Launcher SHA mismatch: $launcherSha"}
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if([string]$task.State -ne 'Running'){throw "H3 Generic Worker task not Running: $($task.State)"}
  $workers=@(Get-Workers)
  if($workers.Count -ne 1){throw "Expected exactly one H3 Generic Worker process; count=$($workers.Count)"}
  $workerPid=[int]$workers[0].ProcessId
  $workerText=[IO.File]::ReadAllText($workerScript)
  foreach($needle in @("'h3-file-hash'",'$Job.args.path','Write-Result','[string]$Job.action')){if(-not $workerText.Contains($needle)){throw "Live worker contract marker missing: $needle"}}

  $oneDriveRoot=Find-OneDriveRoot
  $hub=Join-Path $oneDriveRoot 'AFZ Shared\AFZ Workers'
  $queue=Join-Path $hub 'Queue\h3'
  $processing=Join-Path $hub 'Processing\h3'
  $results=Join-Path $hub 'Results\h3'
  $archive=Join-Path $hub 'Archive\h3'
  $heartbeatPath=Join-Path $hub 'Heartbeat\h3.txt'
  foreach($d in @($queue,$processing,$results,$archive)){if(-not(Test-Path -LiteralPath $d -PathType Container)){throw "H3 worker directory missing: $d"}}
  $hbBefore=Read-Heartbeat $heartbeatPath
  Assert-FreshHeartbeat $hbBefore $workerPid

  if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop}
  $pkg=Join-Path $tempRoot 'afz_h3_worker'
  New-Item -ItemType Directory -Force -Path $pkg|Out-Null
  [IO.File]::WriteAllText((Join-Path $pkg '__init__.py'),'',$utf8)
  $rawBase='https://raw.githubusercontent.com/f3arif/homelab-control/'+$candidateCommit+'/afz-openai-agent/h3-python-worker/afz_h3_worker/'
  Invoke-WebRequest -UseBasicParsing -Uri ($rawBase+'actions.py') -OutFile (Join-Path $pkg 'actions.py') -TimeoutSec 30
  Invoke-WebRequest -UseBasicParsing -Uri ($rawBase+'parity.py') -OutFile (Join-Path $pkg 'parity.py') -TimeoutSec 30
  $runner=Join-Path $tempRoot 'run_candidate.py'
  $runnerText=@"
import json,sys
from afz_h3_worker.actions import h3_file_hash
print(json.dumps(h3_file_hash(sys.argv[1], allowed_roots=(sys.argv[2],)), separators=(',',':')))
"@
  [IO.File]::WriteAllText($runner,$runnerText,$utf8)
  $python=$null
  foreach($name in @('python.exe','python3.exe')){$cmd=Get-Command $name -ErrorAction SilentlyContinue|Select-Object -First 1;if($cmd){$python=[string]$cmd.Source;break}}
  if(-not $python){throw 'Python executable not found on H3.'}
  $candidateOut=@(& $python $runner $targetPath 'C:\AFZ\H3Worker' 2>&1)
  $candidateExit=$LASTEXITCODE
  if($candidateExit -ne 0){throw "Python candidate failed exit=$candidateExit output=$(($candidateOut|ForEach-Object{[string]$_}) -join ' | ')"}
  $candidateLine=($candidateOut|ForEach-Object{[string]$_}|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $candidateLine){throw 'Python candidate returned no JSON.'}
  $candidate=$candidateLine|ConvertFrom-Json -ErrorAction Stop
  $pythonSummary=@($candidate.summary|ForEach-Object{[string]$_})
  if($pythonSummary.Count -ne 3){throw "Python candidate summary count unexpected: $($pythonSummary.Count)"}

  $safeId=($jobId -replace '[^A-Za-z0-9._-]','_')
  $resultJson=Join-Path $results ($safeId+'.json')
  $existing=Get-ExistingJobPath @($results,$processing,$queue,$archive) $safeId
  if(Test-Path -LiteralPath $resultJson -PathType Leaf){$reusedExisting=$true}
  elseif($existing){$reusedExisting=$true}
  else{
    $request=[ordered]@{id=$jobId;project=$project;action=$action;args=[ordered]@{path=$targetPath}}
    $requestJson=($request|ConvertTo-Json -Depth 6 -Compress)
    $tmp=Join-Path $queue ($safeId+'.json.tmp-'+[guid]::NewGuid().ToString('n'))
    $final=Join-Path $queue ($safeId+'.json')
    [IO.File]::WriteAllText($tmp,$requestJson,$utf8)
    Move-Item -LiteralPath $tmp -Destination $final -Force
    $submitted=$true
    $mutation='BOUNDED_LEGACY_FILE_HASH_REQUEST_SUBMITTED'
  }

  $deadline=(Get-Date).AddSeconds(60)
  while((Get-Date) -lt $deadline -and -not(Test-Path -LiteralPath $resultJson -PathType Leaf)){Start-Sleep -Milliseconds 500}
  if(-not(Test-Path -LiteralPath $resultJson -PathType Leaf)){throw "Legacy h3-file-hash result did not arrive within 60 seconds. existing=$existing"}
  $legacyResult=Get-Content -LiteralPath $resultJson -Raw|ConvertFrom-Json -ErrorAction Stop
  if([string]$legacyResult.id -ne $jobId -or [string]$legacyResult.action -ne $action -or -not [bool]$legacyResult.ok){throw "Legacy result contract failed: id=$($legacyResult.id) action=$($legacyResult.action) ok=$($legacyResult.ok) error=$($legacyResult.error)"}
  $legacySummary=@($legacyResult.result.summary|ForEach-Object{[string]$_})
  if($legacySummary.Count -ne 3){throw "Legacy summary count unexpected: $($legacySummary.Count)"}
  $expected=@('FILE_HASH : READ ONLY',('PATH='+$targetPath),('SHA256='+$expectedWorkerSha.ToUpperInvariant()))
  $legacyJson=$legacySummary|ConvertTo-Json -Compress
  $pythonJson=$pythonSummary|ConvertTo-Json -Compress
  $expectedJson=$expected|ConvertTo-Json -Compress
  if($legacyJson -cne $expectedJson){throw "Legacy summary mismatch: $legacyJson"}
  if($pythonJson -cne $expectedJson){throw "Python summary mismatch: $pythonJson"}
  if($legacyJson -cne $pythonJson){throw 'Legacy/Python summary mismatch.'}

  $taskAfter=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if([string]$taskAfter.State -ne 'Running'){throw "H3 task changed state after canary: $($taskAfter.State)"}
  $workersAfter=@(Get-Workers)
  if($workersAfter.Count -ne 1 -or [int]$workersAfter[0].ProcessId -ne $workerPid){throw 'H3 Generic Worker PID changed during canary.'}
  if((Get-Sha $workerScript) -ne $expectedWorkerSha){throw 'Worker SHA changed during canary.'}
  if((Get-Sha $launcher) -ne $expectedLauncherSha){throw 'Launcher SHA changed during canary.'}
  $hbAfter=Read-Heartbeat $heartbeatPath
  Assert-FreshHeartbeat $hbAfter $workerPid
  $orphanCandidates=@(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3.exe'" -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -like ('*'+$tempRoot+'*')})
  if($orphanCandidates.Count -ne 0){throw "Candidate Python orphan process count=$($orphanCandidates.Count)"}

  [ordered]@{schema=1;status='completed';classification='H3_R5_FILEHASH_PARITY_PASS';jobId=$jobId;candidateCommit=$candidateCommit;host=$env:COMPUTERNAME;workerPid=$workerPid;workerSha=$workerSha;launcherSha=$launcherSha;legacySubmitted=$submitted;legacyReusedExisting=$reusedExisting;legacyMutation=$mutation;legacySummary=$legacySummary;pythonSummary=$pythonSummary;heartbeatBefore=$hbBefore.timestamp.ToString('o');heartbeatAfter=$hbAfter.timestamp.ToString('o');taskState=[string]$taskAfter.State;orphanCandidateProcesses=0;forcedSleep=$false;ollamaExposureChanged=$false;cutoverActivated=$false;serviceInstalled=$false;routingChanged=$false;finishedAt=(Get-Date -Format o)}|ConvertTo-Json -Depth 15 -Compress
}finally{
  if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
'@

$inFile=Join-Path $env:TEMP ('afz-h3-r5-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-r5-out-'+[guid]::NewGuid().ToString('n')+'.txt')
$errFile=Join-Path $env:TEMP ('afz-h3-r5-err-'+[guid]::NewGuid().ToString('n')+'.txt')
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded)
  $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};throw 'H3 R5 parity SSH run timed out after 120 seconds.'}
  $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile)}else{''})
  $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile)}else{''})
  $jsonLine=(([string]$stdout -split "`r?`n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if([int]$p.ExitCode -ne 0 -or -not $jsonLine){throw "H3 R5 parity remote failure exit=$($p.ExitCode) stdout=$stdout stderr=$stderr"}
  $parsed=$jsonLine|ConvertFrom-Json -ErrorAction Stop
  if([string]$parsed.classification -ne 'H3_R5_FILEHASH_PARITY_PASS'){throw "Unexpected R5 parity classification: $($parsed.classification)"}
  Publish-Result ([ordered]@{schema=1;status='completed';classification='H3_R5_FILEHASH_PARITY_PASS';jobId=$jobId;candidateCommit=$candidateCommit;systemIdentity=[string]$identity.Name;remote=$parsed;observedAt=(Get-Date -Format o)}) $true
  exit 0
}catch{
  Publish-Result ([ordered]@{schema=1;status='failed';classification='H3_R5_FILEHASH_PARITY_FAILED';jobId=$jobId;candidateCommit=$candidateCommit;systemIdentity=[string]$identity.Name;error=$_.Exception.Message;remoteMutation='NONE_OR_IDEMPOTENT_BOUNDED_CANARY';observedAt=(Get-Date -Format o)})
  exit 20
}finally{
  Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
}
