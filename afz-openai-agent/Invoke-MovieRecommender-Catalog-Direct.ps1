#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit')]
  [string]$Action='audit'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$projectRoot='C:\docker\movie-recommender'
$sourcePath=Join-Path $projectRoot 'stremio_catalog.py'
$stateV2='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-catalog-v2\latest.json'
$stateR3='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-release-results-fix\movierecommender-release-results-fix-20260903-r3.json'

function Http-Json([string]$Uri,[int]$TimeoutSec=30){
  $r=Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec $TimeoutSec
  if([int]$r.StatusCode -ne 200){throw "HTTP_STATUS uri=$Uri status=$([int]$r.StatusCode)"}
  return ([string]$r.Content | ConvertFrom-Json)
}
function Read-JsonFile([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Has-Prop($Object,[string]$Name){
  return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}
function Parse-Date([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){return $null}
  $d=[datetime]::MinValue
  if([datetime]::TryParse($Value,[ref]$d)){return $d.Date}
  return $null
}

$main=Http-Json 'http://127.0.0.1:8765/health' 15
$side=Http-Json 'http://127.0.0.1:18766/health' 15
$manifest=Http-Json 'http://127.0.0.1:18766/manifest.json' 15
$today=(Get-Date).Date
$cutoff=$today.AddDays(-180)

$catalogs=[ordered]@{}
foreach($c in @($manifest.catalogs)){
  $id=[string]$c.id
  $type=[string]$c.type
  if(-not $id -or -not $type){continue}
  $url='http://127.0.0.1:18766/catalog/'+[Uri]::EscapeDataString($type)+'/'+[Uri]::EscapeDataString($id)+'.json'
  $data=Http-Json $url 240
  $metas=@()
  if(Has-Prop $data 'metas'){$metas=@($data.metas)}
  $ids=@($metas | ForEach-Object {[string]$_.id} | Where-Object {$_})
  $dupCount=($ids.Count - @($ids | Sort-Object -Unique).Count)
  $dates=@()
  foreach($m in $metas){
    $d=Parse-Date ([string]$m.releaseInfo)
    if($d){$dates+=$d}
  }
  $sorted=$true
  for($i=1;$i -lt $dates.Count;$i++){
    if($dates[$i] -gt $dates[$i-1]){$sorted=$false;break}
  }
  $outside=@($dates | Where-Object {$_ -lt $cutoff -or $_ -gt $today})
  $catalogs[$id]=[ordered]@{
    name=[string]$c.name
    count=$metas.Count
    duplicateIds=$dupCount
    datedItems=$dates.Count
    newest=$(if($dates.Count){($dates|Sort-Object -Descending|Select-Object -First 1).ToString('yyyy-MM-dd')}else{$null})
    oldest=$(if($dates.Count){($dates|Sort-Object|Select-Object -First 1).ToString('yyyy-MM-dd')}else{$null})
    sortedNewestToOldest=$sorted
    outside180DayDateWindow=$outside.Count
    outsideDates=@($outside|Sort-Object|ForEach-Object{$_.ToString('yyyy-MM-dd')}|Select-Object -First 10)
  }
}

$srcHash=$null
$srcVersionV2=$false
$srcHindi=$false
$srcR3=$false
if(Test-Path -LiteralPath $sourcePath -PathType Leaf){
  $srcHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $src=[IO.File]::ReadAllText($sourcePath)
  $srcVersionV2=($src -match "APP_VERSION='0\.2\.0'")
  $srcHindi=($src -match "hindi_bollywood")
  $srcR3=($src -match 'AFZ_RELEASE_RESULTS_NORMALIZATION_V1')
}

$v2=Read-JsonFile $stateV2
$r3=Read-JsonFile $stateR3
$result=[ordered]@{
  ok=([bool]$main.ok -and [bool]$side.ok -and [string]$manifest.id -eq 'com.afzengineering.releasecatalog')
  action='audit'
  host=$env:COMPUTERNAME
  mode='read-only'
  mainHealth=[ordered]@{ok=[bool]$main.ok;version=[string]$main.version}
  sidecarHealth=[ordered]@{ok=[bool]$side.ok;version=[string]$side.version;cacheAgeSeconds=$(if(Has-Prop $side 'cacheAgeSeconds'){$side.cacheAgeSeconds}else{$null})}
  manifest=[ordered]@{
    id=[string]$manifest.id
    version=[string]$manifest.version
    catalogIds=@($manifest.catalogs|ForEach-Object{[string]$_.id})
    catalogNames=@($manifest.catalogs|ForEach-Object{[string]$_.name})
  }
  source=[ordered]@{
    path=$sourcePath
    sha256=$srcHash
    r3Marker=$srcR3
    v2Version=$srcVersionV2
    hindiCatalogSource=$srcHindi
  }
  catalogWindow=[ordered]@{today=$today.ToString('yyyy-MM-dd');cutoff=$cutoff.ToString('yyyy-MM-dd')}
  catalogs=$catalogs
  v2State=$v2
  r3State=$r3
  secretValuesLogged=$false
  timestamp=(Get-Date -Format o)
}
$result|ConvertTo-Json -Depth 30 -Compress
