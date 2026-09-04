#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$jobId='h3-python-r5-live-filehash-system-20260904-r1'
$candidateCommit='3819a0459835746f5e29905d0d1aaa3142e1bd19'
$packagePath='afz-openai-agent/h3-python-worker/afz_h3_worker'
$targetPath='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1'
$allowedRoot='C:\AFZ\H3Worker'
$legacyResult='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\h3\h3-python-r5-legacy-file-hash-20260830T1406.txt'
$legacySha='B61D8EB4E625549836C504D102BC0139D1C97786447E2EA071AC9DBC8F02795E'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$target='Faiz@100.106.186.118'
$expectedHost='DESKTOP-H3R6CQN'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$git=(Get-Command git.exe,git -ErrorAction Stop|Select-Object -First 1).Source
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-python-r5-filehash-parity'
$statePath=Join-Path $stateRoot ($jobId+'.json')
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'H3-PYTHON-R5-FILEHASH-PARITY-LATEST.json'
$sharedRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$sharedPath=Join-Path $sharedRoot 'AFZ-H3-PYTHON-R5-FILEHASH-PARITY-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 30 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  try{if(Test-Path -LiteralPath $sharedRoot -PathType Container){[IO.File]::WriteAllText($sharedPath,$json,$utf8)}}catch{}
  Write-Output $json
}

function Invoke-H3Script([string]$RemoteScript){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''R5 parity stdin empty.''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@(
    '-i',$key,
    '-o','IdentitiesOnly=yes',
    '-o','BatchMode=yes',
    '-o','ConnectTimeout=8',
    '-o','StrictHostKeyChecking=yes',
    '-o',('UserKnownHostsFile='+$known),
    $target,
    'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded
  )
  $inFile=Join-Path $env:TEMP ('afz-r5-parity-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-r5-parity-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-r5-parity-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};throw 'R5 parity SSH timed out after 120 seconds.'}
    $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    [ordered]@{exit=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr}
  }finally{
    Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{$existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json;Write-Output ($existing|ConvertTo-Json -Depth 30 -Compress);exit 0}catch{}
}

try{
  if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA.'}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "SYSTEM execution required; actual=$($identity.Name)"}
  foreach($p in @($key,$known,$ssh,$git)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required path missing: $p"}}

  & $git -C $InstallRoot cat-file -e ($candidateCommit+'^{commit}') 2>$null
  if($LASTEXITCODE -ne 0){throw "Pinned R5 candidate commit not present locally: $candidateCommit"}

  $zip=Join-Path $env:TEMP ('afz-h3-r5-'+[guid]::NewGuid().ToString('n')+'.zip')
  try{
    & $git -C $InstallRoot archive --format=zip --output=$zip $candidateCommit -- $packagePath
    if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $zip -PathType Leaf)){throw 'git archive of pinned R5 candidate failed.'}
    $zipSha=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $zipB64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
  }finally{
    if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue}
  }

  $remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$jobId='__JOB_ID__'
$expectedHost='__EXPECTED_HOST__'
$targetPath='__TARGET_PATH__'
$allowedRoot='__ALLOWED_ROOT__'
$legacyResult='__LEGACY_RESULT__'
$legacySha='__LEGACY_SHA__'
$stageRoot=Join-Path $env:LOCALAPPDATA ('AFZ\H3PythonR5Parity\'+$jobId)
$zipPath=Join-Path $stageRoot 'candidate.zip'
$extractRoot=Join-Path $stageRoot 'src'
$runnerPath=Join-Path $stageRoot 'run_candidate.py'
$outPath=Join-Path $stageRoot 'candidate.stdout.txt'
$errPath=Join-Path $stageRoot 'candidate.stderr.txt'
$heartbeat='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Heartbeat\h3.txt'
$workerScript='C:\AFZ\H3Worker\AFZ-H3-Worker.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
$zipB64='__ZIP_B64__'

function Get-WorkerPids {
  @(
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
      Where-Object {[string]$_.CommandLine -like ('*'+$workerScript+'*')} |
      ForEach-Object {[int]$_.ProcessId} |
      Sort-Object
  )
}
function Get-HeartbeatState {
  if(-not(Test-Path -LiteralPath $heartbeat -PathType Leaf)){return [ordered]@{exists=$false;lastWrite=$null;ageSeconds=$null}}
  $i=Get-Item -LiteralPath $heartbeat -ErrorAction Stop
  [ordered]@{exists=$true;lastWrite=$i.LastWriteTime.ToString('o');ageSeconds=[math]::Round(((Get-Date)-$i.LastWriteTime).TotalSeconds,1)}
}

$beforePids=@(Get-WorkerPids)
$beforeHeartbeat=Get-HeartbeatState
$cleanupOk=$false
$candidate=$null
$candidateExit=$null
$candidateStdout=''
$candidateStderr=''
$legacySummary=@()
$classification='H3_R5_PARITY_FAILED'
$checks=[ordered]@{}
try{
  if($env:COMPUTERNAME -ne $expectedHost){throw "Unexpected host: $env:COMPUTERNAME"}
  if($beforePids.Count -lt 1){throw 'Legacy H3 Generic Worker process is not running.'}
  if(-not $beforeHeartbeat.exists -or [double]$beforeHeartbeat.ageSeconds -gt 60){throw 'H3 heartbeat is not fresh before parity run.'}
  if(-not(Test-Path -LiteralPath $targetPath -PathType Leaf)){throw "Target missing: $targetPath"}
  if(-not(Test-Path -LiteralPath $allowedRoot -PathType Container)){throw "Allowed root missing: $allowedRoot"}
  if(-not(Test-Path -LiteralPath $legacyResult -PathType Leaf)){throw "Legacy result missing: $legacyResult"}

  $liveSha=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToUpperInvariant()
  $checks['liveWorkerShaMatchesLegacy']=($liveSha -eq $legacySha)
  if(-not $checks['liveWorkerShaMatchesLegacy']){throw "Live worker SHA drifted: $liveSha"}

  $legacyLines=@(Get-Content -LiteralPath $legacyResult -Encoding UTF8)
  $legacyPass=($legacyLines -contains 'Result=PASS')
  $legacyHeader=($legacyLines -contains 'FILE_HASH : READ ONLY')
  $legacyPathLine=@($legacyLines|Where-Object{$_ -like 'PATH=*'}|Select-Object -First 1)
  $legacyShaLine=@($legacyLines|Where-Object{$_ -like 'SHA256=*'}|Select-Object -First 1)
  if(-not $legacyPass -or -not $legacyHeader -or $legacyPathLine.Count -ne 1 -or $legacyShaLine.Count -ne 1){throw 'Legacy result contract is incomplete.'}
  $legacySummary=@('FILE_HASH : READ ONLY',[string]$legacyPathLine[0],[string]$legacyShaLine[0])

  if(Test-Path -LiteralPath $stageRoot){Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction Stop}
  New-Item -ItemType Directory -Force -Path $stageRoot,$extractRoot|Out-Null
  [IO.File]::WriteAllBytes($zipPath,[Convert]::FromBase64String($zipB64))
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

  $packageRoot=Join-Path $extractRoot 'afz-openai-agent\h3-python-worker'
  $actionsPath=Join-Path $packageRoot 'afz_h3_worker\actions.py'
  $parityPath=Join-Path $packageRoot 'afz_h3_worker\parity.py'
  foreach($p in @($actionsPath,$parityPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Pinned candidate file missing after stage: $p"}}

  $runner=@'
import json
import sys
from afz_h3_worker.actions import h3_file_hash

result = h3_file_hash(sys.argv[1], allowed_roots=[sys.argv[2]])
print(json.dumps(result, separators=(",", ":")))
'@
  [IO.File]::WriteAllText($runnerPath,$runner,$utf8)

  $python=Get-Command python.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  $pythonArgs=@()
  if(-not $python){
    $python=Get-Command py.exe -ErrorAction SilentlyContinue|Select-Object -First 1
    if($python){$pythonArgs+=@('-3')}
  }
  if(-not $python){throw 'No Python interpreter found on H3.'}
  $pythonArgs+=@($runnerPath,$targetPath,$allowedRoot)

  $oldPythonPath=$env:PYTHONPATH
  try{
    $env:PYTHONPATH=$packageRoot
    $proc=Start-Process -FilePath $python.Source -ArgumentList $pythonArgs -RedirectStandardOutput $outPath -RedirectStandardError $errPath -WindowStyle Hidden -PassThru
    if(-not $proc.WaitForExit(45000)){try{$proc.Kill()}catch{};throw 'Candidate Python process timed out.'}
    $candidateExit=[int]$proc.ExitCode
  }finally{$env:PYTHONPATH=$oldPythonPath}
  $candidateStdout=$(if(Test-Path -LiteralPath $outPath){[IO.File]::ReadAllText($outPath).Trim()}else{''})
  $candidateStderr=$(if(Test-Path -LiteralPath $errPath){[IO.File]::ReadAllText($errPath).Trim()}else{''})
  if($candidateExit -ne 0){throw "Candidate exit=$candidateExit stderr=$candidateStderr"}
  if([string]::IsNullOrWhiteSpace($candidateStdout)){throw 'Candidate returned empty stdout.'}
  $candidate=$candidateStdout|ConvertFrom-Json -ErrorAction Stop
  $candidateSummary=@($candidate.summary|ForEach-Object{[string]$_})

  $checks['candidateExitZero']=($candidateExit -eq 0)
  $checks['candidateStderrEmpty']=[string]::IsNullOrWhiteSpace($candidateStderr)
  $checks['summaryCountExact']=($candidateSummary.Count -eq 3)
  $checks['summary0Exact']=($candidateSummary.Count -ge 1 -and $candidateSummary[0] -ceq $legacySummary[0])
  $checks['summary1Exact']=($candidateSummary.Count -ge 2 -and $candidateSummary[1] -ceq $legacySummary[1])
  $checks['summary2Exact']=($candidateSummary.Count -ge 3 -and $candidateSummary[2] -ceq $legacySummary[2])

  $afterPids=@(Get-WorkerPids)
  $afterHeartbeat=Get-HeartbeatState
  $checks['workerPidContinuity']=(($beforePids -join ',') -eq ($afterPids -join ','))
  $checks['heartbeatFreshAfter']=($afterHeartbeat.exists -and [double]$afterHeartbeat.ageSeconds -le 60)
  $orphans=@(
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='py.exe'" -ErrorAction SilentlyContinue |
      Where-Object {[string]$_.CommandLine -like ('*'+$stageRoot+'*')} |
      ForEach-Object {[int]$_.ProcessId}
  )
  $checks['candidateOrphanCountZero']=($orphans.Count -eq 0)

  $failed=@($checks.GetEnumerator()|Where-Object{-not [bool]$_.Value}|ForEach-Object{[string]$_.Key})
  if($failed.Count -gt 0){throw ('Parity checks failed: '+($failed -join ','))}
  $classification='PASS_R5_LIVE_FILE_HASH_PARITY'
}finally{
  if(Test-Path -LiteralPath $stageRoot){
    try{Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction Stop}catch{}
  }
  $cleanupOk= -not (Test-Path -LiteralPath $stageRoot)
}

$finalPids=@(Get-WorkerPids)
$finalHeartbeat=Get-HeartbeatState
[ordered]@{
  schema=1;purpose='H3_R5_FILE_HASH_LIVE_PARITY';status=$(if($classification -eq 'PASS_R5_LIVE_FILE_HASH_PARITY'){'passed'}else{'failed'});
  classification=$classification;host=$env:COMPUTERNAME;candidateCommit='__CANDIDATE_COMMIT__';candidateZipSha256='__ZIP_SHA__';
  legacyResult=$legacyResult;legacySha=$legacySha;targetPath=$targetPath;allowedRoot=$allowedRoot;
  candidateExit=$candidateExit;candidateStdout=$candidateStdout;candidateStderr=$candidateStderr;candidate=$candidate;
  legacySummary=$legacySummary;checks=$checks;beforePids=$beforePids;finalPids=$finalPids;
  beforeHeartbeat=$beforeHeartbeat;finalHeartbeat=$finalHeartbeat;cleanupOk=$cleanupOk;
  remoteMutation='TRANSIENT_STAGE_ONLY_CLEANED';observedAt=(Get-Date -Format o)
}|ConvertTo-Json -Depth 20 -Compress
'@
  $remote=$remote.Replace('__JOB_ID__',$jobId).Replace('__EXPECTED_HOST__',$expectedHost).Replace('__TARGET_PATH__',$targetPath).Replace('__ALLOWED_ROOT__',$allowedRoot).Replace('__LEGACY_RESULT__',$legacyResult).Replace('__LEGACY_SHA__',$legacySha).Replace('__ZIP_B64__',$zipB64).Replace('__CANDIDATE_COMMIT__',$candidateCommit).Replace('__ZIP_SHA__',$zipSha)

  $rr=Invoke-H3Script $remote
  $jsonLine=@(([string]$rr.stdout -split "\r?\n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $jsonLine){throw "H3 parity returned no JSON. exit=$($rr.exit) stderr=$($rr.stderr) stdout=$($rr.stdout)"}
  $payload=$jsonLine|ConvertFrom-Json -ErrorAction Stop
  $pass=([int]$rr.exit -eq 0 -and [string]$payload.classification -eq 'PASS_R5_LIVE_FILE_HASH_PARITY' -and [bool]$payload.cleanupOk)
  $state=[ordered]@{
    schema=1;status=$(if($pass){'passed'}else{'failed'});classification=[string]$payload.classification;
    jobId=$jobId;syncedSha=$SyncedSha.ToLowerInvariant();candidateCommit=$candidateCommit;candidateZipSha256=$zipSha;
    systemIdentity=[string]$identity.Name;remoteHost=[string]$payload.host;cleanupOk=[bool]$payload.cleanupOk;
    remoteMutation=[string]$payload.remoteMutation;remote=$payload;sshExit=[int]$rr.exit;sshStderr=[string]$rr.stderr;
    capturedAt=(Get-Date -Format o)
  }
  Save-State $state
  if(-not $pass){exit 21}
  exit 0
}catch{
  Save-State ([ordered]@{
    schema=1;status='failed';classification='H3_R5_LIVE_PARITY_SYSTEM_HELPER_FAILED';jobId=$jobId;
    syncedSha=$SyncedSha.ToLowerInvariant();candidateCommit=$candidateCommit;error=$_.Exception.Message;
    remoteMutation='NONE_OR_TRANSIENT_STAGE_CLEANUP_ATTEMPTED';capturedAt=(Get-Date -Format o)
  })
  exit 20
}
