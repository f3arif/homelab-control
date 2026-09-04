#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$projectRoot='C:\docker\movie-recommender'
$sourcePath=Join-Path $projectRoot 'stremio_catalog.py'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\movierecommender-release-results-fix.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-release-results-fix'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagFile=Join-Path $diagRoot 'AFZ-MovieRecommender-Catalog-Fix-Latest.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 20 -Compress),$utf8)
}
function Quote-NativeArg([string]$Arg){
  if($null -eq $Arg){return '""'}
  return '"' + $Arg.Replace('\','\\').Replace('"','\"') + '"'
}
function Invoke-Native([string]$File,[string[]]$ArgumentList,[int]$TimeoutSec=120,[string]$WorkingDirectory=$projectRoot){
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$File
  $psi.WorkingDirectory=$WorkingDirectory
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.Arguments=(($ArgumentList | ForEach-Object { Quote-NativeArg ([string]$_) }) -join ' ')
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
  $r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec
  if([int]$r.StatusCode -ne 200){throw "HTTP_STATUS uri=$Uri status=$([int]$r.StatusCode)"}
  return ([string]$r.Content | ConvertFrom-Json)
}
function Write-Diag($Object){
  if(Test-Path -LiteralPath $diagRoot -PathType Container){
    [IO.File]::WriteAllText($diagFile,($Object | ConvertTo-Json -Depth 20),$utf8)
  }
}

if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'INVALID_REQUEST_JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'movierecommender' -or [string]$req.action -ne 'fix-release-results-normalization'){throw 'INVALID_REQUEST'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
if([int]$req.host_port -ne 18766 -or [int]$req.container_port -ne 8766){throw 'INVALID_PORT_CONTRACT'}
if([bool]$req.allow_global_docker_config_change){throw 'GLOBAL_DOCKER_CONFIG_CHANGE_FORBIDDEN'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'INVALID_JOB_ID'}
$stateFile=Join-Path $stateRoot ($job+'.json')
$prior=Read-Json $stateFile
if($prior -and [string]$prior.status -in @('completed','failed')){exit 0}

$started=Get-Date
$backup=$null
$changed=$false
$rollbackAttempted=$false
$rollbackSucceeded=$false
$tempConfig=$null
$oldDockerConfig=$env:DOCKER_CONFIG
$oldDockerHost=$env:DOCKER_HOST
$dockerEnvPrepared=$false
$beforeHash=$null
$afterHash=$null

try{
  if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw 'SOURCE_MISSING'}
  $beforeHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $text=[IO.File]::ReadAllText($sourcePath)
  $marker='# AFZ_RELEASE_RESULTS_NORMALIZATION_V1'
  if($text -notmatch [regex]::Escape($marker)){
    $pattern="(?m)(def region_releases\(detail, typ\):\r?\n    rels=detail\.get\('releases'\) or \[\]\r?\n)"
    $matches=[regex]::Matches($text,$pattern)
    if($matches.Count -ne 1){throw "SOURCE_SHAPE_MISMATCH matches=$($matches.Count)"}
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup=Join-Path $projectRoot ("stremio_catalog.py.before-release-results-fix-"+$stamp+".bak")
    Copy-Item -LiteralPath $sourcePath -Destination $backup -Force
    $nl=[Environment]::NewLine
    $insert='$1'+"    $marker"+$nl+"    if isinstance(rels,dict):"+$nl+"        nested=rels.get('results')"+$nl+"        rels=nested if isinstance(nested,list) else []"+$nl+"    if not isinstance(rels,list): rels=[]"+$nl
    $text=[regex]::Replace($text,$pattern,$insert,1)
    [IO.File]::WriteAllText($sourcePath,$text,$utf8)
    $changed=$true
  }
  $afterHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()

  # Keep the installed Docker CLI/Compose plugin configuration intact. No pulls are allowed.
  $dockerEnvPrepared=$true
  $ver=Invoke-Docker @('version','--format','{{.Server.Version}}') 30
  if($ver.Code -ne 0){throw "DOCKER_ENGINE_UNAVAILABLE exit=$($ver.Code)"}
  $cfg=Invoke-Docker @('compose','config','--services') 30
  if($cfg.Code -ne 0 -or $cfg.Stdout -notmatch '(?m)^stremio-catalog\s*

  $build=Invoke-Docker @('compose','build','--pull=false','stremio-catalog') 300
  if($build.Code -ne 0){throw "SIDECAR_BUILD_FAILED exit=$($build.Code)"}
  $up=Invoke-Docker @('compose','up','-d','--no-deps','--force-recreate','--pull','never','stremio-catalog') 180
  if($up.Code -ne 0){throw "SIDECAR_UP_FAILED exit=$($up.Code)"}

  $health=$null
  for($i=0;$i -lt 30;$i++){
    Start-Sleep -Seconds 2
    try{
      $health=Http-Json 'http://127.0.0.1:18766/health' 10
      if($health -and [bool]$health.ok){break}
    }catch{}
  }
  if(-not $health -or -not [bool]$health.ok){throw 'HEALTH_ACCEPTANCE_FAILED'}

  $manifest=Http-Json 'http://127.0.0.1:18766/manifest.json' 15
  if([string]$manifest.id -ne 'com.afzengineering.releasecatalog'){throw 'MANIFEST_ID_MISMATCH'}
  $catalogDefs=@($manifest.catalogs)
  if($catalogDefs.Count -lt 4){throw "MANIFEST_CATALOG_COUNT_LOW count=$($catalogDefs.Count)"}

  $counts=[ordered]@{}
  foreach($c in $catalogDefs){
    $cid=[string]$c.id
    $type=[string]$c.type
    if(-not $cid -or -not $type){throw 'INVALID_CATALOG_DEFINITION'}
    $url='http://127.0.0.1:18766/catalog/'+[Uri]::EscapeDataString($type)+'/'+[Uri]::EscapeDataString($cid)+'.json'
    $data=Http-Json $url 240
    if(-not ($data.PSObject.Properties.Name -contains 'metas')){throw "CATALOG_METAS_MISSING id=$cid"}
    $counts[$cid]=@($data.metas).Count
  }
  if(-not $counts.Contains('new_digital')){throw 'NEW_DIGITAL_CATALOG_MISSING'}
  if([int]$counts['new_digital'] -lt 1){throw 'NEW_DIGITAL_STILL_EMPTY'}

  $result=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='completed'
    classification='RELEASE_RESULTS_NORMALIZATION_ACCEPTED'
    host=$env:COMPUTERNAME;changed=$changed;backup=$backup
    sourceHashBefore=$beforeHash;sourceHashAfter=$afterHash
    hostPort=18766;containerPort=8766
    healthPass=$true;manifestPass=$true;catalogCounts=$counts
    rollbackAttempted=$false;secretExposed=$false
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $result
  Write-Diag $result
  $result | ConvertTo-Json -Compress -Depth 20 | Write-Output
  exit 0
}catch{
  $err=$_.Exception.Message
  if($changed -and $backup -and (Test-Path -LiteralPath $backup -PathType Leaf)){
    $rollbackAttempted=$true
    try{
      Copy-Item -LiteralPath $backup -Destination $sourcePath -Force
      if($dockerEnvPrepared){
        $rbBuild=Invoke-Docker @('compose','build','--pull=false','stremio-catalog') 300
        $rbUp=Invoke-Docker @('compose','up','-d','--no-deps','--force-recreate','--pull','never','stremio-catalog') 180
        $rollbackSucceeded=($rbBuild.Code -eq 0 -and $rbUp.Code -eq 0)
      }else{$rollbackSucceeded=$true}
    }catch{$rollbackSucceeded=$false}
  }
  $result=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='failed'
    classification='RELEASE_RESULTS_NORMALIZATION_FAILED'
    host=$env:COMPUTERNAME;changed=$changed;backup=$backup
    sourceHashBefore=$beforeHash;sourceHashAfter=$afterHash;error=$err
    rollbackAttempted=$rollbackAttempted;rollbackSucceeded=$rollbackSucceeded
    secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $result
  Write-Diag $result
  $result | ConvertTo-Json -Compress -Depth 20 | Write-Output
  exit 1
}finally{
  if($null -eq $oldDockerConfig){Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue}else{$env:DOCKER_CONFIG=$oldDockerConfig}
  if($null -eq $oldDockerHost){Remove-Item Env:DOCKER_HOST -ErrorAction SilentlyContinue}else{$env:DOCKER_HOST=$oldDockerHost}
  if($tempConfig -and (Test-Path -LiteralPath $tempConfig -PathType Container)){Remove-Item -LiteralPath $tempConfig -Recurse -Force -ErrorAction SilentlyContinue}
}
){
    $cfgOut=($cfg.Stdout -replace '\r?\n','; ').Trim()
    $cfgErr=($cfg.Stderr -replace '\r?\n','; ').Trim()
    throw "COMPOSE_SIDECAR_MISSING exit=$($cfg.Code) stdout=$cfgOut stderr=$cfgErr"
  }

  $build=Invoke-Docker @('compose','build','--pull=false','stremio-catalog') 300
  if($build.Code -ne 0){throw "SIDECAR_BUILD_FAILED exit=$($build.Code)"}
  $up=Invoke-Docker @('compose','up','-d','--no-deps','--force-recreate','--pull','never','stremio-catalog') 180
  if($up.Code -ne 0){throw "SIDECAR_UP_FAILED exit=$($up.Code)"}

  $health=$null
  for($i=0;$i -lt 30;$i++){
    Start-Sleep -Seconds 2
    try{
      $health=Http-Json 'http://127.0.0.1:18766/health' 10
      if($health -and [bool]$health.ok){break}
    }catch{}
  }
  if(-not $health -or -not [bool]$health.ok){throw 'HEALTH_ACCEPTANCE_FAILED'}

  $manifest=Http-Json 'http://127.0.0.1:18766/manifest.json' 15
  if([string]$manifest.id -ne 'com.afzengineering.releasecatalog'){throw 'MANIFEST_ID_MISMATCH'}
  $catalogDefs=@($manifest.catalogs)
  if($catalogDefs.Count -lt 4){throw "MANIFEST_CATALOG_COUNT_LOW count=$($catalogDefs.Count)"}

  $counts=[ordered]@{}
  foreach($c in $catalogDefs){
    $cid=[string]$c.id
    $type=[string]$c.type
    if(-not $cid -or -not $type){throw 'INVALID_CATALOG_DEFINITION'}
    $url='http://127.0.0.1:18766/catalog/'+[Uri]::EscapeDataString($type)+'/'+[Uri]::EscapeDataString($cid)+'.json'
    $data=Http-Json $url 240
    if(-not ($data.PSObject.Properties.Name -contains 'metas')){throw "CATALOG_METAS_MISSING id=$cid"}
    $counts[$cid]=@($data.metas).Count
  }
  if(-not $counts.Contains('new_digital')){throw 'NEW_DIGITAL_CATALOG_MISSING'}
  if([int]$counts['new_digital'] -lt 1){throw 'NEW_DIGITAL_STILL_EMPTY'}

  $result=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='completed'
    classification='RELEASE_RESULTS_NORMALIZATION_ACCEPTED'
    host=$env:COMPUTERNAME;changed=$changed;backup=$backup
    sourceHashBefore=$beforeHash;sourceHashAfter=$afterHash
    hostPort=18766;containerPort=8766
    healthPass=$true;manifestPass=$true;catalogCounts=$counts
    rollbackAttempted=$false;secretExposed=$false
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $result
  Write-Diag $result
  $result | ConvertTo-Json -Compress -Depth 20 | Write-Output
  exit 0
}catch{
  $err=$_.Exception.Message
  if($changed -and $backup -and (Test-Path -LiteralPath $backup -PathType Leaf)){
    $rollbackAttempted=$true
    try{
      Copy-Item -LiteralPath $backup -Destination $sourcePath -Force
      if($dockerEnvPrepared){
        $rbBuild=Invoke-Docker @('compose','build','--pull=false','stremio-catalog') 300
        $rbUp=Invoke-Docker @('compose','up','-d','--no-deps','--force-recreate','--pull','never','stremio-catalog') 180
        $rollbackSucceeded=($rbBuild.Code -eq 0 -and $rbUp.Code -eq 0)
      }else{$rollbackSucceeded=$true}
    }catch{$rollbackSucceeded=$false}
  }
  $result=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='failed'
    classification='RELEASE_RESULTS_NORMALIZATION_FAILED'
    host=$env:COMPUTERNAME;changed=$changed;backup=$backup
    sourceHashBefore=$beforeHash;sourceHashAfter=$afterHash;error=$err
    rollbackAttempted=$rollbackAttempted;rollbackSucceeded=$rollbackSucceeded
    secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $result
  Write-Diag $result
  $result | ConvertTo-Json -Compress -Depth 20 | Write-Output
  exit 1
}finally{
  if($null -eq $oldDockerConfig){Remove-Item Env:DOCKER_CONFIG -ErrorAction SilentlyContinue}else{$env:DOCKER_CONFIG=$oldDockerConfig}
  if($null -eq $oldDockerHost){Remove-Item Env:DOCKER_HOST -ErrorAction SilentlyContinue}else{$env:DOCKER_HOST=$oldDockerHost}
  if($tempConfig -and (Test-Path -LiteralPath $tempConfig -PathType Container)){Remove-Item -LiteralPath $tempConfig -Recurse -Force -ErrorAction SilentlyContinue}
}
