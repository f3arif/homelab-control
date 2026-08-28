#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-direct-return-generation'
$stateFile=Join-Path $stateRoot 'latest.json'
$bootstrapState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-github-direct-bootstrap\latest.json'
$request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-direct-bootstrap-generation.json'
$bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-GitHub-DirectBenchmark.ps1'
$logFile=Join-Path $stateRoot 'latest.log'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-DIRECT-RETURN-GENERATION-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Write-State($Object){[IO.File]::WriteAllText($stateFile,($Object|ConvertTo-Json -Depth 12 -Compress),$utf8)}
function Publish-Diagnostic($Object){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $d=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github';observedAt=(Get-Date -Format o);state=$Object}
    [IO.File]::WriteAllText($diagFile,($d|ConvertTo-Json -Depth 20 -Compress),$utf8)
  }catch{}
}
function Emit($Object){Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 12 -Compress);exit 0}
function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}

$generation=0
try{
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){Emit ([ordered]@{ok=$true;status='not-requested';generation=0;syncedSha=$SyncedSha})}
  $r=Get-Content -LiteralPath $request -Raw|ConvertFrom-Json
  if([int]$r.schema -ne 1){throw 'Return generation request schema must be 1'}
  if([string]$r.purpose -ne 'force-exact-sha-bootstrap-generation'){throw 'Unexpected return generation request purpose'}
  if([string]$r.target -ne 'DESKTOP-H3R6CQN'){throw 'Unexpected return generation target'}
  if([string]$r.lane -ne 'h3-direct-github-benchmark'){throw 'Unexpected return generation lane'}
  if([string]$r.benchmark_job_id -ne 'qwen27b-website-20260827-i02'){throw 'Unexpected benchmark job id in return generation request'}
  $generation=[int]$r.generation
  if($generation -lt 1){throw 'Return generation must be >= 1'}

  $prior=Read-Json $stateFile
  if($prior -and [int]$prior.generation -ge $generation){
    Emit ([ordered]@{ok=([bool]$prior.ok);status='already-attempted';generation=$generation;priorStatus=[string]$prior.status;syncedSha=$SyncedSha;prior=$prior})
  }
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){throw "Return bootstrap missing: $bootstrap"}
  $text=Get-Content -LiteralPath $bootstrap -Raw
  if($text -notmatch [regex]::Escape('Return-only recovery: this script never launches Qwen or creates a benchmark iteration.')){throw 'Return-only bootstrap safety marker missing'}
  if($text -notmatch 'Bootstrap-H3-GitHub-DirectReturnV4\.ps1'){throw 'Return bootstrap is not wired to stdin/V4 transport'}

  $running=[ordered]@{ok=$false;status='running';generation=$generation;syncedSha=$SyncedSha;benchmarkJobId=[string]$r.benchmark_job_id;mode='return-only-v4';startedAt=(Get-Date -Format o)}
  Write-State $running
  Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -ExpectedSha $SyncedSha -InstallRoot $InstallRoot *> $logFile
  $code=$LASTEXITCODE
  $bs=Read-Json $bootstrapState
  $completed=($code -eq 0 -and $bs -and [string]$bs.status -eq 'completed')
  $terminal=[ordered]@{
    ok=$completed
    status=$(if($completed){'completed'}else{'failed'})
    generation=$generation
    syncedSha=$SyncedSha
    benchmarkJobId=[string]$r.benchmark_job_id
    mode='return-only-v4'
    bootstrapExit=$code
    bootstrapStatus=$(if($bs){[string]$bs.status}else{$null})
    bootstrapMessage=$(if($bs){[string]$bs.message}else{$null})
    finishedAt=(Get-Date -Format o)
  }
  Write-State $terminal
  Emit $terminal
}catch{
  $failed=[ordered]@{ok=$false;status='failed';generation=$generation;syncedSha=$SyncedSha;mode='return-only-v4';error=$_.Exception.Message;finishedAt=(Get-Date -Format o)}
  if($generation -gt 0){try{Write-State $failed}catch{}}
  Emit $failed
}
