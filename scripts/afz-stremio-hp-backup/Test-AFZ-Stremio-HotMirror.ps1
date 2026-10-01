# AFZ Stremio HP hot-mirror verification
param(
  [string]$DestinationRoot='\\192.168.50.185\G\AFZ-Backups\AFZ-Stremio\HotMirror'
)
$ErrorActionPreference='Stop'
$manifestPath=Join-Path $DestinationRoot 'selection-manifest.json'
if(-not(Test-Path -LiteralPath $manifestPath)){throw 'HOTMIRROR_MANIFEST_MISSING'}
$m=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$missing=@()
$movieBytes=[Int64]0
foreach($movie in @($m.selectedMovies)){
  $p=Join-Path (Join-Path $DestinationRoot 'Movies') ([string]$movie.name)
  if(Test-Path -LiteralPath $p){
    $movieBytes += [Int64]((Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
  }else{
    $missing += [string]$movie.name
  }
}
$tvPath=Join-Path $DestinationRoot 'TV'
$tvBytes=if(Test-Path -LiteralPath $tvPath){[Int64]((Get-ChildItem -LiteralPath $tvPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)}else{[Int64]0}
[ordered]@{
  ok=($missing.Count -eq 0 -and $movieBytes -eq [Int64]$m.selectedMovieBytes -and $tvBytes -eq [Int64]$m.tvBytes)
  missing=$missing
  expectedMovieBytes=[Int64]$m.selectedMovieBytes
  actualMovieBytes=$movieBytes
  expectedTVBytes=[Int64]$m.tvBytes
  actualTVBytes=$tvBytes
  checkedUtc=(Get-Date).ToUniversalTime().ToString('o')
}|ConvertTo-Json -Depth 6
