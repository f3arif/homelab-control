#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$JobId,
  [int]$StartIteration=2,
  [int]$MaxIterations=5,
  [Parameter(Mandatory=$true)][string]$ExpectedSha
)

$ErrorActionPreference='Stop'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen27b'
$stateFile=Join-Path $stateRoot 'latest.json'
$logRoot=Join-Path $stateRoot $JobId
$outFile=Join-Path $logRoot 'h3.stdout.log'
$errFile=Join-Path $logRoot 'h3.stderr.log'
$knownHosts='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$key='C:\Users\Faiz\.ssh\afz_h3_worker'
$h3='Faiz@100.106.186.118'
$projectRoot='C:\Projects\Qwen38-27B-Website-Benchmark-20260826-174739'
$model='qwen3.8:27b'
$utf8=New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$logRoot | Out-Null

function Write-State([string]$Status,[string]$Message,$Result=$null){
  $o=[ordered]@{ok=($Status -notin @('failed','error'));jobId=$JobId;status=$Status;message=$Message;worker='H3';host='DESKTOP-H3R6CQN';model=$model;project='qwen38-27b-website-benchmark';relayPid=$PID;startedAt=$script:startedAt;updatedAt=(Get-Date -Format o);expectedSha=$ExpectedSha;startIteration=$StartIteration;maxIterations=$MaxIterations}
  if($Result){$o.result=$Result}
  [IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 20 -Compress),$utf8)
}

$startedAt=(Get-Date -Format o)
try{
  if($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){throw 'Invalid JobId'}
  if($ExpectedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedSha must be a 40-character commit SHA'}
  $ExpectedSha=$ExpectedSha.ToLowerInvariant()
  if($StartIteration -lt 1 -or $StartIteration -gt 8){throw 'StartIteration out of range'}
  if($MaxIterations -lt $StartIteration -or $MaxIterations -gt 8){throw 'MaxIterations out of range'}
  if(-not(Test-Path $key)){throw "H3 SSH key missing: $key"}
  $ssh=(Get-Command ssh.exe -ErrorAction Stop).Source
  Write-State 'running' 'Preparing exact-SHA H3 benchmark controller.'

  $rawUrl="https://raw.githubusercontent.com/f3arif/homelab-control/$ExpectedSha/afz-openai-agent/tools/Run-H3-Qwen27B-WebsiteBenchmark.ps1"
  $remote=@"
`$ErrorActionPreference='Stop'
`$dir='C:\AFZ\QwenBenchmark'
New-Item -ItemType Directory -Force -Path `$dir | Out-Null
`$script=Join-Path `$dir 'Run-H3-Qwen27B-WebsiteBenchmark.ps1'
Invoke-WebRequest -Uri '$rawUrl' -OutFile `$script -UseBasicParsing -TimeoutSec 60
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$script -ProjectRoot '$projectRoot' -Model '$model' -StartIteration $StartIteration -MaxIterations $MaxIterations
exit `$LASTEXITCODE
"@
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  $args=@('-i',$key,'-o','BatchMode=yes','-o','ConnectTimeout=12','-o','ServerAliveInterval=30','-o','ServerAliveCountMax=6','-o','StrictHostKeyChecking=accept-new','-o',"UserKnownHostsFile=$knownHosts",$h3,'powershell.exe','-NoProfile','-EncodedCommand',$encoded)
  Write-State 'running' 'Executing bounded Qwen benchmark loop on H3.'
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardOutput $outFile -RedirectStandardError $errFile -Wait -PassThru -NoNewWindow
  $stdout='';$stderr='';if(Test-Path $outFile){$stdout=Get-Content $outFile -Raw};if(Test-Path $errFile){$stderr=Get-Content $errFile -Raw}
  $marker=@($stdout -split "`r?`n" | Where-Object {$_.StartsWith('AFZ_RESULT_JSON=')} | Select-Object -Last 1)
  if($marker.Count -eq 0){throw "H3 benchmark returned no AFZ_RESULT_JSON marker. sshExit=$($p.ExitCode)"}
  $json=$marker[0].Substring('AFZ_RESULT_JSON='.Length)
  $result=$json|ConvertFrom-Json
  $status=if([bool]$result.ok){'completed'}else{'failed'}
  Write-State $status ("H3 benchmark finished: "+[string]$result.benchmarkStatus) $result
  if([bool]$result.ok){exit 0}else{exit 2}
} catch {
  $msg=$_.Exception.Message
  try{Write-State 'failed' $msg}catch{}
  Write-Error $msg
  exit 1
}
