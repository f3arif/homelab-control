param(
  [string]$CoreRoot='C:\AFZ\Stremio-Failover-H3',
  [Parameter(Mandatory=$true)][string]$GuardRoot,
  [Parameter(Mandatory=$true)][string]$CandidateDir,
  [Parameter(Mandatory=$true)][string]$VerifyScript,
  [Parameter(Mandatory=$true)][string]$MovieImdb,
  [Parameter(Mandatory=$true)][string]$MovieItemId,
  [Parameter(Mandatory=$true)][string]$PublicBase
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$receipt=Get-Content (Join-Path $CandidateDir 'prepared.json') -Raw | ConvertFrom-Json
$tested=Get-Content (Join-Path $CandidateDir 'candidate-verification.json') -Raw | ConvertFrom-Json
if(-not $tested.candidatePassed -or -not $tested.wrongItemRejected -or $tested.proxyBytes -ne 1024){throw 'CANDIDATE_NOT_VERIFIED'}
$files=[ordered]@{
  core=(Join-Path $CoreRoot 'stremio_catalog.py')
  launcher=(Join-Path $CoreRoot 'Start-AFZ-Stremio-H3-Core243.ps1')
  guard=(Join-Path $GuardRoot 'Guard-Source-Health-V3.ps1')
}
$expectedAfter=@{
  core='eaea71d7be0ffd3a78650602ee010b2360406bb95486fac286f8f9acefe56b59'
  launcher='9e1a7a77d4eaaba2e825ddfe9f719f94bb565f82c0c68e78a4dc5cd0e729cc8f'
  guard='6b9d1d999bf3b4211e21d73d42e4b6b71cb203e076ff6d44a8c7ac4b5b28f16a'
}
function Sha([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Restart-Core {
  $ids=@(Get-NetTCPConnection -State Listen -LocalPort 18774 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
  foreach($servicePid in $ids){
    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$servicePid"
    if(-not $proc -or $proc.Name -notmatch '^python' -or $proc.CommandLine -notmatch 'uvicorn stremio_catalog:app'){throw 'UNEXPECTED_CORE_PROCESS'}
    Stop-Process -Id $servicePid -Force
  }
  Start-ScheduledTask -TaskName 'AFZ Stremio H3 Failover'
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
# Hold the guard's existing deployment mutex while its code pin is updated.
# The integrity check is retained; neither the task nor its routing is disabled.
$mutex=New-Object Threading.Mutex($false,'Global\AFZ_SOURCE_HEALTH_V3_GUARD_20261012')
$owned=$false; $written=$false
try {
  try{$owned=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(-not $owned){throw 'GUARD_BUSY'}
  New-Item -ItemType Directory -Path $backup | Out-Null
  foreach($name in $files.Keys){Copy-Item -LiteralPath $files[$name] -Destination (Join-Path $backup ($name+'.before'))}
  $written=$true
  foreach($name in $files.Keys){
    $temp=$files[$name]+'.landing.tmp'
    Copy-Item -LiteralPath $receipt.candidates.$name -Destination $temp
    Move-Item -LiteralPath $temp -Destination $files[$name] -Force
  }
  Restart-Core
  Write-Output 'NUVIO_LANDING_INSTALLED_VERIFYING'
  $python=Join-Path $CoreRoot '.venv\Scripts\python.exe'
  & $python -u $VerifyScript --candidate-dir $CandidateDir --imdb $MovieImdb --item-id $MovieItemId --public-base $PublicBase --output (Join-Path $CandidateDir 'live-verification.json')
  if($LASTEXITCODE -ne 0){throw 'LIVE_VERIFICATION_FAILED'}
  $record=[ordered]@{activatedAt=(Get-Date).ToUniversalTime().ToString('o');success=$true;hashes=$expectedAfter;guardPinUpdated=$true;guardPolicyPreserved=$true}
  $record | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $CandidateDir 'activation.json') -Encoding UTF8
  Write-Output 'NUVIO_LANDING_ACTIVATION_PASSED'
}catch {
  $reason=$_.Exception.Message
  if($written){
    foreach($name in $files.Keys){Copy-Item -LiteralPath (Join-Path $backup ($name+'.before')) -Destination $files[$name] -Force}
    Restart-Core
  }
  @{success=$false;rolledBack=$written;reason=$reason;timestamp=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $CandidateDir 'activation-failed.json') -Encoding UTF8
  throw
}finally {
  if($owned){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
