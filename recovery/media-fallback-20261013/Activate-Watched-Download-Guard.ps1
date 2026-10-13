param(
  [string]$CoreRoot='C:\AFZ\Stremio-Failover-H3',
  [Parameter(Mandatory=$true)][string]$GuardRoot,
  [Parameter(Mandatory=$true)][string]$CandidateDir,
  [Parameter(Mandatory=$true)][string]$VerifyScript
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$receipt=Get-Content (Join-Path $CandidateDir 'prepared.json') -Raw | ConvertFrom-Json
$tested=Get-Content (Join-Path $CandidateDir 'candidate-verification.json') -Raw | ConvertFrom-Json
if(-not $tested.passed -or $tested.tests -ne 8){throw 'CANDIDATE_NOT_VERIFIED'}
$files=[ordered]@{
  core=(Join-Path $CoreRoot 'stremio_catalog.py')
  launcher=(Join-Path $CoreRoot 'Start-AFZ-Stremio-H3-Core243.ps1')
  guard=(Join-Path $GuardRoot 'Guard-Source-Health-V3.ps1')
}
$expectedAfter=@{
  core='53a24803e6f2c96e90d238bf479bc6a36ad4ca6c04d3e930fa27a3dcc178cfd6'
  launcher='92ae44ac9f4ae54a5cd5f808b2e0af29db95aa507b3a9db733d2674ba7094bc8'
  guard='30a54c125ccccf45282cc9caa605ca537b3dc54139d1c9384f20c7774dae9d95'
}
function Sha([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Stop-Core {
  $ids=@(Get-NetTCPConnection -State Listen -LocalPort 18774 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
  foreach($servicePid in $ids){
    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$servicePid"
    if(-not $proc -or $proc.Name -notmatch '^python' -or $proc.CommandLine -notmatch 'uvicorn stremio_catalog:app'){throw 'UNEXPECTED_CORE_PROCESS'}
    Stop-Process -Id $servicePid -Force
  }
}
$backup=Join-Path $CandidateDir 'before-activation'
if(Test-Path -LiteralPath $backup){throw 'ACTIVATION_ALREADY_ATTEMPTED_INSPECT_RECEIPTS'}
foreach($name in $files.Keys){
  if((Sha $files[$name]) -ne $receipt.before.$name){throw "LIVE_${name}_CHANGED"}
  if((Sha $receipt.candidates.$name) -ne $expectedAfter[$name] -or $receipt.after.$name -ne $expectedAfter[$name]){throw "CANDIDATE_${name}_CHANGED"}
}
foreach($name in @('launcher','guard')){
  $tokens=$null; $parseErrors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($receipt.candidates.$name,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors.Count){throw "INVALID_${name}_SYNTAX"}
}
# Coordinate the source change and the guard's exact source pin using its own
# deployment mutex. The guard, its integrity checks, and routing stay enabled.
$mutex=New-Object Threading.Mutex($false,'Global\AFZ_SOURCE_HEALTH_V3_GUARD_20261012')
$owned=$false; $written=$false
try {
  try{$owned=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(-not $owned){throw 'GUARD_BUSY'}
  New-Item -ItemType Directory -Path $backup | Out-Null
  foreach($name in $files.Keys){Copy-Item -LiteralPath $files[$name] -Destination (Join-Path $backup ($name+'.before'))}
  $policy=Join-Path $CoreRoot 'state\auto-media-download-policy.json'
  Copy-Item -LiteralPath $policy -Destination (Join-Path $backup 'download-policy.before.json')
  Stop-Core
  $written=$true
  foreach($name in $files.Keys){
    $temp=$files[$name]+'.watched.tmp'
    Copy-Item -LiteralPath $receipt.candidates.$name -Destination $temp
    Move-Item -LiteralPath $temp -Destination $files[$name] -Force
  }
  $python=Join-Path $CoreRoot '.venv\Scripts\python.exe'
  & $python -u $VerifyScript --mode seed --core-root $CoreRoot --candidate-dir $CandidateDir --imdb tt27165187 --title 'The End of Oak Street' --movie-id 23
  if($LASTEXITCODE -ne 0){throw 'SEED_FAILED'}
  Start-ScheduledTask -TaskName 'AFZ Stremio H3 Failover'
  & $python -u $VerifyScript --mode live --core-root $CoreRoot --candidate-dir $CandidateDir --imdb tt27165187 --title 'The End of Oak Street' --movie-id 23
  if($LASTEXITCODE -ne 0){throw 'LIVE_VERIFICATION_FAILED'}
  @{activatedAt=(Get-Date).ToUniversalTime().ToString('o');success=$true;hashes=$expectedAfter;guardPinUpdated=$true;guardPolicyPreserved=$true} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $CandidateDir 'activation.json') -Encoding UTF8
  Write-Output 'WATCHED_DOWNLOAD_GUARD_ACTIVATION_PASSED'
}catch {
  $reason=$_.Exception.Message
  if($written){
    Stop-Core
    foreach($name in $files.Keys){Copy-Item -LiteralPath (Join-Path $backup ($name+'.before')) -Destination $files[$name] -Force}
    # The confirmed watched exclusion remains valid even after code rollback.
    Start-ScheduledTask -TaskName 'AFZ Stremio H3 Failover'
  }
  @{success=$false;rolledBack=$written;reason=$reason;timestamp=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $CandidateDir 'activation-failed.json') -Encoding UTF8
  throw
}finally {
  if($owned){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
