#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
# Multi-role secretless request watcher. Existing H3/OpenWebUI behavior is preserved;
# Marketplace Manager is install/validate only and cannot edit listings from this watcher.
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
$owBreadcrumb=Join-Path $owStateRoot 'latest.txt'

$mpStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\marketplace-manager-request'
$mpWatchState=Join-Path $mpStateRoot 'request-watcher.json'
$mpRequestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\marketplace-manager.json'
$mpBootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-Marketplace-Manager.ps1'
$mpBootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\marketplace-manager\latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot,$owStateRoot,$mpStateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Save-WatchState([string]$JobId,[string]$Status,[string]$Message,[int]$PidValue=0){
  [ordered]@{ok=($Status -notin @('error','failed'));jobId=$JobId;status=$Status;message=$Message;bootstrapPid=$PidValue;transport='one-time-bootstrap-to-h3-direct-github';intervalSeconds=$IntervalSeconds;updatedAt=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Save-OpenWebUIState([string]$JobId,[string]$Status,[string]$Message,[string]$Sha,[int]$PidValue=0){
  $o=[ordered]@{ok=($Status -notin @('error','failed'));jobId=$JobId;status=$Status;message=$Message;expectedSha=$Sha;bootstrapPid=$PidValue;transport='windows-main-ssh+github-exact-sha';intervalSeconds=$IntervalSeconds;updatedAt=(Get-Date -Format o)}
  $o|ConvertTo-Json -Depth 8 -Compress|Set-Content -LiteralPath $owWatchState -Encoding UTF8
  try{
    $parent=Split-Path -Parent $owBreadcrumb
    New-Item -ItemType Directory -Force -Path $parent|Out-Null
    $lines=@('AFZ_OPENWEBUI_PIPE_WATCHER','STATUS='+$Status,'JOB_ID='+$JobId,'EXPECTED_SHA='+$Sha,'BOOTSTRAP_PID='+$PidValue,'MESSAGE='+$Message,'UPDATED_AT='+$o.updatedAt)
    [IO.File]::WriteAllText($owBreadcrumb,($lines -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
  }catch{}
}
function Save-MarketplaceState([string]$JobId,[string]$Status,[string]$Message,[string]$Sha,[int]$PidValue=0){
  [ordered]@{ok=($Status -notin @('error','failed'));jobId=$JobId;status=$Status;message=$Message;expectedSha=$Sha;bootstrapPid=$PidValue;mode='install-validate-dryrun';transport='github-exact-sha-to-windows-main';intervalSeconds=$IntervalSeconds;updatedAt=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $mpWatchState -Encoding UTF8
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
function Valid-MarketplaceRequest($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'marketplace-manager'){return $false}
  if([string]$r.action -ne 'install-validate-dryrun'){return $false}
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
  elseif($handled -and [string]$handled.status -eq 'bootstrapping' -and [int]$handled.bootstrapPid -gt 0 -and (Get-Process -Id ([int]$handled.bootstrapPid) -ErrorAction SilentlyContinue)){return}
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
  $jobId=[string]$req.job_id; $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for OpenWebUI request'}
  $bs=Read-Json $owBootstrapState; $handled=Read-Json $owWatchState
  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha){Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe installed/enabled and smoke-tested in H3 OpenWebUI.' $sha;return}
  if($handled -and [string]$handled.status -eq 'bootstrapping' -and [string]$handled.expectedSha -eq $sha -and [int]$handled.bootstrapPid -gt 0 -and (Get-Process -Id ([int]$handled.bootstrapPid) -ErrorAction SilentlyContinue)){return}
  if(-not(Test-Path $owBootstrap)){throw "H3 OpenWebUI bootstrap script missing: $owBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$owBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-OpenWebUIState $jobId 'bootstrapping' "Installing AFZ Typed Agent Pipe on H3 from exact source $sha" $sha $p.Id
  Log "OPENWEBUI_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}
function Handle-MarketplaceRequest {
  if(-not(Test-Path $mpRequestFile)){return}
  $req=Read-Json $mpRequestFile
  if(-not(Valid-MarketplaceRequest $req)){throw "Invalid typed Marketplace request: $mpRequestFile"}
  $jobId=[string]$req.job_id; $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Marketplace request'}
  $bs=Read-Json $mpBootstrapState; $handled=Read-Json $mpWatchState
  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha){
    Save-MarketplaceState $jobId 'completed' 'Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.' $sha; return
  }
  if($handled -and [string]$handled.status -eq 'bootstrapping' -and [string]$handled.expectedSha -eq $sha -and [int]$handled.bootstrapPid -gt 0 -and (Get-Process -Id ([int]$handled.bootstrapPid) -ErrorAction SilentlyContinue)){return}
  if(-not(Test-Path $mpBootstrap)){throw "Marketplace bootstrap script missing: $mpBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$mpBootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-MarketplaceState $jobId 'bootstrapping' "Installing Marketplace Manager from exact source $sha" $sha $p.Id
  Log "MARKETPLACE_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate"
  while($true){
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg";Save-MarketplaceState '' 'error' $msg (Current-Sha)}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg";Save-OpenWebUIState '' 'error' $msg (Current-Sha)}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg";Save-WatchState '' 'error' $msg}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{if($locked){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
