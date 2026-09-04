#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)
# Multi-role secretless request watcher.
# Each request is one-shot by job_id. A repository SHA change never replays an old request.
# To intentionally rerun a lane, publish a new typed request with a new job_id.
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

$ridgeStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-request'
$ridgeWatchState=Join-Path $ridgeStateRoot 'request-watcher.json'
$ridgeRequestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwenridge16k-website-test.json'
$ridgeBootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-QwenRidge16K-WebsiteTest.ps1'
$ridgeBootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-bootstrap\latest.json'

$dcStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\desktop-commander-remote-request'
$dcWatchState=Join-Path $dcStateRoot 'request-watcher.json'
$dcRequestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\windows-main-desktop-commander-remote.json'
$dcBootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-WindowsMain-DesktopCommanderRemote.ps1'
$dcBootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\desktop-commander-remote-pairing\latest.json'

New-Item -ItemType Directory -Force -Path $stateRoot,$owStateRoot,$mpStateRoot,$ridgeStateRoot,$dcStateRoot | Out-Null

function Log([string]$Message){
  Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}
function Save-WatchState(
  [string]$JobId,
  [string]$Status,
  [string]$Message,
  [string]$Sha='',
  [int]$PidValue=0
){
  [ordered]@{
    ok=($Status -notin @('error','failed'))
    jobId=$JobId
    status=$Status
    message=$Message
    expectedSha=$Sha
    bootstrapPid=$PidValue
    transport='one-time-bootstrap-to-h3-direct-github'
    intervalSeconds=$IntervalSeconds
    updatedAt=(Get-Date -Format o)
  } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Save-OpenWebUIState(
  [string]$JobId,
  [string]$Status,
  [string]$Message,
  [string]$Sha,
  [int]$PidValue=0
){
  $o=[ordered]@{
    ok=($Status -notin @('error','failed'))
    jobId=$JobId
    status=$Status
    message=$Message
    expectedSha=$Sha
    bootstrapPid=$PidValue
    transport='windows-main-ssh+github-exact-sha'
    intervalSeconds=$IntervalSeconds
    updatedAt=(Get-Date -Format o)
  }
  $o | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $owWatchState -Encoding UTF8
  try{
    $parent=Split-Path -Parent $owBreadcrumb
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $lines=@(
      'AFZ_OPENWEBUI_PIPE_WATCHER',
      'STATUS='+$Status,
      'JOB_ID='+$JobId,
      'EXPECTED_SHA='+$Sha,
      'BOOTSTRAP_PID='+$PidValue,
      'MESSAGE='+$Message,
      'UPDATED_AT='+$o.updatedAt
    )
    [IO.File]::WriteAllText($owBreadcrumb,($lines -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
  }catch{}
}
function Save-MarketplaceState(
  [string]$JobId,
  [string]$Status,
  [string]$Message,
  [string]$Sha,
  [int]$PidValue=0
){
  [ordered]@{
    ok=($Status -notin @('error','failed'))
    jobId=$JobId
    status=$Status
    message=$Message
    expectedSha=$Sha
    bootstrapPid=$PidValue
    mode='install-validate-dryrun'
    transport='github-exact-sha-to-windows-main'
    intervalSeconds=$IntervalSeconds
    updatedAt=(Get-Date -Format o)
  } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $mpWatchState -Encoding UTF8
}
function Save-RidgeState(
  [string]$JobId,
  [string]$Status,
  [string]$Message,
  [string]$Sha,
  [int]$PidValue=0
){
  [ordered]@{
    ok=($Status -notin @('error','failed'))
    jobId=$JobId
    status=$Status
    message=$Message
    expectedSha=$Sha
    bootstrapPid=$PidValue
    model='qwen3.8-ridge:27b-16k'
    context=16384
    noThink=$true
    modelCalls=1
    transport='github-exact-sha-windows-main-to-h3-detached'
    intervalSeconds=$IntervalSeconds
    updatedAt=(Get-Date -Format o)
  } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $ridgeWatchState -Encoding UTF8
}
function Save-DesktopCommanderState(
  [string]$JobId,
  [string]$Status,
  [string]$Message,
  [string]$Sha,
  [int]$PidValue=0
){
  [ordered]@{
    ok=($Status -notin @('error','failed'))
    jobId=$JobId
    status=$Status
    message=$Message
    expectedSha=$Sha
    bootstrapPid=$PidValue
    target='DESKTOP-10SKF0M'
    transport='github-exact-sha-local-interactive-pairing'
    persistentStartup=$false
    authMaterialCaptured=$false
    intervalSeconds=$IntervalSeconds
    updatedAt=(Get-Date -Format o)
  } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $dcWatchState -Encoding UTF8
}
function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json}catch{return $null}
}
function Current-Sha{
  $s=Read-Json $sourceState
  if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){
    return ([string]$s.remoteSha).ToLowerInvariant()
  }
  return ''
}
function Same-Job($State,[string]$JobId){
  return ($State -and [string]$State.jobId -eq $JobId)
}
function Is-TerminalStatus([string]$Status){
  return ($Status -in @('completed','failed','error','h3-direct'))
}
function Process-IsAlive([int]$PidValue){
  if($PidValue -le 0){return $false}
  return [bool](Get-Process -Id $PidValue -ErrorAction SilentlyContinue)
}
function Valid-Request($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'qwen38-27b-website-benchmark'){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  try{$start=[int]$r.start_iteration;$max=[int]$r.max_iterations}catch{return $false}
  return ($start -ge 1 -and $start -le 8 -and $max -ge $start -and $max -le 8)
}
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
function Valid-RidgeRequest($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'qwen38-ridge16k-website-direct-test'){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  if([string]$r.model -ne 'qwen3.8-ridge:27b-16k'){return $false}
  if([int]$r.context -ne 16384){return $false}
  if(-not [bool]$r.no_think){return $false}
  if([int]$r.max_model_calls -ne 1){return $false}
  $routes=@($r.required_routes|ForEach-Object {[string]$_})
  $expected=@('/','/services','/projects','/about','/contact')
  if($routes.Count -ne $expected.Count){return $false}
  foreach($route in $expected){if($routes -notcontains $route){return $false}}
  return $true
}

function Valid-DesktopCommanderRequest($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'desktop-commander-remote'){return $false}
  if([string]$r.action -ne 'launch-windows-main-pairing'){return $false}
  if([string]$r.target -ne 'windows-main'){return $false}
  if([string]$r.host -ne 'DESKTOP-10SKF0M'){return $false}
  if([bool]$r.persistent_startup){return $false}
  if([bool]$r.capture_auth_material){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}

  $handled=Read-Json $watchState
  $bs=Read-Json $bootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $pinnedSha){
        Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher installed; benchmark request completed.' $pinnedSha
        Log "BENCHMARK_TERMINAL_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }

      $reason='Benchmark bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.status -eq 'failed'){$reason='Benchmark bootstrap failed: '+[string]$bs.message}
      Save-WatchState $jobId 'failed' $reason $pinnedSha
      Log "BENCHMARK_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-WatchState $jobId 'failed' ("Unexpected prior benchmark state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $sha){
    Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher already installed at this exact SHA.' $sha
    return
  }

  if(-not(Test-Path -LiteralPath $bootstrap)){throw "H3 direct bootstrap script missing: $bootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-WatchState $jobId 'bootstrapping' "Installing H3-local GitHub return publisher from exact source $sha" $sha $p.Id
  Log "BENCHMARK_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-OpenWebUIRequest {
  if(-not(Test-Path -LiteralPath $owRequestFile)){return}
  $req=Read-Json $owRequestFile
  if(-not(Valid-OpenWebUIRequest $req)){throw "Invalid typed OpenWebUI request: $owRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for OpenWebUI request'}

  $handled=Read-Json $owWatchState
  $bs=Read-Json $owBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe installed/enabled and smoke-tested in H3 OpenWebUI.' ([string]$bs.expectedSha)
        Log "OPENWEBUI_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='OpenWebUI bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='OpenWebUI bootstrap failed: '+[string]$bs.message}
      Save-OpenWebUIState $jobId 'failed' $reason $pinnedSha
      Log "OPENWEBUI_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-OpenWebUIState $jobId 'failed' ("Unexpected prior OpenWebUI state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-OpenWebUIState $jobId 'failed' ('OpenWebUI bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $owBootstrap)){throw "H3 OpenWebUI bootstrap script missing: $owBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$owBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-OpenWebUIState $jobId 'bootstrapping' "Installing AFZ Typed Agent Pipe on H3 from exact source $sha" $sha $p.Id
  Log "OPENWEBUI_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-MarketplaceRequest {
  if(-not(Test-Path -LiteralPath $mpRequestFile)){return}
  $req=Read-Json $mpRequestFile
  if(-not(Valid-MarketplaceRequest $req)){throw "Invalid typed Marketplace request: $mpRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Marketplace request'}

  $handled=Read-Json $mpWatchState
  $bs=Read-Json $mpBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-MarketplaceState $jobId 'completed' 'Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.' ([string]$bs.expectedSha)
        Log "MARKETPLACE_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='Marketplace bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Marketplace bootstrap failed: '+[string]$bs.message}
      Save-MarketplaceState $jobId 'failed' $reason $pinnedSha
      Log "MARKETPLACE_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-MarketplaceState $jobId 'failed' ("Unexpected prior Marketplace state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-MarketplaceState $jobId 'completed' 'Marketplace Manager was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-MarketplaceState $jobId 'failed' ('Marketplace bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $mpBootstrap)){throw "Marketplace bootstrap script missing: $mpBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$mpBootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-MarketplaceState $jobId 'bootstrapping' "Installing Marketplace Manager from exact source $sha" $sha $p.Id
  Log "MARKETPLACE_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-RidgeRequest {
  if(-not(Test-Path -LiteralPath $ridgeRequestFile)){return}
  $req=Read-Json $ridgeRequestFile
  if(-not(Valid-RidgeRequest $req)){throw "Invalid typed Ridge16K request: $ridgeRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Ridge16K request'}

  $handled=Read-Json $ridgeWatchState
  $bs=Read-Json $ridgeBootstrapState
  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}
    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $pinnedSha -and [string]$bs.status -eq 'completed'){
        Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner launch was proven; generation and GitHub result publishing are H3-local.' $pinnedSha
        Log "RIDGE16K_TERMINAL_LAUNCH_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }
      $reason='Ridge16K bootstrap exited before durable H3 launch proof; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Ridge16K bootstrap failed: '+[string]$bs.message}
      Save-RidgeState $jobId 'failed' $reason $pinnedSha
      Log "RIDGE16K_TERMINAL_LAUNCH_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }
    Save-RidgeState $jobId 'failed' ("Unexpected prior Ridge16K state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha -and [string]$bs.status -eq 'completed'){
    Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner was already launched for this exact job/SHA.' $sha
    return
  }
  if(-not(Test-Path -LiteralPath $ridgeBootstrap)){throw "H3 Ridge16K bootstrap script missing: $ridgeBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$ridgeBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-RidgeState $jobId 'bootstrapping' "Launching H3 Ridge16K no-think website test from exact source $sha" $sha $p.Id
  Log "RIDGE16K_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-DesktopCommanderRequest {
  if(-not(Test-Path -LiteralPath $dcRequestFile)){return}
  $req=Read-Json $dcRequestFile
  if(-not(Valid-DesktopCommanderRequest $req)){throw "Invalid typed Desktop Commander request: $dcRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate,qwen-ridge16k-bootstrap,desktop-commander-pairing one-shot-job-id=true"
  while($true){
    try{Handle-DesktopCommanderRequest}catch{$msg=$_.Exception.Message;Log "DESKTOP_COMMANDER_ERROR $msg"}
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg"}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg"}
    try{Handle-RidgeRequest}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
){return $false}
  return $true
}

function Handle-BenchmarkRequest {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}

  $handled=Read-Json $watchState
  $bs=Read-Json $bootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $pinnedSha){
        Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher installed; benchmark request completed.' $pinnedSha
        Log "BENCHMARK_TERMINAL_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }

      $reason='Benchmark bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.status -eq 'failed'){$reason='Benchmark bootstrap failed: '+[string]$bs.message}
      Save-WatchState $jobId 'failed' $reason $pinnedSha
      Log "BENCHMARK_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-WatchState $jobId 'failed' ("Unexpected prior benchmark state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $sha){
    Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher already installed at this exact SHA.' $sha
    return
  }

  if(-not(Test-Path -LiteralPath $bootstrap)){throw "H3 direct bootstrap script missing: $bootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-WatchState $jobId 'bootstrapping' "Installing H3-local GitHub return publisher from exact source $sha" $sha $p.Id
  Log "BENCHMARK_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-OpenWebUIRequest {
  if(-not(Test-Path -LiteralPath $owRequestFile)){return}
  $req=Read-Json $owRequestFile
  if(-not(Valid-OpenWebUIRequest $req)){throw "Invalid typed OpenWebUI request: $owRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for OpenWebUI request'}

  $handled=Read-Json $owWatchState
  $bs=Read-Json $owBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe installed/enabled and smoke-tested in H3 OpenWebUI.' ([string]$bs.expectedSha)
        Log "OPENWEBUI_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='OpenWebUI bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='OpenWebUI bootstrap failed: '+[string]$bs.message}
      Save-OpenWebUIState $jobId 'failed' $reason $pinnedSha
      Log "OPENWEBUI_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-OpenWebUIState $jobId 'failed' ("Unexpected prior OpenWebUI state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-OpenWebUIState $jobId 'failed' ('OpenWebUI bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $owBootstrap)){throw "H3 OpenWebUI bootstrap script missing: $owBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$owBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-OpenWebUIState $jobId 'bootstrapping' "Installing AFZ Typed Agent Pipe on H3 from exact source $sha" $sha $p.Id
  Log "OPENWEBUI_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-MarketplaceRequest {
  if(-not(Test-Path -LiteralPath $mpRequestFile)){return}
  $req=Read-Json $mpRequestFile
  if(-not(Valid-MarketplaceRequest $req)){throw "Invalid typed Marketplace request: $mpRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Marketplace request'}

  $handled=Read-Json $mpWatchState
  $bs=Read-Json $mpBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-MarketplaceState $jobId 'completed' 'Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.' ([string]$bs.expectedSha)
        Log "MARKETPLACE_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='Marketplace bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Marketplace bootstrap failed: '+[string]$bs.message}
      Save-MarketplaceState $jobId 'failed' $reason $pinnedSha
      Log "MARKETPLACE_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-MarketplaceState $jobId 'failed' ("Unexpected prior Marketplace state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-MarketplaceState $jobId 'completed' 'Marketplace Manager was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-MarketplaceState $jobId 'failed' ('Marketplace bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $mpBootstrap)){throw "Marketplace bootstrap script missing: $mpBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$mpBootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-MarketplaceState $jobId 'bootstrapping' "Installing Marketplace Manager from exact source $sha" $sha $p.Id
  Log "MARKETPLACE_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-RidgeRequest {
  if(-not(Test-Path -LiteralPath $ridgeRequestFile)){return}
  $req=Read-Json $ridgeRequestFile
  if(-not(Valid-RidgeRequest $req)){throw "Invalid typed Ridge16K request: $ridgeRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Ridge16K request'}

  $handled=Read-Json $ridgeWatchState
  $bs=Read-Json $ridgeBootstrapState
  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}
    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $pinnedSha -and [string]$bs.status -eq 'completed'){
        Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner launch was proven; generation and GitHub result publishing are H3-local.' $pinnedSha
        Log "RIDGE16K_TERMINAL_LAUNCH_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }
      $reason='Ridge16K bootstrap exited before durable H3 launch proof; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Ridge16K bootstrap failed: '+[string]$bs.message}
      Save-RidgeState $jobId 'failed' $reason $pinnedSha
      Log "RIDGE16K_TERMINAL_LAUNCH_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }
    Save-RidgeState $jobId 'failed' ("Unexpected prior Ridge16K state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha -and [string]$bs.status -eq 'completed'){
    Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner was already launched for this exact job/SHA.' $sha
    return
  }
  if(-not(Test-Path -LiteralPath $ridgeBootstrap)){throw "H3 Ridge16K bootstrap script missing: $ridgeBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$ridgeBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-RidgeState $jobId 'bootstrapping' "Launching H3 Ridge16K no-think website test from exact source $sha" $sha $p.Id
  Log "RIDGE16K_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate,qwen-ridge16k-bootstrap one-shot-job-id=true"
  while($true){
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg"}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg"}
    try{Handle-RidgeRequest}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
){throw 'Current exact GitHub source SHA unavailable for Desktop Commander request'}

  $handled=Read-Json $dcWatchState
  $bs=Read-Json $dcBootstrapState
  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if($status -in @('completed','failed','error')){return}
    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate,qwen-ridge16k-bootstrap one-shot-job-id=true"
  while($true){
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg"}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg"}
    try{Handle-RidgeRequest}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
){return $false}
  return $true
}

function Handle-BenchmarkRequest {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}

  $handled=Read-Json $watchState
  $bs=Read-Json $bootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $pinnedSha){
        Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher installed; benchmark request completed.' $pinnedSha
        Log "BENCHMARK_TERMINAL_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }

      $reason='Benchmark bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.status -eq 'failed'){$reason='Benchmark bootstrap failed: '+[string]$bs.message}
      Save-WatchState $jobId 'failed' $reason $pinnedSha
      Log "BENCHMARK_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-WatchState $jobId 'failed' ("Unexpected prior benchmark state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $sha){
    Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher already installed at this exact SHA.' $sha
    return
  }

  if(-not(Test-Path -LiteralPath $bootstrap)){throw "H3 direct bootstrap script missing: $bootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-WatchState $jobId 'bootstrapping' "Installing H3-local GitHub return publisher from exact source $sha" $sha $p.Id
  Log "BENCHMARK_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-OpenWebUIRequest {
  if(-not(Test-Path -LiteralPath $owRequestFile)){return}
  $req=Read-Json $owRequestFile
  if(-not(Valid-OpenWebUIRequest $req)){throw "Invalid typed OpenWebUI request: $owRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for OpenWebUI request'}

  $handled=Read-Json $owWatchState
  $bs=Read-Json $owBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe installed/enabled and smoke-tested in H3 OpenWebUI.' ([string]$bs.expectedSha)
        Log "OPENWEBUI_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='OpenWebUI bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='OpenWebUI bootstrap failed: '+[string]$bs.message}
      Save-OpenWebUIState $jobId 'failed' $reason $pinnedSha
      Log "OPENWEBUI_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-OpenWebUIState $jobId 'failed' ("Unexpected prior OpenWebUI state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-OpenWebUIState $jobId 'failed' ('OpenWebUI bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $owBootstrap)){throw "H3 OpenWebUI bootstrap script missing: $owBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$owBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-OpenWebUIState $jobId 'bootstrapping' "Installing AFZ Typed Agent Pipe on H3 from exact source $sha" $sha $p.Id
  Log "OPENWEBUI_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-MarketplaceRequest {
  if(-not(Test-Path -LiteralPath $mpRequestFile)){return}
  $req=Read-Json $mpRequestFile
  if(-not(Valid-MarketplaceRequest $req)){throw "Invalid typed Marketplace request: $mpRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Marketplace request'}

  $handled=Read-Json $mpWatchState
  $bs=Read-Json $mpBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-MarketplaceState $jobId 'completed' 'Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.' ([string]$bs.expectedSha)
        Log "MARKETPLACE_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='Marketplace bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Marketplace bootstrap failed: '+[string]$bs.message}
      Save-MarketplaceState $jobId 'failed' $reason $pinnedSha
      Log "MARKETPLACE_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-MarketplaceState $jobId 'failed' ("Unexpected prior Marketplace state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-MarketplaceState $jobId 'completed' 'Marketplace Manager was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-MarketplaceState $jobId 'failed' ('Marketplace bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $mpBootstrap)){throw "Marketplace bootstrap script missing: $mpBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$mpBootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-MarketplaceState $jobId 'bootstrapping' "Installing Marketplace Manager from exact source $sha" $sha $p.Id
  Log "MARKETPLACE_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-RidgeRequest {
  if(-not(Test-Path -LiteralPath $ridgeRequestFile)){return}
  $req=Read-Json $ridgeRequestFile
  if(-not(Valid-RidgeRequest $req)){throw "Invalid typed Ridge16K request: $ridgeRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Ridge16K request'}

  $handled=Read-Json $ridgeWatchState
  $bs=Read-Json $ridgeBootstrapState
  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}
    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $pinnedSha -and [string]$bs.status -eq 'completed'){
        Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner launch was proven; generation and GitHub result publishing are H3-local.' $pinnedSha
        Log "RIDGE16K_TERMINAL_LAUNCH_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }
      $reason='Ridge16K bootstrap exited before durable H3 launch proof; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Ridge16K bootstrap failed: '+[string]$bs.message}
      Save-RidgeState $jobId 'failed' $reason $pinnedSha
      Log "RIDGE16K_TERMINAL_LAUNCH_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }
    Save-RidgeState $jobId 'failed' ("Unexpected prior Ridge16K state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha -and [string]$bs.status -eq 'completed'){
    Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner was already launched for this exact job/SHA.' $sha
    return
  }
  if(-not(Test-Path -LiteralPath $ridgeBootstrap)){throw "H3 Ridge16K bootstrap script missing: $ridgeBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$ridgeBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-RidgeState $jobId 'bootstrapping' "Launching H3 Ridge16K no-think website test from exact source $sha" $sha $p.Id
  Log "RIDGE16K_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate,qwen-ridge16k-bootstrap one-shot-job-id=true"
  while($true){
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg"}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg"}
    try{Handle-RidgeRequest}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $pinnedSha -and [string]$bs.status -eq 'awaiting-user-authorization'){
        Save-DesktopCommanderState $jobId 'completed' 'Interactive Desktop Commander Remote MCP pairing is running on Windows-main and awaiting local device authorization.' $pinnedSha
        Log "DESKTOP_COMMANDER_PAIRING_LAUNCHED job=$jobId sha=$pinnedSha"
        return
      }
      $reason='Desktop Commander pairing bootstrap exited without a durable awaiting-user-authorization state.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Desktop Commander bootstrap failed: '+[string]$bs.message}
      Save-DesktopCommanderState $jobId 'failed' $reason $pinnedSha
      Log "DESKTOP_COMMANDER_PAIRING_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }
    Save-DesktopCommanderState $jobId 'failed' ("Unexpected prior Desktop Commander state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'awaiting-user-authorization'){
    Save-DesktopCommanderState $jobId 'completed' 'Interactive Desktop Commander pairing was already launched for this request.' ([string]$bs.expectedSha)
    return
  }
  if(-not(Test-Path -LiteralPath $dcBootstrap)){throw "Desktop Commander bootstrap script missing: $dcBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$dcBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-DesktopCommanderState $jobId 'bootstrapping' "Launching Windows-main interactive Desktop Commander pairing from exact source $sha" $sha $p.Id
  Log "DESKTOP_COMMANDER_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate,qwen-ridge16k-bootstrap one-shot-job-id=true"
  while($true){
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg"}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg"}
    try{Handle-RidgeRequest}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
){return $false}
  return $true
}

function Handle-BenchmarkRequest {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}

  $handled=Read-Json $watchState
  $bs=Read-Json $bootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $pinnedSha){
        Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher installed; benchmark request completed.' $pinnedSha
        Log "BENCHMARK_TERMINAL_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }

      $reason='Benchmark bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.status -eq 'failed'){$reason='Benchmark bootstrap failed: '+[string]$bs.message}
      Save-WatchState $jobId 'failed' $reason $pinnedSha
      Log "BENCHMARK_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-WatchState $jobId 'failed' ("Unexpected prior benchmark state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.status -eq 'completed' -and [string]$bs.expectedSha -eq $sha){
    Save-WatchState $jobId 'h3-direct' 'H3 direct GitHub return publisher already installed at this exact SHA.' $sha
    return
  }

  if(-not(Test-Path -LiteralPath $bootstrap)){throw "H3 direct bootstrap script missing: $bootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-WatchState $jobId 'bootstrapping' "Installing H3-local GitHub return publisher from exact source $sha" $sha $p.Id
  Log "BENCHMARK_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-OpenWebUIRequest {
  if(-not(Test-Path -LiteralPath $owRequestFile)){return}
  $req=Read-Json $owRequestFile
  if(-not(Valid-OpenWebUIRequest $req)){throw "Invalid typed OpenWebUI request: $owRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for OpenWebUI request'}

  $handled=Read-Json $owWatchState
  $bs=Read-Json $owBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe installed/enabled and smoke-tested in H3 OpenWebUI.' ([string]$bs.expectedSha)
        Log "OPENWEBUI_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='OpenWebUI bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='OpenWebUI bootstrap failed: '+[string]$bs.message}
      Save-OpenWebUIState $jobId 'failed' $reason $pinnedSha
      Log "OPENWEBUI_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-OpenWebUIState $jobId 'failed' ("Unexpected prior OpenWebUI state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-OpenWebUIState $jobId 'completed' 'AFZ Typed Agent Pipe was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-OpenWebUIState $jobId 'failed' ('OpenWebUI bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $owBootstrap)){throw "H3 OpenWebUI bootstrap script missing: $owBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$owBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-OpenWebUIState $jobId 'bootstrapping' "Installing AFZ Typed Agent Pipe on H3 from exact source $sha" $sha $p.Id
  Log "OPENWEBUI_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-MarketplaceRequest {
  if(-not(Test-Path -LiteralPath $mpRequestFile)){return}
  $req=Read-Json $mpRequestFile
  if(-not(Valid-MarketplaceRequest $req)){throw "Invalid typed Marketplace request: $mpRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Marketplace request'}

  $handled=Read-Json $mpWatchState
  $bs=Read-Json $mpBootstrapState

  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}

    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}

      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
        Save-MarketplaceState $jobId 'completed' 'Marketplace Manager installed and dry-run core validated; no Facebook listing was changed.' ([string]$bs.expectedSha)
        Log "MARKETPLACE_TERMINAL_SUCCESS job=$jobId sha=$([string]$bs.expectedSha)"
        return
      }

      $reason='Marketplace bootstrap exited before durable completion; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Marketplace bootstrap failed: '+[string]$bs.message}
      Save-MarketplaceState $jobId 'failed' $reason $pinnedSha
      Log "MARKETPLACE_TERMINAL_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }

    Save-MarketplaceState $jobId 'failed' ("Unexpected prior Marketplace state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'completed'){
    Save-MarketplaceState $jobId 'completed' 'Marketplace Manager was already completed for this request.' ([string]$bs.expectedSha)
    return
  }
  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){
    Save-MarketplaceState $jobId 'failed' ('Marketplace bootstrap previously failed: '+[string]$bs.message) ([string]$bs.expectedSha)
    return
  }

  if(-not(Test-Path -LiteralPath $mpBootstrap)){throw "Marketplace bootstrap script missing: $mpBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$mpBootstrap`" -InstallRoot `"$InstallRoot`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-MarketplaceState $jobId 'bootstrapping' "Installing Marketplace Manager from exact source $sha" $sha $p.Id
  Log "MARKETPLACE_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

function Handle-RidgeRequest {
  if(-not(Test-Path -LiteralPath $ridgeRequestFile)){return}
  $req=Read-Json $ridgeRequestFile
  if(-not(Valid-RidgeRequest $req)){throw "Invalid typed Ridge16K request: $ridgeRequestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Ridge16K request'}

  $handled=Read-Json $ridgeWatchState
  $bs=Read-Json $ridgeBootstrapState
  if(Same-Job $handled $jobId){
    $status=[string]$handled.status
    if(Is-TerminalStatus $status){return}
    if($status -eq 'bootstrapping'){
      $pinnedSha=[string]$handled.expectedSha
      if($pinnedSha -notmatch '^[0-9a-f]{40}$'){$pinnedSha=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $pinnedSha -and [string]$bs.status -eq 'completed'){
        Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner launch was proven; generation and GitHub result publishing are H3-local.' $pinnedSha
        Log "RIDGE16K_TERMINAL_LAUNCH_SUCCESS job=$jobId sha=$pinnedSha"
        return
      }
      $reason='Ridge16K bootstrap exited before durable H3 launch proof; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Ridge16K bootstrap failed: '+[string]$bs.message}
      Save-RidgeState $jobId 'failed' $reason $pinnedSha
      Log "RIDGE16K_TERMINAL_LAUNCH_FAILED job=$jobId sha=$pinnedSha reason=$reason"
      return
    }
    Save-RidgeState $jobId 'failed' ("Unexpected prior Ridge16K state '$status'; request will not replay automatically.") ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha -and [string]$bs.status -eq 'completed'){
    Save-RidgeState $jobId 'h3-direct' 'H3 Ridge16K runner was already launched for this exact job/SHA.' $sha
    return
  }
  if(-not(Test-Path -LiteralPath $ridgeBootstrap)){throw "H3 Ridge16K bootstrap script missing: $ridgeBootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$ridgeBootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-RidgeState $jobId 'bootstrapping' "Launching H3 Ridge16K no-think website test from exact source $sha" $sha $p.Id
  Log "RIDGE16K_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s roles=benchmark-bootstrap,openwebui-pipe-bootstrap,marketplace-install-validate,qwen-ridge16k-bootstrap one-shot-job-id=true"
  while($true){
    try{Handle-MarketplaceRequest}catch{$msg=$_.Exception.Message;Log "MARKETPLACE_ERROR $msg"}
    try{Handle-OpenWebUIRequest}catch{$msg=$_.Exception.Message;Log "OPENWEBUI_ERROR $msg"}
    try{Handle-RidgeRequest}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    try{Handle-BenchmarkRequest}catch{$msg=$_.Exception.Message;Log "BENCHMARK_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
