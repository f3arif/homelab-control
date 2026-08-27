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
$latestState=Join-Path $stateRoot 'latest.json'
$requestFile=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwen27b-benchmark.json'
$relay=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen27B-WebsiteBenchmark.ps1'
$sourceState='C:\ProgramData\AFZ\OpenAIAgent\source-state.json'
$logFile=Join-Path $stateRoot 'request-watcher.log'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Log([string]$Message){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $Message" -Encoding UTF8}
function Save-WatchState([string]$JobId,[string]$Status,[string]$Message,[int]$RelayPid=0){
  [ordered]@{ok=($Status -notin @('error','failed'));jobId=$JobId;status=$Status;message=$Message;relayPid=$RelayPid;intervalSeconds=$IntervalSeconds;updatedAt=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Read-Json([string]$Path){if(-not(Test-Path $Path)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Current-Sha{
  $s=Read-Json $sourceState
  if($s -and ([string]$s.remoteSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.remoteSha).ToLowerInvariant()}
  return ''
}
function Valid-Request($r){
  if(-not $r){return $false}
  if([int]$r.schema -ne 1){return $false}
  if([string]$r.project -ne 'qwen38-27b-website-benchmark'){return $false}
  if(([string]$r.job_id) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return $false}
  try{$start=[int]$r.start_iteration;$max=[int]$r.max_iterations}catch{return $false}
  return ($start -ge 1 -and $start -le 8 -and $max -ge $start -and $max -le 8)
}

$mutex=New-Object Threading.Mutex($false,'Global\AFZH3Qwen27BRequestWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  Log "START interval=${IntervalSeconds}s transport=github-synced-request"
  while($true){
    try{
      if(Test-Path $requestFile){
        $req=Read-Json $requestFile
        if(-not(Valid-Request $req)){throw "Invalid typed request: $requestFile"}
        $jobId=[string]$req.job_id
        $start=[int]$req.start_iteration
        $max=[int]$req.max_iterations
        $latest=Read-Json $latestState
        $handled=Read-Json $watchState

        if($latest -and [string]$latest.jobId -eq $jobId -and [string]$latest.status -in @('completed','failed','error')){
          Save-WatchState $jobId 'handled' ("Terminal benchmark state already recorded: "+[string]$latest.status)
        }
        elseif($latest -and [string]$latest.jobId -eq $jobId -and [string]$latest.status -eq 'running'){
          $pidValue=0;try{$pidValue=[int]$latest.relayPid}catch{}
          if($pidValue -gt 0 -and (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)){
            Save-WatchState $jobId 'running' 'Benchmark relay is active.' $pidValue
          }
        }
        elseif($handled -and [string]$handled.jobId -eq $jobId -and [string]$handled.status -in @('started','running','handled')){
          # Idempotency: one launch per immutable job_id. Change job_id to request an explicit retry.
        }
        else{
          if(-not(Test-Path $relay)){throw "Benchmark relay missing: $relay"}
          $sha=Current-Sha
          if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Current exact GitHub source SHA unavailable'}
          $argLine="-NoProfile -ExecutionPolicy Bypass -File `"$relay`" -InstallRoot `"$InstallRoot`" -JobId `"$jobId`" -StartIteration $start -MaxIterations $max -ExpectedSha `"$sha`""
          $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
          Save-WatchState $jobId 'started' "Typed H3 benchmark relay started from GitHub request at source $sha" $p.Id
          Log "START_JOB job=$jobId pid=$($p.Id) sha=$sha start=$start max=$max"
        }
      }
    }catch{
      $msg=$_.Exception.Message
      Log "ERROR $msg"
      Save-WatchState '' 'error' $msg
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
