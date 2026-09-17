#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$projectRoot='C:\docker\movie-recommender'
$sourcePath=Join-Path $projectRoot 'stremio_catalog.py'
$composePath=Join-Path $projectRoot 'docker-compose.yml'
if(-not $RequestPath){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\movierecommender-episode-art-local-fix.json'}
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-episode-art-local-fix'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagFile=Join-Path $diagRoot 'AFZ-MovieRecommender-EpisodeArtLocalFix-Latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$mutex=New-Object Threading.Mutex($false,'Global\AFZMovieRecommenderEpisodeArtLocal06164')
$locked=$false
try{$locked=$mutex.WaitOne(0)}catch [System.Threading.AbandonedMutexException]{$locked=$true}
if(-not $locked){exit 0}

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 20 -Compress),$utf8)}
function Publish($Object){try{if(Test-Path -LiteralPath $diagRoot -PathType Container){Write-Json $diagFile $Object}}catch{}}
function Quote-Arg([string]$Arg){if($null -eq $Arg){return '""'};return '"'+$Arg.Replace('\','\\').Replace('"','\"')+'"'}
function Invoke-Native([string]$File,[string[]]$Args,[int]$TimeoutSec=180,[string]$WorkingDirectory=$projectRoot){
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$File;$psi.WorkingDirectory=$WorkingDirectory;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.Arguments=(($Args|ForEach-Object{Quote-Arg ([string]$_)}) -join ' ')
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
  $o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
  if(-not $p.WaitForExit($TimeoutSec*1000)){try{$p.Kill()}catch{};throw "NATIVE_TIMEOUT file=$File timeout=$TimeoutSec"}
  return [pscustomobject]@{Code=[int]$p.ExitCode;Stdout=[string]$o.Result;Stderr=[string]$e.Result}
}
function Invoke-Docker([string[]]$Args,[int]$TimeoutSec=180){Invoke-Native 'docker.exe' $Args $TimeoutSec $projectRoot}
function Http-Json([string]$Uri,[int]$TimeoutSec=10){
  try{$r=Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec $TimeoutSec;if([int]$r.StatusCode -eq 200){return ([string]$r.Content|ConvertFrom-Json)}}catch{};return $null
}
function Get-ResourceGate {
  $os=Get-CimInstance Win32_OperatingSystem
  $ramPct=[math]::Round((1-([double]$os.FreePhysicalMemory/[double]$os.TotalVisibleMemorySize))*100,1)
  $cpu=@(Get-CimInstance Win32_Processor|ForEach-Object{[double]$_.LoadPercentage}|Measure-Object -Average).Average
  return [pscustomobject]@{RamPct=$ramPct;CpuPct=[math]::Round([double]$cpu,1);Allowed=($ramPct -lt 90 -and $cpu -lt 92)}
}
function Replace-ExactlyOnce([string]$Text,[string]$Old,[string]$New,[string]$Label){
  $count=([regex]::Matches($Text,[regex]::Escape($Old))).Count
  if($count -ne 1){throw "ANCHOR_COUNT_$Label=$count"}
  return $Text.Replace($Old,$New)
}
$computer=[Environment]::MachineName
if($computer -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$computer"}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){exit 0}
$req=Read-Json $RequestPath
if(-not $req){throw 'INVALID_REQUEST_JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'movierecommender' -or [string]$req.action -ne 'episode-art-local-fix'){throw 'INVALID_REQUEST'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
if(-not [bool]$req.rollback_on_failure){throw 'ROLLBACK_REQUIRED'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'INVALID_JOB_ID'}
$expectedSha=([string]$req.source_sha256).Trim().ToLowerInvariant()
if($expectedSha -notmatch '^[0-9a-f]{64}$'){throw 'INVALID_SOURCE_SHA256'}
$targetVersion=[string]$req.target_version
if($targetVersion -ne '0.6.164'){throw 'INVALID_TARGET_VERSION'}
$stateFile=Join-Path $stateRoot ($job+'.json')
$prior=Read-Json $stateFile
if($prior -and [string]$prior.status -eq 'completed'){$prior|ConvertTo-Json -Depth 20 -Compress|Write-Output;exit 0}

$started=Get-Date
$gate=Get-ResourceGate
if(-not $gate.Allowed){
  $out=[ordered]@{schema=1;project='movierecommender';job_id=$job;status='deferred';classification='RESOURCE_GATE_DEFERRED';ramPct=$gate.RamPct;cpuPct=$gate.CpuPct;changed=$false;secretExposed=$false;time=(Get-Date -Format o)}
  Write-Json $stateFile $out;Publish $out;$out|ConvertTo-Json -Compress|Write-Output;exit 0
}
if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw 'SOURCE_MISSING'}
if(-not(Test-Path -LiteralPath $composePath -PathType Leaf)){throw 'COMPOSE_MISSING'}
$backupPath="$sourcePath.before-$job.bak"
$sourceSha=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
$text=[IO.File]::ReadAllText($sourcePath)
$alreadyPatched=($text.Contains("APP_VERSION='0.6.164'") -and $text.Contains('AFZ_SERIES_META_EPISODE_ART_V1') -and $text.Contains('/wl.jpg?media=series'))
$knownPatchedLineage=$false
if($alreadyPatched -and (Test-Path -LiteralPath $backupPath -PathType Leaf)){
  try{$knownPatchedLineage=((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedSha)}catch{}
}
if($sourceSha -ne $expectedSha -and -not $knownPatchedLineage){
  $out=[ordered]@{schema=1;project='movierecommender';job_id=$job;status='safe-stop';classification='SOURCE_DRIFT';expectedSourceSha256=$expectedSha;actualSourceSha256=$sourceSha;changed=$false;secretExposed=$false;time=(Get-Date -Format o)}
  Write-Json $stateFile $out;Publish $out;$out|ConvertTo-Json -Compress|Write-Output;exit 0
}
$backupImage="movie-recommender-stremio-catalog:afz-pre-06164-$job"
$sourceChanged=$false;$imageTagged=$false;$rollbackOk=$false
try {
  $dockerVersion=Invoke-Docker @('version','--format','{{.Server.Version}}') 30
  if($dockerVersion.Code -ne 0){throw 'DOCKER_ENGINE_UNAVAILABLE'}
  $currentImage=Invoke-Docker @('inspect','-f','{{.Image}}','afz-stremio-catalog') 30
  if($currentImage.Code -ne 0 -or [string]::IsNullOrWhiteSpace($currentImage.Stdout)){throw 'CURRENT_CONTAINER_IMAGE_UNKNOWN'}
  $imageSha=$currentImage.Stdout.Trim()
  $tag=Invoke-Docker @('image','tag',$imageSha,$backupImage) 30
  if($tag.Code -ne 0){throw 'BACKUP_IMAGE_TAG_FAILED'}
  $imageTagged=$true

  if(-not $alreadyPatched){
    Copy-Item -LiteralPath $sourcePath -Destination $backupPath -Force
    $nl=$(if($text.Contains("`r`n")){"`r`n"}else{"`n"})
    $text=Replace-ExactlyOnce $text "APP_VERSION='0.6.163'" "APP_VERSION='0.6.164'" 'VERSION'
    $oldResource="{'name':'meta','types':['movie'],'idPrefixes':['afzlib']},{'name':'stream','types':['movie','series'],'idPrefixes':['tt','afzlib']}"
    $newResource="{'name':'meta','types':['movie'],'idPrefixes':['afzlib']},{'name':'meta','types':['series'],'idPrefixes':['tt']},{'name':'stream','types':['movie','series'],'idPrefixes':['tt','afzlib']}"
    $text=Replace-ExactlyOnce $text $oldResource $newResource 'SERIES_META_RESOURCE'
    $oldPoster="m['poster']=f'{PUBLIC_BASE}/badge-poster-v3/{tmdb}/w.jpg?media=series'"
    $newPoster="m['poster']=f'{PUBLIC_BASE}/badge-poster-v3/{tmdb}/wl.jpg?media=series'"
    $text=Replace-ExactlyOnce $text $oldPoster $newPoster 'HEYARNOLD_LOCAL_BADGE'
    $seriesBlock=@'
# AFZ_SERIES_META_EPISODE_ART_V1
episode_art_lock=threading.Lock()
episode_art_cache={}
episode_season_cache={}
EPISODE_ART_TTL=max(300,int(os.getenv('STREMIO_EPISODE_ART_TTL','86400')))

def _episode_season_art(imdb,season):
    key=(str(imdb),int(season))
    now=time.time()
    with episode_art_lock:
        hit=dict(episode_season_cache.get(key) or {})
    if hit and now-float(hit.get('ts') or 0)<EPISODE_ART_TTL:
        return dict(hit.get('episodes') or {})
    episodes={}
    try:
        item=resolve_series_item(str(imdb))
        tid=int((item or {}).get('tmdbId') or 0)
        if tid:
            season_obj=sget(f'/tv/{tid}/season/{int(season)}')
            for row in ((season_obj or {}).get('episodes') or []):
                if not isinstance(row,dict):
                    continue
                ep=int(row.get('episodeNumber') or row.get('episode_number') or 0)
                still=str(row.get('stillPath') or row.get('still_path') or '')
                if ep>0 and still:
                    episodes[ep]=('https://image.tmdb.org/t/p/w780'+still) if still.startswith('/') else still
    except Exception:
        episodes={}
    with episode_art_lock:
        episode_season_cache[key]={'episodes':dict(episodes),'ts':now}
    return episodes

def _episode_art_url(imdb,season,episode):
    key=(str(imdb),int(season),int(episode))
    now=time.time()
    with episode_art_lock:
        hit=dict(episode_art_cache.get(key) or {})
    if hit and now-float(hit.get('ts') or 0)<EPISODE_ART_TTL:
        return str(hit.get('url') or '')
    url=str(_episode_season_art(imdb,season).get(int(episode)) or '')
    if not url:
        probe=f'https://episodes.metahub.space/{imdb}/{int(season)}/{int(episode)}/w780.jpg'
        try:
            r=requests.get(probe,timeout=8)
            ctype=str(r.headers.get('content-type') or '').lower()
            if r.status_code==200 and 'image/' in ctype and len(r.content)>1000:
                url=probe
        except Exception:
            pass
    if not url:
        try:
            r=requests.get(f'{CINEMETA}/meta/series/{imdb}.json',timeout=10)
            r.raise_for_status()
            meta=(r.json() or {}).get('meta') or {}
            url=str(meta.get('background') or meta.get('poster') or '')
        except Exception:
            url=''
    with episode_art_lock:
        episode_art_cache[key]={'url':url,'ts':now}
    return url

@app.get('/art/episode/{imdb}/{season}/{episode}.jpg')
def afz_episode_art(imdb:str,season:int,episode:int):
    if not re.fullmatch(r'tt\d+',str(imdb)) or int(season)<0 or int(episode)<1:
        raise HTTPException(404,'Episode artwork unavailable')
    url=_episode_art_url(str(imdb),int(season),int(episode))
    if not url:
        raise HTTPException(404,'Episode artwork unavailable')
    return RedirectResponse(url,status_code=307,headers={'Cache-Control':'public, max-age=21600'})

@app.get('/meta/series/{vid}.json')
def afz_series_meta(vid:str):
    if not re.fullmatch(r'tt\d+',str(vid)):
        return {'meta':None}
    try:
        r=requests.get(f'{CINEMETA}/meta/series/{vid}.json',timeout=15)
        r.raise_for_status()
        meta=dict((r.json() or {}).get('meta') or {})
    except Exception:
        return {'meta':None}
    if not meta:
        return {'meta':None}
    videos=[]
    for src in (meta.get('videos') or []):
        if not isinstance(src,dict):
            continue
        row=dict(src)
        try:
            season=int(row.get('season') or 0)
            episode=int(row.get('episode') or row.get('number') or 0)
        except Exception:
            season=0;episode=0
        if season>=0 and episode>0:
            row['thumbnail']=f'{PUBLIC_BASE}/art/episode/{vid}/{season}/{episode}.jpg'
        videos.append(row)
    meta['videos']=videos
    return {'meta':meta}
'@
    $seriesBlock=$seriesBlock -replace "`r?`n",$nl
    $anchor="@app.get('/meta/movie/{vid}.json')${nl}def jf_meta(vid:str):"
    $text=Replace-ExactlyOnce $text $anchor ($seriesBlock+$nl+$nl+$anchor) 'SERIES_META_INSERT'

    $tempPath=Join-Path $projectRoot 'stremio_catalog.py.afz-v06164-new'
    [IO.File]::WriteAllText($tempPath,$text,$utf8)
    $mount="${projectRoot}:/src:ro"
    $compile=Invoke-Docker @('run','--rm','-v',$mount,'movie-recommender-stremio-catalog:latest','python','-m','py_compile','/src/stremio_catalog.py.afz-v06164-new') 60
    if($compile.Code -ne 0){throw ('PYTHON_COMPILE_FAILED '+$compile.Stderr)}
    Move-Item -LiteralPath $tempPath -Destination $sourcePath -Force
    $sourceChanged=$true
  }

  $build=Invoke-Docker @('compose','build','stremio-catalog') 420
  if($build.Code -ne 0){throw ('STREMIO_BUILD_FAILED '+$build.Stderr)}
  $up=Invoke-Docker @('compose','up','-d','--no-build','stremio-catalog') 120
  if($up.Code -ne 0){throw ('STREMIO_RECREATE_FAILED '+$up.Stderr)}

  $health=$null;$manifest=$null
  $deadline=(Get-Date).AddSeconds(120)
  do {
    Start-Sleep -Seconds 3
    $health=Http-Json 'http://127.0.0.1:18766/health' 8
    $manifest=Http-Json 'http://127.0.0.1:18766/manifest.json' 8
    if($health -and [string]$health.version -eq $targetVersion -and $manifest){break}
  } while((Get-Date) -lt $deadline)
  if(-not $health -or [string]$health.version -ne $targetVersion){throw 'TARGET_HEALTH_VERSION_FAILED'}
  if(-not $manifest){throw 'TARGET_MANIFEST_MISSING'}
  $seriesMeta=@($manifest.resources|Where-Object {$_ -isnot [string] -and [string]$_.name -eq 'meta' -and @($_.types) -contains 'series'})
  if(@($seriesMeta).Count -ne 1){throw 'SERIES_META_RESOURCE_MISSING'}

  $kids=Http-Json 'http://127.0.0.1:18766/catalog/series/kids_series_expanded.json' 20
  $arnold=@(($kids.metas|Where-Object {[string]$_.id -eq 'tt0115200'}))|Select-Object -First 1
  if(-not $arnold){throw 'HEYARNOLD_META_MISSING'}
  if([string]$arnold.poster -notmatch '/537/wl[.]jpg'){throw ('HEYARNOLD_LOCAL_BADGE_FAILED poster='+[string]$arnold.poster)}

  $arthur=Http-Json 'http://127.0.0.1:18766/meta/series/tt0169414.json' 20
  if(-not $arthur -or -not $arthur.meta){throw 'ARTHUR_SERIES_META_FAILED'}
  $ep=@($arthur.meta.videos|Where-Object {[int]$_.season -eq 3 -and [int]$_.episode -eq 2})|Select-Object -First 1
  if(-not $ep -or [string]$ep.thumbnail -notmatch '/art/episode/tt0169414/3/2[.]jpg$'){throw 'ARTHUR_EPISODE_PROXY_FAILED'}
  try {
    $art=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18766/art/episode/tt0169414/3/2.jpg' -TimeoutSec 25
    $ctype=[string]$art.Headers['Content-Type']
    if([int]$art.StatusCode -ne 200 -or $ctype -notmatch '^image/' -or $art.RawContentLength -lt 1000){throw 'bad image response'}
  } catch {throw ('EPISODE_ART_CANARY_FAILED '+$_.Exception.Message)}

  $finalSha=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $out=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='completed';classification='EPISODE_ART_LOCAL_FIX_ACCEPTED'
    changed=$sourceChanged;targetVersion=$targetVersion;sourceSha256=$finalSha;backupPath=$(if($sourceChanged){$backupPath}else{$null})
    priorImageTag=$backupImage;healthPass=$true;manifestSeriesMetaPass=$true;heyArnoldLocalBadgePass=$true;episodeArtPass=$true
    ramPct=$gate.RamPct;cpuPct=$gate.CpuPct;secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $out;Publish $out;$out|ConvertTo-Json -Depth 20 -Compress|Write-Output
  exit 0
} catch {
  $err=$_.Exception.Message
  try {
    if($sourceChanged -and (Test-Path -LiteralPath $backupPath -PathType Leaf)){Copy-Item -LiteralPath $backupPath -Destination $sourcePath -Force}
    if($imageTagged){
      $rt=Invoke-Docker @('image','tag',$backupImage,'movie-recommender-stremio-catalog:latest') 30
      if($rt.Code -eq 0){$ru=Invoke-Docker @('compose','up','-d','--no-build','stremio-catalog') 120;$rollbackOk=($ru.Code -eq 0)}
    }
  } catch {$rollbackOk=$false}
  $out=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='failed';classification='EPISODE_ART_LOCAL_FIX_FAILED'
    changed=$sourceChanged;error=$err;rollbackAttempted=($sourceChanged -or $imageTagged);rollbackOk=$rollbackOk
    backupPath=$(if($sourceChanged){$backupPath}else{$null});priorImageTag=$(if($imageTagged){$backupImage}else{$null})
    ramPct=$gate.RamPct;cpuPct=$gate.CpuPct;secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $out;Publish $out;$out|ConvertTo-Json -Depth 20 -Compress|Write-Output
  exit 1
}
