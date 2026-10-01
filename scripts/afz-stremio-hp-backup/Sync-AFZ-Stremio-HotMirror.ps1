#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$SourceMovies='F:\Media\Movies',
  [string]$SourceTV='F:\Media\TV',
  [string]$DestinationRoot='\\192.168.50.185\G\AFZ-Backups\AFZ-Stremio\HotMirror',
  [Int64]$MovieCapBytes=214748364800
)
$ErrorActionPreference='Stop'

$destMovies=Join-Path $DestinationRoot 'Movies'
$destTV=Join-Path $DestinationRoot 'TV'
$stateRoot='C:\AFZ\Nuvio-Setup-20260923'
$log=Join-Path $stateRoot 'hp-hotmirror-sync-latest.log'
$resultPath=Join-Path $stateRoot 'hp-hotmirror-sync-latest-result.json'
$manifestPath=Join-Path $stateRoot 'hp-hotmirror-selection-latest.json'
$started=(Get-Date).ToUniversalTime()

New-Item -ItemType Directory -Force -Path $destMovies,$destTV | Out-Null
"[$($started.ToString('o'))] START dest=$DestinationRoot movieCapBytes=$MovieCapBytes" |
  Set-Content -LiteralPath $log -Encoding UTF8

$rows=@()
Get-ChildItem -LiteralPath $SourceMovies -Directory | ForEach-Object {
  $files=Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue
  $bytes=[Int64](($files|Measure-Object Length -Sum).Sum)
  $latest=($files|Measure-Object LastWriteTime -Maximum).Maximum
  if($bytes -gt 0){
    $rows += [pscustomobject]@{Name=$_.Name;Path=$_.FullName;Bytes=$bytes;Latest=$latest}
  }
}

$selected=@()
$movieBytes=[Int64]0
foreach($x in ($rows|Sort-Object Latest -Descending)){
  if(($movieBytes+$x.Bytes)-le $MovieCapBytes){
    $selected += $x
    $movieBytes += $x.Bytes
  }
}
$tvFiles=Get-ChildItem -LiteralPath $SourceTV -Recurse -File -ErrorAction SilentlyContinue
$tvBytes=[Int64](($tvFiles|Measure-Object Length -Sum).Sum)

$manifest=[ordered]@{
  schema=1
  createdUtc=$started.ToString('o')
  sourceMovies=$SourceMovies
  sourceTV=$SourceTV
  destination=$DestinationRoot
  movieCapBytes=$MovieCapBytes
  selectedMovieBytes=$movieBytes
  tvBytes=$tvBytes
  totalPlannedBytes=($movieBytes+$tvBytes)
  selectedMovies=@($selected|ForEach-Object{
    [ordered]@{
      name=$_.Name
      path=$_.Path
      bytes=$_.Bytes
      latest=if($_.Latest){$_.Latest.ToString('o')}else{$null}
    }
  })
}
$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $DestinationRoot 'selection-manifest.json') -Force

$failures=@()
function Invoke-AfzRobocopy([string]$Source,[string]$Destination,[string]$Label){
  "[$((Get-Date).ToUniversalTime().ToString('o'))] COPY_START $Label src=$Source dst=$Destination" |
    Add-Content -LiteralPath $log -Encoding UTF8
  $out=& robocopy.exe $Source $Destination /E /Z /R:2 /W:2 /COPY:DAT /DCOPY:DAT /XJ /NP /NFL /NDL 2>&1
  $code=$LASTEXITCODE
  $out | Select-Object -Last 15 | Add-Content -LiteralPath $log -Encoding UTF8
  "[$((Get-Date).ToUniversalTime().ToString('o'))] COPY_END $Label code=$code" |
    Add-Content -LiteralPath $log -Encoding UTF8
  if($code -ge 8){
    $script:failures += [ordered]@{label=$Label;source=$Source;destination=$Destination;exitCode=$code}
  }
}

Invoke-AfzRobocopy $SourceTV $destTV 'TV'
foreach($x in $selected){
  Invoke-AfzRobocopy $x.Path (Join-Path $destMovies $x.Name) ('MOVIE:'+ $x.Name)
}

$finished=(Get-Date).ToUniversalTime()
$result=[ordered]@{
  status=if($failures.Count -eq 0){'completed'}else{'completed-with-errors'}
  startedUtc=$started.ToString('o')
  finishedUtc=$finished.ToString('o')
  durationMinutes=[math]::Round(($finished-$started).TotalMinutes,1)
  selectedMovieCount=$selected.Count
  selectedMovieBytes=$movieBytes
  tvBytes=$tvBytes
  totalPlannedBytes=($movieBytes+$tvBytes)
  destination=$DestinationRoot
  failures=$failures
}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $resultPath -Encoding UTF8
Copy-Item -LiteralPath $resultPath -Destination (Join-Path $DestinationRoot 'last-sync-result.json') -Force
if($failures.Count -gt 0){exit 8}
exit 0
