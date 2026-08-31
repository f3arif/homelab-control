#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$sourceParent='C:\Users\Faiz\Downloads\Cloud drive'
$link='C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos\OneDrive.mblink'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_WEDDING_FORENSICS_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'

$linkExists=Test-Path -LiteralPath $link -PathType Leaf
Write-Output ('LINK_EXISTS='+$linkExists)
if($linkExists){
  $linkValue=''
  try{$linkValue=([IO.File]::ReadAllText($link)).Trim()}catch{$linkValue='READ_FAILED'}
  Write-Output ('LINK_VALUE='+$linkValue)
  if($linkValue -and $linkValue -ne 'READ_FAILED'){Write-Output ('LINK_TARGET_EXISTS='+(Test-Path -LiteralPath $linkValue))}
}

$sourceExists=Test-Path -LiteralPath $source -PathType Container
Write-Output ('LEGACY_SOURCE='+$source)
Write-Output ('LEGACY_SOURCE_EXISTS='+$sourceExists)
Write-Output ('LEGACY_SOURCE_PARENT_EXISTS='+(Test-Path -LiteralPath $sourceParent -PathType Container))

function Get-MediaCountCapped([string]$p,[int]$cap=10001){
  if(-not(Test-Path -LiteralPath $p -PathType Container)){return 0}
  $n=0
  try{
    foreach($f in Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue){
      if($f.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'){$n++;if($n -ge $cap){break}}
    }
  }catch{}
  return $n
}

if($sourceExists){
  $direct=@(Get-ChildItem -LiteralPath $source -Directory -Force -ErrorAction SilentlyContinue)
  Write-Output ('LEGACY_DIRECT_DIR_COUNT='+$direct.Count)
  foreach($d in $direct|Select-Object -First 100){Write-Output ('LEGACY_DIRECT_DIR='+$d.Name)}
  $w=@($direct|Where-Object {$_.Name -ieq 'Wedding'})
  Write-Output ('LEGACY_WEDDING_DIRECT_COUNT='+$w.Count)
  foreach($d in $w){Write-Output ('LEGACY_WEDDING_PATH='+$d.FullName);Write-Output ('LEGACY_WEDDING_MEDIA_COUNT_CAPPED='+(Get-MediaCountCapped $d.FullName))}
  Write-Output ('LEGACY_SOURCE_MEDIA_COUNT_CAPPED='+(Get-MediaCountCapped $source))
}

# Candidate personal/cloud roots, without traversing AppData or system trees.
$candidates=New-Object System.Collections.Generic.List[string]
foreach($p in @($source,$sourceParent,$env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial,'C:\Users\Faiz\OneDrive','C:\Users\Faiz\OneDrive - AFZ Engineering Inc','C:\Media')){
  if($p -and (Test-Path -LiteralPath $p -PathType Container) -and -not $candidates.Contains($p)){$candidates.Add($p)}
}
try{
  foreach($d in @(Get-ChildItem -LiteralPath 'C:\Users\Faiz' -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '(?i)OneDrive|Cloud'})){
    if(-not $candidates.Contains($d.FullName)){$candidates.Add($d.FullName)}
  }
}catch{}
Write-Output ('CANDIDATE_ROOT_COUNT='+$candidates.Count)
foreach($p in $candidates){Write-Output ('CANDIDATE_ROOT|path='+$p+'|media_count_capped='+(Get-MediaCountCapped $p 5001))}

$hits=New-Object System.Collections.Generic.List[string]
function Scan-NamedDirs([string]$root,[int]$maxDepth,[int]$maxDirs){
  if(-not(Test-Path -LiteralPath $root -PathType Container)){return}
  $q=New-Object System.Collections.Queue
  $q.Enqueue([pscustomobject]@{Path=$root;Depth=0})
  $seen=0
  while($q.Count -gt 0 -and $seen -lt $maxDirs -and $hits.Count -lt 50){
    $node=$q.Dequeue();$seen++
    $kids=@();try{$kids=@([IO.Directory]::EnumerateDirectories([string]$node.Path))}catch{continue}
    foreach($k in $kids){
      $leaf=[IO.Path]::GetFileName($k)
      if($leaf -match '(?i)^Wedding$|^Home Videos( and Photos)?$'){
        if(-not $hits.Contains($k)){$hits.Add($k)}
      }
      if([int]$node.Depth -lt $maxDepth -and $leaf -notmatch '(?i)^(AppData|Windows|Program Files|Program Files \(x86\)|ProgramData|\$Recycle.Bin|System Volume Information|node_modules|\.git)$'){
        $q.Enqueue([pscustomobject]@{Path=$k;Depth=([int]$node.Depth+1)})
      }
    }
  }
}
Scan-NamedDirs 'C:\Users\Faiz' 5 25000
Scan-NamedDirs 'C:\Media' 5 15000
foreach($drv in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)){
  $root=([string]$drv.DeviceID)+'\'
  if($root -ne 'C:\'){Scan-NamedDirs $root 4 15000}
}
$hits=@($hits|Select-Object -Unique)
Write-Output ('NAMED_HIT_COUNT='+$hits.Count)
foreach($p in $hits){Write-Output ('NAMED_HIT|path='+$p+'|media_count_capped='+(Get-MediaCountCapped $p 10001))}
Write-Output 'FORENSICS_STATUS=PASS'
