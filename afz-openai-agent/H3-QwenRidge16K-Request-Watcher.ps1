#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=5
)

$ErrorActionPreference='Stop'
$IntervalSeconds=[math]::Max(3,[math]::Min($IntervalSeconds,30))
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-request'
$watchState=Join-Path $stateRoot 'request-watcher.json'
$logFile=Join-Path $stateRoot 'request-watcher.log'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwenridge16k-website-test.json'
$bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-QwenRidge16K-WebsiteTest.ps1'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$bootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-bootstrap\latest.json'
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Current-Sha {
  $s=Read-Json $sourceState
  if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).ToLowerInvariant()}
  return ''
}
function Process-IsAlive([int]$PidValue){if($PidValue -le 0){return $false};return [bool](Get-Process -Id $PidValue -ErrorAction SilentlyContinue)}
function Save-State([string]$JobId,[string]$Status,[string]$Message,[string]$Sha='',[int]$PidValue=0){
  [ordered]@{
    ok=($Status -notin @('failed','error'))
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
  }|ConvertTo-Json -Depth 8 -Compress|Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Valid-Request($r){
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
function Handle-Request {
  if(-not(Test-Path -LiteralPath $requestFile)){return}
  $req=Read-Json $requestFile
  if(-not(Valid-Request $req)){throw "Invalid typed Ridge16K request: $requestFile"}
  $jobId=[string]$req.job_id
  $sha=Current-Sha
  if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable for Ridge16K request.'}

  $handled=Read-Json $watchState
  $bs=Read-Json $bootstrapState
  if($handled -and [string]$handled.jobId -eq $jobId){
    $status=[string]$handled.status
    if($status -in @('h3-direct','completed','failed','error')){return}
    if($status -eq 'bootstrapping'){
      $pinned=[string]$handled.expectedSha
      if($pinned -notmatch '^[0-9a-f]{40}$'){$pinned=$sha}
      if(Process-IsAlive ([int]$handled.bootstrapPid)){return}
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $pinned -and [string]$bs.status -eq 'completed'){
        Save-State $jobId 'h3-direct' 'H3 Ridge16K runner launch was proven; generation and GitHub result publishing are H3-local.' $pinned
        Log "RIDGE16K_TERMINAL_LAUNCH_SUCCESS job=$jobId sha=$pinned"
        return
      }
      $reason='Ridge16K bootstrap exited before durable H3 launch proof; request is terminal and will not replay automatically.'
      if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.status -eq 'failed'){$reason='Ridge16K bootstrap failed: '+[string]$bs.message}
      Save-State $jobId 'failed' $reason $pinned
      Log "RIDGE16K_TERMINAL_LAUNCH_FAILED job=$jobId sha=$pinned reason=$reason"
      return
    }
    Save-State $jobId 'failed' "Unexpected prior Ridge16K watcher state '$status'; request will not replay automatically." ([string]$handled.expectedSha)
    return
  }

  if($bs -and [string]$bs.jobId -eq $jobId -and [string]$bs.expectedSha -eq $sha -and [string]$bs.status -eq 'completed'){
    Save-State $jobId 'h3-direct' 'H3 Ridge16K runner was already launched for this exact job/SHA.' $sha
    return
  }
  if(-not(Test-Path -LiteralPath $bootstrap)){throw "Ridge16K bootstrap script missing: $bootstrap"}
  $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$sha`" -JobId `"$jobId`""
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Save-State $jobId 'bootstrapping' "Launching H3 Ridge16K no-think website test from exact GitHub source $sha" $sha $p.Id
  Log "RIDGE16K_BOOTSTRAP_START job=$jobId pid=$($p.Id) sha=$sha"
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3QwenRidge16KRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s role=qwen-ridge16k-github-bootstrap one-shot-job-id=true"
  while($true){
    try{Handle-Request}catch{$msg=$_.Exception.Message;Log "RIDGE16K_ERROR $msg"}
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
