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
# longer allowed to retry the publisher automatically on every source sync.
# It only preserves/exposes an existing terminal marker, or creates a durable
# paused-postmortem marker if the earlier attempt failed before Save().
$generationState='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-direct-return-generation\latest.json'
$root='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix'
$marker=Join-Path $root 'gh-argument-binding-v1.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'H3-RETURN-PUBLISHER-HOTFIX-LATEST.json'
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

$prior=Read-Json $marker
if($prior){Publish-Diagnostic $prior;Write-Output ($prior|ConvertTo-Json -Depth 30 -Compress);exit 0}
$g=Read-Json $generationState
if(-not $g -or [int]$g.generation -ne 5 -or [string]$g.status -ne 'completed' -or -not [bool]$g.ok){
  $na=[ordered]@{schema=1;ok=$false;status='not-applicable';reason='generation-5-not-completed';syncedSha=$SyncedSha;returnOnly=$true;updatedAt=(Get-Date -Format o)}
  Publish-Diagnostic $na
  Write-Output ($na|ConvertTo-Json -Compress)
  exit 0
}

$paused=[ordered]@{
  schema=1
  ok=$false
  status='paused-postmortem'
  reason='Prior one-shot publisher hotfix was invoked by a completed exact-SHA sync but produced no terminal marker or durable GitHub status. Automatic retry is frozen pending read-only H3 postmortem.'
  generation=5
  syncedSha=$SyncedSha
  target='DESKTOP-H3R6CQN'
  returnOnly=$true
  publisherRetryAllowed=$false
  qwenLaunchAllowed=$false
  updatedAt=(Get-Date -Format o)
}
Save $paused
exit 0
