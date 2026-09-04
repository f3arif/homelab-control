#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$SyncedSha=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$projectRoot='C:\docker\movie-recommender'
$sourcePath=Join-Path $projectRoot 'stremio_catalog.py'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\movierecommender-catalog-v2-github.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-catalog-v2-github'
$resultBranch='windows-main-results'
$resultRepo='f3arif/homelab-control'
$resultRepoPath='afz-openai-agent/results/movierecommender-catalog-v2-latest.json'
$backupMirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$backupMirrorPath=Join-Path $backupMirrorRoot 'AFZ-MovieRecommender-CatalogV2-GitHub-Latest.json'
$acceptedR3Hash='29a0fcbd36fd6964fbebd88cc99e7e3de26b48185d0a8fc032ca7d9f58fe821f'
$utf8=New-Object Text.UTF8Encoding($false)
$nl=[Environment]::NewLine
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8)
}
function Quote-NativeArg([string]$Value){
  if($null -eq $Value){return '""'}
  if($Value -notmatch '[\s"]'){return $Value}
  return '"'+($Value.Replace('"','\"'))+'"'
}
function Invoke-Native([string]$File,[string[]]$ArgumentList,[int]$TimeoutSec=120,[string]$WorkingDirectory=$projectRoot){
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$File
  $psi.WorkingDirectory=$WorkingDirectory
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.Arguments=(($ArgumentList|ForEach-Object{Quote-NativeArg ([string]$_)}) -join ' ')
  if([string]::IsNullOrWhiteSpace($psi.Arguments)){throw "EMPTY_ARGUMENT_LIST file=$File"}
  $p=New-Object Diagnostics.Process
  $p.StartInfo=$psi
  [void]$p.Start()
  $stdoutTask=$p.StandardOutput.ReadToEndAsync()
  $stderrTask=$p.StandardError.ReadToEndAsync()
  if(-not $p.WaitForExit($TimeoutSec*1000)){
    try{$p.Kill()}catch{}
    throw "NATIVE_TIMEOUT file=$File timeout=$TimeoutSec"
  }
  return [pscustomobject]@{Code=[int]$p.ExitCode;Stdout=[string]$stdoutTask.Result;Stderr=[string]$stderrTask.Result}
}
function Invoke-Docker([string[]]$ArgumentList,[int]$TimeoutSec=120){
  return Invoke-Native -File 'docker.exe' -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec -WorkingDirectory $projectRoot
}
function Http-Json([string]$Uri,[int]$TimeoutSec=30){
  $r=Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec $TimeoutSec
  if([int]$r.StatusCode -ne 200){throw "HTTP_STATUS uri=$Uri status=$([int]$r.StatusCode)"}
  return ([string]$r.Content|ConvertFrom-Json)
}
function Has-Prop($Object,[string]$Name){
  return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}
function Replace-One([string]$Text,[string]$Pattern,[string]$Replacement,[string]$Label){
  $m=[regex]::Matches($Text,$Pattern)
  if($m.Count -ne 1){throw "PATCH_SHAPE_MISMATCH label=$Label matches=$($m.Count)"}
  return [regex]::Replace($Text,$Pattern,$Replacement,1)
}
function Find-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){
    if($c.Source){return [string]$c.Source}
    if($c.Path){return [string]$c.Path}
  }
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){
    if(Test-Path -LiteralPath $p -PathType Leaf){return $p}
  }
  return $null
}
function Try-PublishGithub($Object){
  try{
    $gh=Find-Gh
    if(-not $gh){return [ordered]@{ok=$false;status='gh-missing'}}
    $perm=Invoke-Native -File $gh -ArgumentList @('api',("repos/"+$resultRepo),'--jq','.permissions.push') -TimeoutSec 30 -WorkingDirectory $projectRoot
    if($perm.Code -ne 0 -or $perm.Stdout.Trim().ToLowerInvariant() -ne 'true'){
      return [ordered]@{ok=$false;status='gh-auth-or-permission-unavailable';exit=$perm.Code}
    }
    $json=$Object|ConvertTo-Json -Depth 30 -Compress
    $payload=[ordered]@{
      message='windows-main MovieRecommender catalog v2 result'
      content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
      branch=$resultBranch
    }
    $getUrl="repos/"+$resultRepo+"/contents/"+$resultRepoPath+"?ref="+$resultBranch
    $get=Invoke-Native -File $gh -ArgumentList @('api',$getUrl,'--jq','.sha') -TimeoutSec 30 -WorkingDirectory $projectRoot
    if($get.Code -eq 0 -and $get.Stdout.Trim() -match '^[0-9a-f]{40}$'){$payload.sha=$get.Stdout.Trim()}
    $tmp=Join-Path $env:TEMP ('afz-movie-github-put-'+[guid]::NewGuid().ToString('N')+'.json')
    try{
      [IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Compress),$utf8)
      $putUrl="repos/"+$resultRepo+"/contents/"+$resultRepoPath
      $put=Invoke-Native -File $gh -ArgumentList @('api',$putUrl,'--method','PUT','--input',$tmp) -TimeoutSec 60 -WorkingDirectory $projectRoot
      if($put.Code -ne 0){return [ordered]@{ok=$false;status='contents-put-failed';exit=$put.Code}}
      return [ordered]@{ok=$true;status='published';branch=$resultBranch;path=$resultRepoPath}
    }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  }catch{return [ordered]@{ok=$false;status='publisher-exception';error=$_.Exception.Message}}
}
function Write-BackupMirror($Object){
  try{
    if(Test-Path -LiteralPath $backupMirrorRoot -PathType Container){
      [IO.File]::WriteAllText($backupMirrorPath,($Object|ConvertTo-Json -Depth 30 -Compress),$utf8)
      return $true
    }
  }catch{}
  return $false
}
function Wait-Sidecar([int]$Seconds=90){
  $deadline=(Get-Date).AddSeconds($Seconds)
  while((Get-Date) -lt $deadline){
    try{
      $h=Http-Json 'http://127.0.0.1:18766/health' 8
      if($h -and [bool]$h.ok){return $true}
    }catch{}
    Start-Sleep -Seconds 2
  }
  return $false
}
function Validate-Live([bool]$RequireV2){
  $main=Http-Json 'http://127.0.0.1:8765/health' 15
  $side=Http-Json 'http://127.0.0.1:18766/health' 15
  $manifest=Http-Json 'http://127.0.0.1:18766/manifest.json' 15
  if(-not [bool]$main.ok){throw 'MAIN_MOVIE_BRAIN_UNHEALTHY'}
  if(-not [bool]$side.ok){throw 'SIDECAR_UNHEALTHY'}
  if([string]$manifest.id -ne 'com.afzengineering.releasecatalog'){throw 'MANIFEST_ID_MISMATCH'}
  if($RequireV2 -and [string]$manifest.version -ne '0.2.0'){throw "MANIFEST_VERSION_MISMATCH actual=$([string]$manifest.version)"}
  if($RequireV2){
    $expected=@('new_digital','action_thriller','scifi_fantasy','bluray_4k','hindi_bollywood')
  }else{
    $expected=@('new_digital','action_thriller','scifi_fantasy','bluray_4k')
  }
  $defs=@($manifest.catalogs)
  $ids=@($defs|ForEach-Object{[string]$_.id})
  foreach($id in $expected){if($ids -notcontains $id){throw "MANIFEST_CATALOG_MISSING id=$id"}}
  if($RequireV2){
    foreach($d in $defs){
      $name=[string]$d.name
      if($name -notmatch '^[\x20-\x7E]+$'){throw "MANIFEST_NAME_NON_ASCII id=$([string]$d.id)"}
    }
  }
  $today=(Get-Date).Date
  $cutoff=$today.AddDays(-180)
  $metrics=[ordered]@{}
  foreach($id in $expected){
    $uri='http://127.0.0.1:18766/catalog/movie/'+[Uri]::EscapeDataString($id)+'.json'
    $data=Http-Json $uri 260
    if(-not(Has-Prop $data 'metas')){throw "CATALOG_METAS_MISSING id=$id"}
    $metas=@($data.metas)
    if($RequireV2 -and $metas.Count -lt 1){throw "CATALOG_EMPTY id=$id"}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]'
    $dup=0
    $dates=New-Object 'System.Collections.Generic.List[datetime]'
    foreach($m in $metas){
      $mid=[string]$m.id
      if($mid -and -not $seen.Add($mid)){$dup++}
      $rv=[string]$m.releaseInfo
      $dt=[datetime]::MinValue
      if($rv -and [datetime]::TryParse($rv,[ref]$dt)){[void]$dates.Add($dt.Date)}
    }
    if($RequireV2 -and $dup -gt 0){throw "CATALOG_DUPLICATE_IDS id=$id count=$dup"}
    $outside=0
    foreach($d in $dates){if($d -lt $cutoff -or $d -gt $today){$outside++}}
    if($RequireV2 -and $outside -gt 0){throw "CATALOG_OUTSIDE_WINDOW id=$id count=$outside"}
    $sorted=$true
    for($i=1;$i -lt $dates.Count;$i++){if($dates[$i] -gt $dates[$i-1]){$sorted=$false;break}}
    if($RequireV2 -and -not $sorted){throw "CATALOG_NOT_NEWEST_FIRST id=$id"}
    $newest=$null
    $oldest=$null
    if($dates.Count -gt 0){
      $newest=($dates|Sort-Object -Descending|Select-Object -First 1).ToString('yyyy-MM-dd')
      $oldest=($dates|Sort-Object|Select-Object -First 1).ToString('yyyy-MM-dd')
    }
    $metrics[$id]=[ordered]@{
      count=$metas.Count
      duplicates=$dup
      dated=$dates.Count
      sortedNewestToOldest=$sorted
      outside180DayDateWindow=$outside
      newest=$newest
      oldest=$oldest
    }
  }
  return [ordered]@{
    mainHealth=$true
    sidecarHealth=$true
    manifestVersion=[string]$manifest.version
    manifestIds=$ids
    catalogWindow=[ordered]@{today=$today.ToString('yyyy-MM-dd');cutoff=$cutoff.ToString('yyyy-MM-dd')}
    catalogs=$metrics
  }
}

if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if($SyncedSha -and $SyncedSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'INVALID_SYNCED_SHA'}
$req=Read-Json $requestPath
if(-not $req){exit 0}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'movierecommender' -or [string]$req.action -ne 'catalog-v2-github'){throw 'INVALID_REQUEST'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'INVALID_JOB_ID'}
$stateFile=Join-Path $stateRoot ($job+'.json')
$prior=Read-Json $stateFile
if($prior -and [string]$prior.status -in @('completed','failed')){
  [void](Try-PublishGithub $prior)
  exit 0
}

$started=Get-Date
$backup=$null
$changed=$false
$rollbackAttempted=$false
$rollbackSucceeded=$false
$beforeHash=$null
$afterHash=$null
$result=$null

try{
  [void](Validate-Live $false)
  if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw 'SOURCE_MISSING'}
  $beforeHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if($beforeHash -ne $acceptedR3Hash){throw "SOURCE_HASH_UNEXPECTED actual=$beforeHash expected=$acceptedR3Hash"}
  $backup=Join-Path $projectRoot ('stremio_catalog.py.before-catalog-v2-github-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')
  Copy-Item -LiteralPath $sourcePath -Destination $backup -Force
  $text=[IO.File]::ReadAllText($sourcePath)

  $text=Replace-One $text "APP_VERSION='0\.1\.0'" "APP_VERSION='0.2.0'" 'app-version'

  $catalogLines=@(
    'CATALOGS={',
    " 'new_digital': {'name':'New Digital Releases','kind':'digital'},",
    " 'action_thriller': {'name':'New Action / Thriller','kind':'digital','genres':{28,53,80}},",
    " 'scifi_fantasy': {'name':'New Sci-Fi / Fantasy','kind':'digital','genres':{878,14}},",
    " 'bluray_4k': {'name':'New Blu-ray / 4K','kind':'physical'},",
    " 'hindi_bollywood': {'name':'New Hindi / Bollywood','kind':'digital','language':'hi'},",
    '}'
  )
  $catalogBlock=($catalogLines -join $nl)+$nl+$nl+'cache='
  $text=Replace-One $text '(?s)CATALOGS=\{.*?\}\r?\n\r?\ncache=' $catalogBlock 'catalog-block'

  $dateReplacement="    today=datetime.now(timezone.utc).date()"+$nl+"    cutoff=today-timedelta(days=DAYS)"
  $text=Replace-One $text '(?m)^    today=datetime\.now\(timezone\.utc\)\r?\n    cutoff=today-timedelta\(days=DAYS\)$' $dateReplacement 'choose-release-date-window'

  $eligReplacement="        dt=parse_dt(x.get('date'))"+$nl+"        if not dt: continue"+$nl+"        day=dt.date()"+$nl+"        if day>today or day<cutoff: continue"
  $text=Replace-One $text "(?m)^        dt=parse_dt\(x\.get\('date'\)\)\r?\n        if not dt or dt>today or dt<cutoff: continue$" $eligReplacement 'choose-release-eligibility'

  $hindiLines=@(
    '    start=(datetime.now(timezone.utc)-timedelta(days=540)).date().isoformat()',
    '    end=datetime.now(timezone.utc).date().isoformat()',
    '    # AFZ_HINDI_TARGETED_DISCOVERY_V1',
    '    for p in range(1,min(6,MAX_PAGES)+1):',
    '        try:',
    "            obj=sget('/discover/movies',{",
    "                'page':p,'language':'en','originalLanguage':'hi',",
    "                'primaryReleaseDateGte':start,'primaryReleaseDateLte':end,",
    "                'sortBy':'primaryReleaseDate.desc'",
    '            })',
    '            for x in movie_results(obj):',
    "                tid=x.get('id') or x.get('tmdbId')",
    '                if tid: pool[int(tid)]=x',
    '        except Exception: pass'
  )
  $hindiReplacement=$hindiLines -join $nl
  $text=Replace-One $text '(?m)^    start=\(datetime\.now\(timezone\.utc\)-timedelta\(days=540\)\)\.date\(\)\.isoformat\(\)\r?\n    end=datetime\.now\(timezone\.utc\)\.date\(\)\.isoformat\(\)$' $hindiReplacement 'hindi-targeted-discovery'

  $gidsLine="        gids={int(x.get('id')) for x in (d.get('genres') or []) if isinstance(x,dict) and x.get('id') is not None}"
  $gidsReplacement=$gidsLine+$nl+"        olang=(d.get('originalLanguage') or d.get('original_language') or '').lower()"
  $text=Replace-One $text ([regex]::Escape($gidsLine)) $gidsReplacement 'original-language'

  $digitalLine="                cats['new_digital'].append((dr['dt'],m))"
  $digitalReplacement=$digitalLine+$nl+"                if olang=='hi': cats['hindi_bollywood'].append((dr['dt'],m))"
  $text=Replace-One $text ([regex]::Escape($digitalLine)) $digitalReplacement 'hindi-catalog-append'

  $blurayOld="                cats['bluray_4k'].append(((premium,pr['dt']),m))"
  $blurayNew="                cats['bluray_4k'].append((pr['dt'],m))"
  $text=Replace-One $text ([regex]::Escape($blurayOld)) $blurayNew 'bluray-date-sort'

  $descOld='Read-only new digital, genre, Blu-ray and 4K movie catalogs from the existing AFZ media metadata stack.'
  $descNew='Read-only new digital, genre, Hindi/Bollywood, Blu-ray and 4K movie catalogs from the existing AFZ media metadata stack.'
  if($text.Contains($descOld)){$text=$text.Replace($descOld,$descNew)}

  [IO.File]::WriteAllText($sourcePath,$text,$utf8)
  $changed=$true
  $afterHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()

  $build=Invoke-Docker @('compose','build','--pull=false','stremio-catalog') 300
  if($build.Code -ne 0){throw "SIDECAR_BUILD_FAILED exit=$($build.Code)"}
  $up=Invoke-Docker @('compose','up','-d','--no-deps','--force-recreate','--pull','never','stremio-catalog') 180
  if($up.Code -ne 0){throw "SIDECAR_UP_FAILED exit=$($up.Code)"}
  if(-not(Wait-Sidecar 120)){throw 'SIDECAR_HEALTH_TIMEOUT'}

  $live=Validate-Live $true
  if([int]$live.catalogs['hindi_bollywood'].count -lt 1){throw 'HINDI_CATALOG_EMPTY'}

  $result=[ordered]@{
    schema=1
    project='movierecommender'
    job_id=$job
    status='completed'
    classification='CATALOG_V2_GITHUB_ACCEPTED'
    transport='github-pull-fast-signal'
    syncedSha=$SyncedSha
    host=$env:COMPUTERNAME
    sourceHashBefore=$beforeHash
    sourceHashAfter=$afterHash
    backup=$backup
    changed=$changed
    rollbackAttempted=$false
    rollbackSucceeded=$false
    live=$live
    secretExposed=$false
    startedAt=$started.ToString('o')
    finishedAt=(Get-Date -Format o)
  }
}catch{
  $err=$_.Exception.Message
  if($changed -and $backup -and (Test-Path -LiteralPath $backup -PathType Leaf)){
    $rollbackAttempted=$true
    try{
      Copy-Item -LiteralPath $backup -Destination $sourcePath -Force
      $rbHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
      $rbBuild=Invoke-Docker @('compose','build','--pull=false','stremio-catalog') 300
      $rbUp=Invoke-Docker @('compose','up','-d','--no-deps','--force-recreate','--pull','never','stremio-catalog') 180
      $rbHealth=Wait-Sidecar 120
      $rbMain=$false
      try{$rbMain=[bool](Http-Json 'http://127.0.0.1:8765/health' 15).ok}catch{}
      $rollbackSucceeded=($rbHash -eq $acceptedR3Hash -and $rbBuild.Code -eq 0 -and $rbUp.Code -eq 0 -and $rbHealth -and $rbMain)
    }catch{$rollbackSucceeded=$false}
  }
  $currentHash=$null
  try{$currentHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()}catch{}
  $result=[ordered]@{
    schema=1
    project='movierecommender'
    job_id=$job
    status='failed'
    classification='CATALOG_V2_GITHUB_FAILED'
    transport='github-pull-fast-signal'
    syncedSha=$SyncedSha
    host=$env:COMPUTERNAME
    sourceHashBefore=$beforeHash
    sourceHashAfter=$afterHash
    sourceHashCurrent=$currentHash
    backup=$backup
    changed=$changed
    error=$err
    rollbackAttempted=$rollbackAttempted
    rollbackSucceeded=$rollbackSucceeded
    secretExposed=$false
    startedAt=$started.ToString('o')
    finishedAt=(Get-Date -Format o)
  }
}

Write-Json $stateFile $result
$result['githubPublish']=Try-PublishGithub $result
$result['oneDriveBackupWritten']=Write-BackupMirror $result
Write-Json $stateFile $result
$result|ConvertTo-Json -Depth 30 -Compress|Write-Output
if([string]$result.status -ne 'completed'){exit 1}
