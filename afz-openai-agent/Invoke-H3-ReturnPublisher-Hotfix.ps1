#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [Parameter(Mandatory=$true)][string]$SyncedSha
)
$ErrorActionPreference='Stop'
if($SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'SyncedSha must be a 40-character Git commit SHA'}
$SyncedSha=$SyncedSha.ToLowerInvariant()

# Safety freeze: generation 5 transport is already repaired. This helper is no
# longer allowed to retry the publisher automatically on source sync. The only
# executable child allowed here is the read-only, marker-guarded postmortem.
$generationState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-direct-return-generation\latest.json'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix'
$marker=Join-Path $root 'gh-argument-binding-v1.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-RETURN-PUBLISHER-HOTFIX-LATEST.json'
$postmortem=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-ReturnPublisher-Postmortem.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Read-Json([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}}
function Publish-Diagnostic($Object){
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $d=[ordered]@{schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';source='windows-main';controlPlane='github';observedAt=(Get-Date -Format o);hotfix=$Object}
    [IO.File]::WriteAllText($diagFile,($d|ConvertTo-Json -Depth 40 -Compress),$utf8)
  }catch{}
}
function Save($Object){[IO.File]::WriteAllText($marker,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8);Publish-Diagnostic $Object;Write-Output ($Object|ConvertTo-Json -Depth 30 -Compress)}
function Invoke-ReadOnlyPostmortem {
  if(-not(Test-Path -LiteralPath $postmortem -PathType Leaf)){
    return [ordered]@{ok=$false;status='postmortem-helper-missing';readOnly=$true;syncedSha=$SyncedSha}
  }
  try {
    $raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $postmortem -InstallRoot $InstallRoot -SyncedSha $SyncedSha | Select-Object -Last 1
    $code=$LASTEXITCODE
    if($raw -is [string]){try{$parsed=$raw|ConvertFrom-Json}catch{$parsed=[ordered]@{ok=$false;status='postmortem-result-invalid';readOnly=$true;raw=[string]$raw}}}else{$parsed=$raw}
    if($code -ne 0){return [ordered]@{ok=$false;status='postmortem-process-failed';readOnly=$true;exit=$code;result=$parsed}}
    return $parsed
  } catch {
    return [ordered]@{ok=$false;status='postmortem-exception';readOnly=$true;error=$_.Exception.Message}
  }
}

# Always allow the read-only postmortem to expose its own durable diagnostic.
# It is independently marker-guarded and cannot run the publisher or Qwen.
$postmortemResult=Invoke-ReadOnlyPostmortem

$prior=Read-Json $marker
if($prior){Publish-Diagnostic $prior;Write-Output ($prior|ConvertTo-Json -Depth 30 -Compress);exit 0}
$g=Read-Json $generationState
if(-not $g -or [int]$g.generation -ne 5 -or [string]$g.status -ne 'completed' -or -not [bool]$g.ok){
  $na=[ordered]@{schema=1;ok=$false;status='not-applicable';reason='generation-5-not-completed';syncedSha=$SyncedSha;returnOnly=$true;postmortem=$postmortemResult;updatedAt=(Get-Date -Format o)}
  Publish-Diagnostic $na
  Write-Output ($na|ConvertTo-Json -Depth 30 -Compress)
  exit 0
}

$paused=[ordered]@{
  schema=1
  ok=$false
  status='paused-postmortem'
  reason='Automatic publisher retry is frozen. Only the read-only H3 publisher postmortem is permitted from this hook.'
  generation=5
  syncedSha=$SyncedSha
  target='DESKTOP-H3R6CQN'
  returnOnly=$true
  publisherRetryAllowed=$false
  qwenLaunchAllowed=$false
  postmortem=$postmortemResult
  updatedAt=(Get-Date -Format o)
}
Save $paused
exit 0
