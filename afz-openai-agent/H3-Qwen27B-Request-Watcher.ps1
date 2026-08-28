#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen27b'
$watchState=Join-Path $stateRoot 'request-watcher.json'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwen27b-benchmark.json'
$bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-GitHub-DirectBenchmark.ps1'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$bootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-github-direct-bootstrap\latest.json'
$logFile=Join-Path $stateRoot 'request-watcher.log'

$owStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-openwebui-pipe-request'
$owWatchState=Join-Path $owStateRoot 'request-watcher.json'
$owRequestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-openwebui-afz-pipe.json'
$owBootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-OpenWebUI-AFZ-Pipe.ps1'
$owBootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-openwebui-pipe-bootstrap\latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot,$owStateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Save-WatchState([string]$JobId,[string]$Status,[string]$Message,[int]$PidValue=0){
  [ordered]@{ok=($Status -notin @('error','failed'));jobId=$JobId;status=$Status;message=$Message;bootstrapPid=$PidValue;transport='one-time-bootstrap-to-h3-direct-github';intervalSeconds=$IntervalSeconds;updatedAt=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Save-OpenWebUIState([string]$JobId,[string]$Status,[string]$Message,[string]$Sha,[int]$PidValue=0){
  [ordered]@{ok=($Status -notin @('error','failed'));jobId=$JobId;status=$Status;message=$Message;expectedSha=$Sha;bootstrapPid=$PidValue;transport='windows-main-ssh+github-exact-sha';intervalSeconds=$IntervalSeconds;updatedAt=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $owWatchState -Encoding UTF8
}
function Read-Json([string]$Path){if(-not(Test-Path $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Current-Sha{$s=Read-Json $sourceState;if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).ToLowerInvariant()};return ''}
function Valid-Request($r){if(-not $r){return $false};if([int]$r.schema -ne 1){return $false};if([string]$r.project -ne 'qwen38-27b-website-benchmark'){return $false};if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false};try{$start=[int]$r.start_iteration;$max=[int]$r.max_iterations}catch{return $false};return ($start -ge 1 -and $start -le 8 -and $max -ge $start -and $max -le 8)}
function Valid-OpenWebUIRequest($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'openwebui-afz-agent'){return $false}
  if([string]$r.action -ne 'install-afz-typed-agent-pipe'){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  return $true
}

function Handle-BenchmarkRequest {
  if(-not(Test-Path $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}
  $bs=Read-Json $bootstrapState
  $handled=Read-Json $watchState
  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $sha){
    Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub watcher installed; benchmark dispatch no longer uses windows-main or AFZ queue.'
  }
  elseif($handled -and [string]$handled.status -eq 'bootstrapping' -and [int]$handled.bootstrapPid -gt 0 -and (Get-Process -Id ([int]$handled.bootstrapPid) -ErrorAction SilentlyContinue)){
    return
  }
  else{
    if(-not(Test-Path $bootstrap)){throw "H3 direct bootstrap script missing: $bootstrap"}
    $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`""
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    Save-WatchState $jobId 'bootstrapping' "Installing H3-local GitHub watcher from exact source $sha" $p.Id
    Log "BENCHMARK_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
  }
}

function Handle-OpenWebUIRequest {
  if(-not(Test-Path $owRequestFile)){return}
  $req=Read-Json $owRequestFile
  if(-not(Valid-OpenWebUIRequest $req)){throw "Invalid typed OpenWebUI request: $owRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for OpenWebUI request'}
  $bs=Read-Json $owBootstrapState
  $handled=Read-Json $owWatchState
  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha){
    Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe installed/enabled and smoke-tested in H3 OpenWebUI.' $sha
    return
  }
  if($handled -and [string]$handled.status -eq 'bootstrapping' -and [string]$handled.expectedSha -eq $sha -and [int]$handled.bootstrapPid -gt 0 -and (Get-Process -Id ([int]$handled.bootstrapPid) -ErrorAction SilentlyContinue)){
    return
  }
  if(-not(Test-Path $owBootstrap)){throw "H3 OpenWebUI bootstrap script missing: $owBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$owBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-OpenWebUIState $jobId 'bootstrapping' "Installing AFZ Typed Agent Pipe on H3 from exact source $sha" $sha $p.Id
  Log "OPENWEBUI_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap"
  while($true){
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg";Save-OpenWebUIState '' 'error' $msg (Current-Sha)}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg";Save-WatchState '' 'error' $msg}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
