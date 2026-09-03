#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$projectRoot='C:\docker\movie-recommender'
$composePath=Join-Path $projectRoot 'docker-compose.yml'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\movierecommender-stremio-rebind.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-stremio-rebind'
$stateFile=Join-Path $stateRoot 'latest.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagFile=Join-Path $diagRoot 'AFZ-MovieRecommender-Stremio-Rebind-Latest.json'
$diagTextFile=Join-Path $diagRoot 'AFZ-MovieRecommender-Stremio-Rebind-Latest.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 20 -Compress),$utf8)
}
function Publish-Diagnostic($Object){
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      Write-Json $diagFile $Object
      Write-Json $diagTextFile $Object
    }
  }catch{}
}
function Invoke-Native([string]$File,[string[]]$ArgumentList,[string]$WorkingDirectory=$projectRoot){
  $prior=(Get-Location).Path
  try{
    Set-Location -LiteralPath $WorkingDirectory
    $out=@(& $File @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
    $code=$LASTEXITCODE
    return [pscustomobject]@{Code=[int]$code;Output=$out}
  }finally{
    Set-Location -LiteralPath $prior
  }
}
function Invoke-Docker([string[]]$ArgumentList){
  return Invoke-Native -File 'docker.exe' -ArgumentList $ArgumentList -WorkingDirectory $projectRoot
}
function Test-HttpJson([string]$Uri,[int]$TimeoutSec=5){
  try{
    $r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec
    if([int]$r.StatusCode -ne 200){return $null}
    return ([string]$r.Content | ConvertFrom-Json)
  }catch{return $null}
}
function Get-ListenerOwners([int]$Port){
  $owners=@()
  try{
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    foreach($l in $listeners){
      $p=Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
      $owners += [pscustomobject]@{
        localAddress=[string]$l.LocalAddress
        port=[int]$l.LocalPort
        pid=[int]$l.OwningProcess
        process=$(if($p){[string]$p.ProcessName}else{'unknown'})
      }
    }
  }catch{}
  return @($owners)
}

if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'INVALID_REQUEST_JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'movierecommender' -or [string]$req.action -ne 'stremio-rebind'){throw 'INVALID_REQUEST_SCHEMA_PROJECT_ACTION'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'INVALID_JOB_ID'}
if([int]$req.desired_host_port -ne 18766 -or [int]$req.container_port -ne 8766){throw 'INVALID_FIXED_PORTS'}
if([bool]$req.allow_build -or -not [bool]$req.rollback_on_failure){throw 'INVALID_SAFETY_FLAGS'}

$prior=Read-Json $stateFile
if($prior -and [string]$prior.job_id -eq $job -and [string]$prior.status -in @('completed','failed','safe-stop')){
  $prior | ConvertTo-Json -Depth 20 -Compress | Write-Output
  exit 0
}

$started=Get-Date
$backupPath=$null
$composeChanged=$false
$containerStarted=$false
try{
  if(-not(Test-Path -LiteralPath $projectRoot -PathType Container)){throw 'PROJECT_ROOT_MISSING'}
  if(-not(Test-Path -LiteralPath $composePath -PathType Leaf)){throw 'COMPOSE_FILE_MISSING'}

  $dockerVersion=Invoke-Docker @('version','--format','{{.Server.Version}}')
  if($dockerVersion.Code -ne 0){throw ('DOCKER_ENGINE_UNAVAILABLE: '+(($dockerVersion.Output -join ' ') -replace '\s+',' '))}

  $imageCheck=Invoke-Docker @('image','inspect','movie-recommender-stremio-catalog:latest','--format','{{.Id}}')
  if($imageCheck.Code -ne 0){throw 'SIDECAR_IMAGE_MISSING_NO_BUILD_ALLOWED'}

  $dockerPortOwners=@()
  $ps=Invoke-Docker @('ps','-a','--format','{{.Names}}|{{.Ports}}')
  if($ps.Code -eq 0){
    foreach($line in $ps.Output){
      if($line -match '18766'){
        $parts=@($line -split '\|',2)
        $dockerPortOwners += [pscustomobject]@{name=$parts[0];ports=$(if($parts.Count -gt 1){$parts[1]}else{''})}
      }
    }
  }
  $tcpOwners=@(Get-ListenerOwners 18766)
  $foreignDocker=@($dockerPortOwners | Where-Object {$_.name -ne 'afz-stremio-catalog'})
  if(@($foreignDocker).Count -gt 0){throw ('HOST_PORT_18766_DOCKER_CONFLICT: '+(($foreignDocker | ConvertTo-Json -Compress) -replace '\s+',' '))}
  if(@($tcpOwners).Count -gt 0 -and @($dockerPortOwners).Count -eq 0){
    throw ('HOST_PORT_18766_PROCESS_CONFLICT: '+(($tcpOwners | ConvertTo-Json -Compress) -replace '\s+',' '))
  }

  # Already healthy on the desired port: validate and complete without mutation.
  $existingHealth=Test-HttpJson 'http://127.0.0.1:18766/health'
  $existingManifest=Test-HttpJson 'http://127.0.0.1:18766/manifest.json'
  if($existingHealth -and $existingManifest -and $existingManifest.id -and @($existingManifest.catalogs).Count -gt 0){
    $first=@($existingManifest.catalogs)[0]
    $type=[Uri]::EscapeDataString([string]$first.type)
    $id=[Uri]::EscapeDataString([string]$first.id)
    $existingCatalog=Test-HttpJson ("http://127.0.0.1:18766/catalog/$type/$id.json") 10
    if($existingCatalog -and ($existingCatalog.PSObject.Properties.Name -contains 'metas')){
      $out=[ordered]@{
        schema=1;controlPlane='github';source='windows-main-local-github-request';project='movierecommender'
        job_id=$job;status='completed';classification='STREMIO_SIDECAR_ALREADY_ACCEPTED';changed=$false
        host=$expectedComputer;hostPort=18766;containerPort=8766
        composePass=$true;containerPass=$true;healthPass=$true;manifestPass=$true;catalogPass=$true
        manifestId=[string]$existingManifest.id;manifestVersion=[string]$existingManifest.version
        catalogType=[string]$first.type;catalogId=[string]$first.id;metasCount=@($existingCatalog.metas).Count
        backupPath=$null;secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
      }
      Write-Json $stateFile $out;Publish-Diagnostic $out
      $out | ConvertTo-Json -Depth 20 -Compress | Write-Output
      exit 0
    }
  }

  $composeText=[IO.File]::ReadAllText($composePath)
  $oldToken='"127.0.0.1:8766:8766"'
  $newToken='"127.0.0.1:18766:8766"'
  $oldCount=([regex]::Matches($composeText,[regex]::Escape($oldToken))).Count
  $newCount=([regex]::Matches($composeText,[regex]::Escape($newToken))).Count
  if($oldCount -eq 1 -and $newCount -eq 0){
    $backupPath="$composePath.before-stremio-18766-$job.bak"
    Copy-Item -LiteralPath $composePath -Destination $backupPath -Force
    $composeText=$composeText.Replace($oldToken,$newToken)
    [IO.File]::WriteAllText($composePath,$composeText,$utf8)
    $composeChanged=$true
  }elseif($oldCount -eq 0 -and $newCount -eq 1){
    $composeChanged=$false
  }else{
    throw "AMBIGUOUS_COMPOSE_PORT_MAPPING oldCount=$oldCount newCount=$newCount"
  }

  $config=Invoke-Docker @('compose','config','--quiet')
  if($config.Code -ne 0){throw ('COMPOSE_CONFIG_FAILED: '+(($config.Output -join ' ') -replace '\s+',' '))}

  $up=Invoke-Docker @('compose','up','-d','--no-build','--pull','never','--force-recreate','stremio-catalog')
  if($up.Code -ne 0){throw ('SIDECAR_START_FAILED: '+(($up.Output -join ' ') -replace '\s+',' '))}
  $containerStarted=$true

  $health=$null
  $manifest=$null
  $deadline=(Get-Date).AddSeconds(90)
  do{
    Start-Sleep -Seconds 2
    $health=Test-HttpJson 'http://127.0.0.1:18766/health'
    $manifest=Test-HttpJson 'http://127.0.0.1:18766/manifest.json'
    if($health -and $manifest){break}
  }while((Get-Date) -lt $deadline)
  if(-not $health){throw 'HEALTH_ENDPOINT_NOT_READY'}
  if(-not $manifest -or -not $manifest.id -or -not $manifest.version -or @($manifest.catalogs).Count -lt 1){throw 'MANIFEST_ACCEPTANCE_FAILED'}

  $first=@($manifest.catalogs)[0]
  if(-not $first.type -or -not $first.id){throw 'MANIFEST_FIRST_CATALOG_INVALID'}
  $type=[Uri]::EscapeDataString([string]$first.type)
  $id=[Uri]::EscapeDataString([string]$first.id)
  $catalog=Test-HttpJson ("http://127.0.0.1:18766/catalog/$type/$id.json") 15
  if(-not $catalog -or -not ($catalog.PSObject.Properties.Name -contains 'metas')){throw 'CATALOG_ACCEPTANCE_FAILED'}

  $inspect=Invoke-Docker @('inspect','-f','{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}','afz-stremio-catalog')
  if($inspect.Code -ne 0 -or @($inspect.Output).Count -lt 1){throw 'CONTAINER_INSPECT_FAILED'}
  $stateLine=[string]$inspect.Output[-1]
  if($stateLine -notmatch '^running\|(healthy|none)$'){throw "CONTAINER_NOT_RUNNING_HEALTHY state=$stateLine"}

  $out=[ordered]@{
    schema=1;controlPlane='github';source='windows-main-local-github-request';project='movierecommender'
    job_id=$job;status='completed';classification='STREMIO_SIDECAR_ACCEPTED_18766';changed=$composeChanged
    host=$expectedComputer;hostPort=18766;containerPort=8766
    composePass=$true;containerPass=$true;containerState=$stateLine;healthPass=$true;manifestPass=$true;catalogPass=$true
    manifestId=[string]$manifest.id;manifestVersion=[string]$manifest.version
    catalogType=[string]$first.type;catalogId=[string]$first.id;metasCount=@($catalog.metas).Count
    backupPath=$backupPath;secretExposed=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $out;Publish-Diagnostic $out
  $out | ConvertTo-Json -Depth 20 -Compress | Write-Output
  exit 0
}catch{
  $err=$_.Exception.Message
  if($composeChanged -and $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)){
    try{Copy-Item -LiteralPath $backupPath -Destination $composePath -Force}catch{}
  }
  if($containerStarted){
    try{Invoke-Docker @('compose','stop','stremio-catalog') | Out-Null}catch{}
  }
  $out=[ordered]@{
    schema=1;controlPlane='github';source='windows-main-local-github-request';project='movierecommender'
    job_id=$job;status='failed';classification='STREMIO_SIDECAR_REBIND_FAILED';changed=$composeChanged
    host=$expectedComputer;hostPort=18766;containerPort=8766;error=$err
    backupPath=$backupPath;rollbackAttempted=$composeChanged;secretExposed=$false
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $out;Publish-Diagnostic $out
  $out | ConvertTo-Json -Depth 20 -Compress | Write-Output
  exit 1
}
