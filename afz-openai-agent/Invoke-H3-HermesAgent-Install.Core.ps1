#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Hermes Docker request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid Hermes Docker request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.status -ne 'ACTIVE'){throw 'Hermes Docker request is not active.'}
if([string]$req.deployment -ne 'docker-desktop' -or [string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'Hermes Docker target mismatch.'}
if([string]$req.image -ne 'nousresearch/hermes-agent:latest' -or [string]$req.container_name -ne 'hermes-h3'){throw 'Hermes Docker image/container mismatch.'}
if([string]$req.dashboard_host_ip -ne '100.106.186.118' -or [int]$req.dashboard_port -ne 9119 -or [string]$req.dashboard_username -ne 'afz'){throw 'Hermes Docker dashboard mismatch.'}
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1' -or [string]$req.container_base_url -ne 'http://host.docker.internal:11434/v1'){throw 'Hermes Docker Ollama routing mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [string]$req.preferred_model -ne 'qwen3.6:35b-a3b-hermes64k' -or [int]$req.context_length -ne 65536){throw 'Hermes Docker model request mismatch.'}
if([string]$req.memory_limit -ne '4g' -or [int]$req.cpu_limit -ne 2 -or [string]$req.shm_size -ne '1g'){throw 'Hermes Docker resource policy mismatch.'}
if(-not [bool]$req.verify_before_repair -or -not [bool]$req.publish_result){throw 'Hermes Docker verify/publish policy mismatch.'}
if([string]$req.result_branch -ne 'h3-direct-results' -or [string]$req.result_path -ne 'afz-openai-agent/results/h3-hermes-docker-latest.json'){throw 'Hermes Docker result route mismatch.'}
if([bool]$req.expose_api -or [bool]$req.run_generation_test -or [bool]$req.mutate_ollama){throw 'Hermes Docker safety flags mismatch.'}

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 16 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  Write-Output $json
}
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 SSH path missing: $p"}}

$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$container='hermes-h3'
$image='nousresearch/hermes-agent:latest'
$bindIp='100.106.186.118'
$dashboardPort=9119
$dashboardUser='afz'
$baseModel='qwen3.6:35b-a3b'
$preferredModel='qwen3.6:35b-a3b-hermes64k'
$containerBaseUrl='http://host.docker.internal:11434/v1'
$qwenAlias='qwen-h3'
$repo='f3arif/homelab-control'
$resultBranch='h3-direct-results'
$resultPath='afz-openai-agent/results/h3-hermes-docker-latest.json'
$root=Join-Path $env:LOCALAPPDATA 'HermesDockerDesktop'
$dataRoot=Join-Path $root 'data'
$envPath=Join-Path $dataRoot '.env'
$configPath=Join-Path $dataRoot 'config.yaml'
$credentialPath=Join-Path $root 'desktop-credentials.txt'
$generationTestStarted=$false
$ollamaMutationStarted=$false
$utf8=New-Object Text.UTF8Encoding($false)
$script:docker=$null
$script:selectedModel=$baseModel
$script:hostOllama=$false
$script:hostModels=@()

function RandHex([int]$bytes){
  $rng=New-Object Security.Cryptography.RNGCryptoServiceProvider
  try{$b=New-Object byte[] $bytes;$rng.GetBytes($b);return ([BitConverter]::ToString($b)).Replace('-','').ToLowerInvariant()}finally{$rng.Dispose()}
}
function ProtectFile([string]$path){
  try{
    $user=New-Object Security.Principal.NTAccount("$env:USERDOMAIN\$env:USERNAME")
    $acl=New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($user);$acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($user,'FullControl','Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.NTAccount('NT AUTHORITY\SYSTEM')),'FullControl','Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
  }catch{}
}
function Find-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Publish-Result([bool]$ok,[string]$classification,[hashtable]$extra){
  $gh=Find-Gh
  if(-not $gh){return [ordered]@{ok=$false;error='GitHub CLI unavailable on H3.'}}
  try{
    $perm=(& $gh api "repos/$repo" --jq '.permissions.push' 2>&1|Out-String).Trim()
    if($LASTEXITCODE -ne 0 -or $perm.ToLowerInvariant() -ne 'true'){return [ordered]@{ok=$false;error='H3 GitHub identity does not have authenticated push permission.'}}
    $doc=[ordered]@{
      schema=1
      kind='h3-hermes-docker-runtime'
      ok=$ok
      classification=$classification
      deployment='docker-desktop'
      host=$env:COMPUTERNAME
      containerName=$container
      image=$image
      dashboardUrl=("http://{0}:{1}" -f $bindIp,$dashboardPort)
      dashboardUsername=$dashboardUser
      containerBaseUrl=$containerBaseUrl
      qwenAlias=$qwenAlias
      qwenAliasConfigured=$(if($extra.ContainsKey('qwenAliasConfigured')){[bool]$extra.qwenAliasConfigured}else{$false})
      defaultModelPreserved=$(if($extra.ContainsKey('defaultModelPreserved')){[bool]$extra.defaultModelPreserved}else{$true})
      apiPublished=$false
      generationTestStarted=$false
      ollamaMutationStarted=$false
      repaired=$(if($extra.ContainsKey('repaired')){[bool]$extra.repaired}else{$false})
      containerRunning=$(if($extra.ContainsKey('containerRunning')){[bool]$extra.containerRunning}else{$false})
      dashboardStatusReachable=$(if($extra.ContainsKey('dashboardStatusReachable')){[bool]$extra.dashboardStatusReachable}else{$false})
      authRequired=$(if($extra.ContainsKey('authRequired')){[bool]$extra.authRequired}else{$false})
      basicAuthProvider=$(if($extra.ContainsKey('basicAuthProvider')){[bool]$extra.basicAuthProvider}else{$false})
      dashboardPortBindingOk=$(if($extra.ContainsKey('dashboardPortBindingOk')){[bool]$extra.dashboardPortBindingOk}else{$false})
      hostOllamaReachable=$(if($extra.ContainsKey('hostOllamaReachable')){[bool]$extra.hostOllamaReachable}else{$false})
      containerOllamaReachable=$(if($extra.ContainsKey('containerOllamaReachable')){[bool]$extra.containerOllamaReachable}else{$false})
      selectedModel=$(if($extra.ContainsKey('selectedModel')){[string]$extra.selectedModel}else{$script:selectedModel})
      selectedModelListed=$(if($extra.ContainsKey('selectedModelListed')){[bool]$extra.selectedModelListed}else{$false})
      hermesVersion=$(if($extra.ContainsKey('hermesVersion')){[string]$extra.hermesVersion}else{$null})
      dockerServerVersion=$(if($extra.ContainsKey('dockerServerVersion')){[string]$extra.dockerServerVersion}else{$null})
      resourceMemory='4g'
      resourceCpus=2
      shmSize='1g'
      publishedAt=(Get-Date -Format o)
    }
    $existingSha=$null
    $lookup=(& $gh api "repos/$repo/contents/$resultPath`?ref=$resultBranch" --jq '.sha' 2>$null|Out-String).Trim()
    if($LASTEXITCODE -eq 0 -and $lookup -match '^[0-9a-f]{40}$'){$existingSha=$lookup}
    $payload=[ordered]@{
      message=("H3 Hermes Docker runtime {0}" -f $classification)
      content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($doc|ConvertTo-Json -Depth 8 -Compress)))
      branch=$resultBranch
    }
    if($existingSha){$payload.sha=$existingSha}
    $tmp=Join-Path $env:TEMP ('afz-hermes-publish-'+[guid]::NewGuid().ToString('N')+'.json')
    try{
      [IO.File]::WriteAllText($tmp,($payload|ConvertTo-Json -Depth 8 -Compress),$utf8)
      $put=(& $gh api "repos/$repo/contents/$resultPath" --method PUT --input $tmp 2>&1|Out-String).Trim()
      if($LASTEXITCODE -ne 0){return [ordered]@{ok=$false;error='GitHub result publication failed.'}}
    }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
    return [ordered]@{ok=$true;branch=$resultBranch;path=$resultPath}
  }catch{return [ordered]@{ok=$false;error='GitHub result publication raised an exception.'}}
}
function Test-CurrentHealth([string]$serverVersion){
  $running=$false;$statusReachable=$false;$authRequired=$false;$basicAuth=$false;$containerOllama=$false;$modelListed=$false;$version=$null;$portOk=$false;$apiPublished=$false
  try{
    $state=(& $script:docker inspect -f '{{.State.Running}}' $container 2>$null|Out-String).Trim().ToLowerInvariant()
    $running=($state -eq 'true')
  }catch{}
  if($running){
    try{
      $port=(& $script:docker port $container '9119/tcp' 2>$null|Out-String).Trim()
      $portOk=($port -split "`r?`n"|Where-Object{$_ -eq ("{0}:{1}" -f $bindIp,$dashboardPort)}|Measure-Object).Count -gt 0
    }catch{}
    try{
      $apiPort=(& $script:docker port $container '8642/tcp' 2>$null|Out-String).Trim()
      $apiPublished=(-not [string]::IsNullOrWhiteSpace($apiPort))
    }catch{$apiPublished=$false}
    try{
      $sr=(& $script:docker exec $container curl -fsS 'http://127.0.0.1:9119/api/status' 2>$null|Out-String).Trim()
      if($LASTEXITCODE -eq 0 -and $sr){
        $status=$sr|ConvertFrom-Json;$statusReachable=$true
        if($status.PSObject.Properties.Name -contains 'auth_required'){$authRequired=[bool]$status.auth_required}
        if($status.PSObject.Properties.Name -contains 'auth_providers'){$basicAuth=('basic' -in @($status.auth_providers|ForEach-Object{[string]$_}))}
      }
    }catch{}
    try{
      $mr=(& $script:docker exec $container curl -fsS 'http://host.docker.internal:11434/v1/models' 2>$null|Out-String).Trim()
      if($LASTEXITCODE -eq 0 -and $mr){
        $mo=$mr|ConvertFrom-Json
        $listed=@($mo.data|ForEach-Object{[string]$_.id})
        $containerOllama=$true
        $modelListed=($script:selectedModel -in $listed)
      }
    }catch{}
    try{$version=(& $script:docker exec $container hermes version 2>&1|Out-String).Trim()}catch{}
  }
  $ready=($running -and $portOk -and -not $apiPublished -and $statusReachable -and $authRequired -and $basicAuth -and $script:hostOllama -and $containerOllama -and $modelListed)
  return [ordered]@{
    ready=$ready;containerRunning=$running;dashboardPortBindingOk=$portOk;apiPublished=$apiPublished
    dashboardStatusReachable=$statusReachable;authRequired=$authRequired;basicAuthProvider=$basicAuth
    hostOllamaReachable=$script:hostOllama;containerOllamaReachable=$containerOllama
    selectedModel=$script:selectedModel;selectedModelListed=$modelListed;hostModelCount=$script:hostModels.Count
    hermesVersion=$version;dockerReady=$true;dockerServerVersion=$serverVersion
    resourceMemory='4g';resourceCpus=2;shmSize='1g'
  }
}
function Ensure-QwenAlias{
  if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){return [ordered]@{ok=$false;error='Hermes config.yaml is missing.'}}
  $aliasSpec=[ordered]@{model=$script:selectedModel;provider='custom';base_url=$containerBaseUrl;api_key='none'}|ConvertTo-Json -Compress
  $setRaw=(& $script:docker exec $container hermes config set ("model_aliases.{0}" -f $qwenAlias) $aliasSpec 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0){return [ordered]@{ok=$false;error=("hermes config set failed: {0}" -f $setRaw)}}
  $getRaw=(& $script:docker exec $container hermes config get ("model_aliases.{0}" -f $qwenAlias) --json 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($getRaw)){return [ordered]@{ok=$false;error=("hermes config get failed: {0}" -f $getRaw)}}
  try{$a=$getRaw|ConvertFrom-Json}catch{return [ordered]@{ok=$false;error='Hermes returned non-JSON alias state.'}}
  $ok=([string]$a.model -eq $script:selectedModel -and [string]$a.provider -eq 'custom' -and [string]$a.base_url -eq $containerBaseUrl)
  return [ordered]@{ok=$ok;error=$(if($ok){$null}else{'Hermes alias verification mismatch.'})}
}
function Emit([bool]$ok,[string]$classification,[hashtable]$extra,[bool]$publish){
  $pub=[ordered]@{ok=$false;error=$null}
  if($publish){$pub=Publish-Result $ok $classification $extra}
  $o=[ordered]@{
    schema=2;ok=$ok;classification=$classification;deployment='docker-desktop';host=$env:COMPUTERNAME
    containerName=$container;image=$image;dashboardUrl=("http://{0}:{1}" -f $bindIp,$dashboardPort)
    credentialsPath=$credentialPath;containerBaseUrl=$containerBaseUrl;qwenAlias=$qwenAlias
    generationTestStarted=$false;ollamaMutationStarted=$false;apiPublished=$false
    githubPublished=[bool]$pub.ok;githubResultBranch=$(if($pub.ok){$resultBranch}else{$null});githubResultPath=$(if($pub.ok){$resultPath}else{$null})
    githubPublishError=$(if($pub.ok){$null}else{[string]$pub.error});capturedAt=(Get-Date -Format o)
  }
  foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
  $o|ConvertTo-Json -Depth 10 -Compress
}

try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit $false 'HERMES_DOCKER_WRONG_HOST' @{retryable=$false;repaired=$false} $false;exit 30}
  $dockerCmd=Get-Command docker.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if(-not $dockerCmd){
    $dockerFallback='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    if(Test-Path -LiteralPath $dockerFallback -PathType Leaf){$dockerCmd=[pscustomobject]@{Source=$dockerFallback}}
  }
  if(-not $dockerCmd){Emit $false 'HERMES_DOCKER_ENGINE_MISSING' @{retryable=$false;dockerReady=$false;repaired=$false} $false;exit 31}
  $script:docker=[string]$dockerCmd.Source
  $serverVersion=(& $script:docker version --format '{{.Server.Version}}' 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverVersion)){Emit $false 'HERMES_DOCKER_ENGINE_UNAVAILABLE' @{retryable=$true;dockerReady=$false;repaired=$false} $false;exit 32}
  $ipPresent=$false
  try{$ipPresent=[bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Where-Object{$_.IPAddress -eq $bindIp}|Select-Object -First 1)}catch{}
  if(-not $ipPresent){Emit $false 'HERMES_DOCKER_TAILSCALE_IP_MISSING' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion;repaired=$false} $false;exit 33}
  try{
    $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10
    $script:hostModels=@($tags.models|ForEach-Object{[string]$_.name});$script:hostOllama=$true
  }catch{$script:hostOllama=$false}
  if(-not $script:hostOllama){Emit $false 'HERMES_DOCKER_HOST_OLLAMA_UNREACHABLE' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion;repaired=$false} $false;exit 34}
  $script:selectedModel=$(if($preferredModel -in $script:hostModels){$preferredModel}elseif($baseModel -in $script:hostModels){$baseModel}else{$baseModel})

  # Healthy containers are preserved. Add/verify the Qwen alias in-place without changing model.default.
  $before=Test-CurrentHealth $serverVersion
  if([bool]$before.ready){
    $alias=Ensure-QwenAlias
    $e=@{};foreach($p in $before.GetEnumerator()){$e[$p.Key]=$p.Value};$e.repaired=$false;$e.defaultModelPreserved=$true;$e.qwenAliasConfigured=[bool]$alias.ok
    if([bool]$alias.ok){$e.retryable=$false;Emit $true 'HERMES_READY_LOCAL_OLLAMA_64K' $e $true;exit 0}
    $e.retryable=$true;$e.error=[string]$alias.error
    Emit $false 'HERMES_OLLAMA_ALIAS_CONFIG_FAILED' $e $false
    exit 38
  }

  New-Item -ItemType Directory -Force -Path $root,$dataRoot|Out-Null
  $password=$null;$secret=$null
  if(Test-Path -LiteralPath $envPath -PathType Leaf){
    $et=[IO.File]::ReadAllText($envPath)
    $m=[regex]::Match($et,'(?m)^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=(.+)$');if($m.Success){$password=$m.Groups[1].Value.Trim()}
    $m=[regex]::Match($et,'(?m)^HERMES_DASHBOARD_BASIC_AUTH_SECRET=(.+)$');if($m.Success){$secret=$m.Groups[1].Value.Trim()}
  }
  if([string]::IsNullOrWhiteSpace($password)){$password=RandHex 24}
  if([string]::IsNullOrWhiteSpace($secret)){$secret=RandHex 32}
  $envText=@(
    'HERMES_DASHBOARD=1','HERMES_DASHBOARD_HOST=0.0.0.0','HERMES_DASHBOARD_PORT=9119',
    'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=afz',
    ('HERMES_DASHBOARD_BASIC_AUTH_PASSWORD='+$password),('HERMES_DASHBOARD_BASIC_AUTH_SECRET='+$secret)
  ) -join "`n"
  [IO.File]::WriteAllText($envPath,$envText+"`n",$utf8);ProtectFile $envPath

  # Preserve any existing Hermes model/provider configuration. Only bootstrap Qwen as
  # the main model when config.yaml does not yet exist or is empty.
  $defaultModelPreserved=$false
  if(Test-Path -LiteralPath $configPath -PathType Leaf){
    $existingConfig=[IO.File]::ReadAllText($configPath)
    if(-not [string]::IsNullOrWhiteSpace($existingConfig)){$defaultModelPreserved=$true}
  }
  if(-not $defaultModelPreserved){
    $config=@"
model:
  default: "$script:selectedModel"
  provider: custom
  base_url: "$containerBaseUrl"
  api_key: "none"
  context_length: 65536
tool_loop_guardrails:
  hard_stop_enabled: true
  hard_stop_after:
    exact_failure: 5
    idempotent_no_progress: 5
"@
    [IO.File]::WriteAllText($configPath,$config,$utf8)
  }
  [IO.File]::WriteAllText($credentialPath,("Hermes Desktop H3`r`nURL: http://${bindIp}:9119`r`nUsername: afz`r`nPassword: $password`r`n"),$utf8);ProtectFile $credentialPath

  & $script:docker pull $image *> $null
  if($LASTEXITCODE -ne 0){Emit $false 'HERMES_DOCKER_IMAGE_PULL_FAILED' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion;repaired=$false;defaultModelPreserved=$defaultModelPreserved} $false;exit 35}
  $exists=(& $script:docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>$null|Out-String).Trim()
  if($exists -eq $container){& $script:docker rm -f $container *> $null;if($LASTEXITCODE -ne 0){throw 'Could not replace unhealthy Hermes container.'}}
  $runArgs=@(
    'run','-d','--name',$container,'--restart','unless-stopped','--memory=4g','--cpus=2','--shm-size=1g',
    '--env-file',$envPath,'-p',("${bindIp}:9119:9119"),'--mount',("type=bind,source=$dataRoot,target=/opt/data"),
    $image,'gateway','run'
  )
  $cid=(& $script:docker @runArgs 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cid)){Emit $false 'HERMES_DOCKER_CONTAINER_START_FAILED' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion;repaired=$true;defaultModelPreserved=$defaultModelPreserved} $false;exit 36}

  $after=$null
  for($i=0;$i -lt 45;$i++){
    Start-Sleep -Seconds 2
    $after=Test-CurrentHealth $serverVersion
    if([bool]$after.ready){break}
    if(-not [bool]$after.containerRunning){break}
  }
  if($null -eq $after){$after=Test-CurrentHealth $serverVersion}
  $x=@{};foreach($p in $after.GetEnumerator()){$x[$p.Key]=$p.Value};$x.repaired=$true;$x.defaultModelPreserved=$defaultModelPreserved
  if([bool]$after.ready){
    $alias=Ensure-QwenAlias;$x.qwenAliasConfigured=[bool]$alias.ok
    if([bool]$alias.ok){$x.retryable=$false;Emit $true 'HERMES_READY_LOCAL_OLLAMA_64K' $x $true;exit 0}
    $x.retryable=$true;$x.error=[string]$alias.error
    Emit $false 'HERMES_OLLAMA_ALIAS_CONFIG_FAILED' $x $false
    exit 38
  }
  $x.qwenAliasConfigured=$false;$x.retryable=$true
  Emit $false 'HERMES_DOCKER_DESKTOP_SETUP_INCOMPLETE' $x $false
  exit 37
}catch{
  Emit $false 'HERMES_DOCKER_DESKTOP_SETUP_FAILED' @{retryable=$true;repaired=$false;error=$_.Exception.Message} $false
  exit 75
}
'@

$inFile=Join-Path $env:TEMP ('afz-h3-hermes-docker-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-docker-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-docker-'+[guid]::NewGuid().ToString('n')+'.err')
$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes remote stdin was empty.''};Invoke-Expression $script'
$bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded)
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(300000)){try{$p.Kill()}catch{};throw 'H3 Hermes Docker verify/repair exceeded 300 seconds.'}
  $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
  if([string]::IsNullOrWhiteSpace($stdout)){throw "H3 Hermes Docker SSH returned no result. exit=$($p.ExitCode) stderr=$stderr"}
  $lines=@($stdout -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
  $result=$lines[$lines.Count-1]|ConvertFrom-Json
  $result|Add-Member -NotePropertyName jobId -NotePropertyValue $id -Force
  Save-State $result
  if([bool]$result.ok){exit 0}
  exit $(if($p.ExitCode -gt 0){$p.ExitCode}else{75})
}catch{
  Save-State ([ordered]@{schema=2;ok=$false;classification='HERMES_DOCKER_DESKTOP_TRANSPORT_FAILED';deployment='docker-desktop';jobId=$id;retryable=$true;error=$_.Exception.Message;generationTestStarted=$false;ollamaMutationStarted=$false;capturedAt=(Get-Date -Format o)})
  exit 75
}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}