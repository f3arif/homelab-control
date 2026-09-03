#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$projectRoot='C:\docker\movie-recommender'
$requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\movierecommender-catalog-audit.json'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-catalog-audit'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagFile=Join-Path $diagRoot 'AFZ-MovieRecommender-Catalog-Audit-Latest.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object | ConvertTo-Json -Depth 20 -Compress),$utf8)
}
function Safe-Text([string]$Text){
  if($null -eq $Text){return ''}
  $s=[string]$Text
  $s=[regex]::Replace($s,'(?im)^(\s*[A-Za-z0-9_.-]*(?:KEY|TOKEN|PASSWORD|SECRET|AUTH)[A-Za-z0-9_.-]*\s*[:=]\s*).+$','$1[REDACTED]')
  $s=[regex]::Replace($s,'(?i)([?&](?:api_?key|token|key|apikey|auth|access_token)=)[^&\s]+','$1[REDACTED]')
  $s=[regex]::Replace($s,'(?i)(Authorization:\s*(?:Bearer|Basic)\s+)\S+','$1[REDACTED]')
  return $s
}
function Quote-NativeArg([string]$Arg){
  if($null -eq $Arg){return '""'}
  return '"' + $Arg.Replace('\','\\').Replace('"','\"') + '"'
}
function Invoke-Native([string]$File,[string[]]$ArgumentList,[int]$TimeoutSec=45,[string]$WorkingDirectory=$projectRoot){
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
  $stdout=$stdoutTask.Result
  $stderr=$stderrTask.Result
  return [pscustomobject]@{Code=[int]$p.ExitCode;Stdout=[string]$stdout;Stderr=[string]$stderr}
}
function Invoke-Docker([string[]]$ArgumentList,[int]$TimeoutSec=45){
  return Invoke-Native -File 'docker.exe' -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec -WorkingDirectory $projectRoot
}
function Http-Json([string]$Uri,[int]$TimeoutSec=10){
  try{
    $r=Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec
    if([int]$r.StatusCode -ne 200){return $null}
    return ([string]$r.Content | ConvertFrom-Json)
  }catch{return $null}
}
function Relative-Path([string]$Full){
  if($Full.StartsWith($projectRoot,[StringComparison]::OrdinalIgnoreCase)){
    return $Full.Substring($projectRoot.Length).TrimStart('\')
  }
  return $Full
}

if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){exit 0}
$req=Read-Json $requestPath
if(-not $req){throw 'INVALID_REQUEST_JSON'}
if([int]$req.schema -ne 1 -or [string]$req.project -ne 'movierecommender' -or [string]$req.action -ne 'catalog-audit'){throw 'INVALID_REQUEST'}
if([string]$req.status -ne 'active' -or [string]$req.target -ne 'windows-main' -or [string]$req.host -ne $expectedComputer){exit 0}
if(-not [bool]$req.read_only){throw 'READ_ONLY_REQUIRED'}
$job=[string]$req.job_id
if($job -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,100}$'){throw 'INVALID_JOB_ID'}
$stateFile=Join-Path $stateRoot ($job+'.json')
$prior=Read-Json $stateFile
if($prior -and [string]$prior.status -eq 'completed'){exit 0}

$started=Get-Date
$lines=New-Object 'System.Collections.Generic.List[string]'
function Add-Line([string]$Line){[void]$lines.Add((Safe-Text $Line))}
function Add-Block([string]$Name,[string]$Text,[int]$MaxChars=30000){
  Add-Line ("--- "+$Name+" BEGIN ---")
  $safe=Safe-Text $Text
  if($safe.Length -gt $MaxChars){$safe=$safe.Substring(0,$MaxChars)+[Environment]::NewLine+'[TRUNCATED]'}
  foreach($ln in ($safe -split '\r?\n')){[void]$lines.Add($ln)}
  Add-Line ("--- "+$Name+" END ---")
}

try{
  if(-not(Test-Path -LiteralPath $projectRoot -PathType Container)){throw 'PROJECT_ROOT_MISSING'}
  Add-Line '===== AFZ MOVIERECOMMENDER CATALOG AUDIT ====='
  Add-Line ('TIME='+$started.ToString('o'))
  Add-Line ('COMPUTER='+$env:COMPUTERNAME)
  Add-Line 'MODE=READ_ONLY'
  Add-Line 'SECRETS_EXPORTED=NO'

  $docker=Invoke-Docker @('version','--format','{{.Server.Version}}')
  Add-Line ('DOCKER_EXIT='+$docker.Code)
  if($docker.Code -ne 0){throw 'DOCKER_ENGINE_UNAVAILABLE'}

  $composeServices=Invoke-Docker @('compose','config','--services')
  Add-Line ('COMPOSE_SERVICES_EXIT='+$composeServices.Code)
  foreach($s in (($composeServices.Stdout -split '\r?\n') | Where-Object {$_})){Add-Line ('COMPOSE_SERVICE='+$s.Trim())}

  $inspect=Invoke-Docker @('inspect','afz-stremio-catalog')
  if($inspect.Code -ne 0){throw 'SIDECAR_CONTAINER_MISSING'}
  $obj=($inspect.Stdout | ConvertFrom-Json)[0]
  Add-Line ('CONTAINER_NAME='+[string]$obj.Name)
  Add-Line ('CONTAINER_IMAGE='+[string]$obj.Config.Image)
  Add-Line ('CONTAINER_STATE='+[string]$obj.State.Status)
  if($obj.State.Health){Add-Line ('CONTAINER_HEALTH='+[string]$obj.State.Health.Status)}
  Add-Line ('CONTAINER_WORKDIR='+[string]$obj.Config.WorkingDir)
  if($obj.Config.Cmd){Add-Line ('CONTAINER_CMD='+(@($obj.Config.Cmd) -join ' '))}
  foreach($e in @($obj.Config.Env)){
    $key=(([string]$e) -split '=',2)[0]
    if($key){Add-Line ('ENV_KEY='+$key)}
  }
  foreach($m in @($obj.Mounts)){
    Add-Line ('MOUNT|TYPE='+[string]$m.Type+'|DEST='+[string]$m.Destination+'|SOURCE='+[string]$m.Source)
  }
  if($obj.NetworkSettings -and $obj.NetworkSettings.Ports){
    foreach($p in $obj.NetworkSettings.Ports.PSObject.Properties){
      $bindings=@($p.Value)
      foreach($b in $bindings){if($b){Add-Line ('PORT|CONTAINER='+$p.Name+'|HOST='+[string]$b.HostIp+':'+[string]$b.HostPort)}}
    }
  }

  $allFiles=@(Get-ChildItem -LiteralPath $projectRoot -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch '(?i)\\(?:\.git|node_modules|__pycache__|\.venv|venv)\\' -and
    $_.Name -notmatch '(?i)^\.env(?:\.|$)' -and
    $_.Name -notmatch '(?i)(secret|credential|token|password|apikey|api-key)' -and
    $_.Extension -notin @('.bak','.db','.sqlite','.sqlite3','.log')
  } | Sort-Object FullName)
  Add-Line ('PROJECT_FILE_COUNT='+@($allFiles).Count)
  foreach($f in ($allFiles | Select-Object -First 160)){
    $hash=''
    try{$hash=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}catch{}
    Add-Line ('PROJECT_FILE|'+(Relative-Path $f.FullName)+'|BYTES='+$f.Length+'|SHA256='+$hash)
  }

  $sourceCandidates=@($allFiles | Where-Object {
    $_.Length -le 100000 -and (
      $_.Extension -in @('.py','.js','.ts') -or
      $_.Name -in @('Dockerfile.stremio','requirements.txt')
    )
  } | Select-Object -First 12)
  foreach($f in $sourceCandidates){
    $raw=''
    try{$raw=[IO.File]::ReadAllText($f.FullName)}catch{}
    if($raw){Add-Block ('PROJECT_SOURCE '+(Relative-Path $f.FullName)) $raw 35000}
  }

  $containerList=Invoke-Docker @('exec','afz-stremio-catalog','sh','-lc',"find /app -maxdepth 3 -type f -printf '%p|%s\n' 2>/dev/null | sort | head -200") 30
  Add-Line ('CONTAINER_FILE_LIST_EXIT='+$containerList.Code)
  Add-Block 'CONTAINER_FILES' $containerList.Stdout 30000

  $containerPy=Invoke-Docker @('exec','afz-stremio-catalog','sh','-lc',"find /app -maxdepth 3 -type f -name '*.py' -size -100k -print 2>/dev/null | sort | head -10") 30
  $pyPaths=@(($containerPy.Stdout -split '\r?\n') | Where-Object {$_ -match '^/app/'})
  foreach($path in $pyPaths){
    $cat=Invoke-Docker @('exec','afz-stremio-catalog','cat',$path) 30
    if($cat.Code -eq 0){Add-Block ('CONTAINER_SOURCE '+$path) $cat.Stdout 35000}
  }

  $health=Http-Json 'http://127.0.0.1:18766/health'
  $manifest=Http-Json 'http://127.0.0.1:18766/manifest.json'
  Add-Line ('HEALTH_OK='+[bool]$health)
  if(-not $manifest){throw 'MANIFEST_UNAVAILABLE'}
  Add-Line ('MANIFEST_ID='+[string]$manifest.id)
  Add-Line ('MANIFEST_VERSION='+[string]$manifest.version)
  Add-Line ('MANIFEST_NAME='+[string]$manifest.name)
  $catalogs=@($manifest.catalogs)
  Add-Line ('MANIFEST_CATALOG_COUNT='+@($catalogs).Count)

  $totalMetas=0
  $nonEmpty=0
  foreach($c in $catalogs){
    $type=[string]$c.type
    $id=[string]$c.id
    $name=[string]$c.name
    Add-Line ('CATALOG_DEF|TYPE='+$type+'|ID='+$id+'|NAME='+$name)
    if($c.extra){Add-Line ('CATALOG_EXTRA|ID='+$id+'|JSON='+($c.extra|ConvertTo-Json -Compress -Depth 8))}
    if($type -and $id){
      $u='http://127.0.0.1:18766/catalog/'+[Uri]::EscapeDataString($type)+'/'+[Uri]::EscapeDataString($id)+'.json'
      $data=Http-Json $u 20
      $hasMetas=$false
      $count=0
      if($data -and ($data.PSObject.Properties.Name -contains 'metas')){
        $hasMetas=$true
        $count=@($data.metas).Count
      }
      $totalMetas+=$count
      if($count -gt 0){$nonEmpty++}
      Add-Line ('CATALOG_RESULT|TYPE='+$type+'|ID='+$id+'|HTTP_JSON='+[bool]$data+'|HAS_METAS='+$hasMetas+'|METAS='+$count)
      if($count -gt 0){
        $sample=@($data.metas) | Select-Object -First 5
        foreach($m in $sample){
          Add-Line ('META_SAMPLE|CATALOG='+$id+'|ID='+[string]$m.id+'|NAME='+[string]$m.name+'|YEAR='+[string]$m.year+'|GENRES='+(@($m.genres)-join ','))
        }
      }
    }
  }
  Add-Line ('CATALOG_TOTAL_METAS='+$totalMetas)
  Add-Line ('CATALOG_NONEMPTY_COUNT='+$nonEmpty)

  $logs=Invoke-Docker @('logs','--tail','120','afz-stremio-catalog') 30
  Add-Line ('LOGS_EXIT='+$logs.Code)
  Add-Block 'SIDECAR_LOG_STDOUT' $logs.Stdout 35000
  Add-Block 'SIDECAR_LOG_STDERR' $logs.Stderr 35000

  $classification=$(if($totalMetas -eq 0){'CATALOG_STRUCTURE_GREEN_DATA_EMPTY'}elseif($nonEmpty -lt @($catalogs).Count){'CATALOG_PARTIAL_DATA'}else{'CATALOG_DATA_PRESENT'})
  Add-Line ('CLASSIFICATION='+$classification)
  Add-Line '===== END AUDIT ====='

  $text=($lines -join [Environment]::NewLine)
  if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagFile,$text,$utf8)}
  $state=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='completed';classification=$classification
    readOnly=$true;secretExposed=$false;catalogCount=@($catalogs).Count;nonEmptyCatalogCount=$nonEmpty;totalMetas=$totalMetas
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $state
  $state | ConvertTo-Json -Compress -Depth 10 | Write-Output
  exit 0
}catch{
  $err=Safe-Text $_.Exception.Message
  Add-Line ('ERROR='+$err)
  $text=($lines -join [Environment]::NewLine)
  if(Test-Path -LiteralPath $diagRoot -PathType Container){try{[IO.File]::WriteAllText($diagFile,$text,$utf8)}catch{}}
  $state=[ordered]@{
    schema=1;project='movierecommender';job_id=$job;status='failed';classification='CATALOG_AUDIT_FAILED'
    readOnly=$true;secretExposed=$false;error=$err;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  }
  Write-Json $stateFile $state
  $state | ConvertTo-Json -Compress -Depth 10 | Write-Output
  exit 1
}
