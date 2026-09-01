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
if([string]$req.action -ne 'install-and-configure' -or [string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'Hermes Docker target mismatch.'}
if([string]$req.deployment -ne 'docker-desktop' -or [string]$req.status -ne 'ACTIVE'){throw 'Hermes Docker deployment request is not active.'}
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1' -or [string]$req.container_base_url -ne 'http://host.docker.internal:11434/v1'){throw 'Hermes Docker Ollama routing mismatch.'}
if([string]$req.image -ne 'nousresearch/hermes-agent:latest' -or [string]$req.container_name -ne 'hermes-h3'){throw 'Hermes Docker image/container mismatch.'}
if([string]$req.dashboard_host_ip -ne '100.106.186.118' -or [int]$req.dashboard_port -ne 9119){throw 'Hermes Docker dashboard bind mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [string]$req.preferred_model -ne 'qwen3.6:35b-a3b-hermes64k' -or [int]$req.context_length -ne 65536){throw 'Hermes Docker model request mismatch.'}
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
  $json=$o|ConvertTo-Json -Depth 12 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  Write-Output $json
}
if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
    if([bool]$prior.ok -and [string]$prior.deployment -eq 'docker-desktop' -and [string]$prior.classification -eq 'HERMES_READY_LOCAL_OLLAMA_64K'){Save-State $prior;exit 0}
  }catch{}
}
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 SSH path missing: $p"}}

$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$container='hermes-h3'
$image='nousresearch/hermes-agent:latest'
$bindIp='100.106.186.118'
$dashboardPort=9119
$baseModel='qwen3.6:35b-a3b'
$preferredModel='qwen3.6:35b-a3b-hermes64k'
$containerBaseUrl='http://host.docker.internal:11434/v1'
$root=Join-Path $env:LOCALAPPDATA 'HermesDockerDesktop'
$dataRoot=Join-Path $root 'data'
$envPath=Join-Path $dataRoot '.env'
$configPath=Join-Path $dataRoot 'config.yaml'
$credentialPath=Join-Path $root 'desktop-credentials.txt'
$generationTestStarted=$false
$ollamaMutationStarted=$false

function Emit([bool]$ok,[string]$classification,[hashtable]$extra){
  $o=[ordered]@{
    schema=1;ok=$ok;classification=$classification;deployment='docker-desktop';host=$env:COMPUTERNAME
    containerName=$container;image=$image;dashboardUrl=("http://{0}:{1}" -f $bindIp,$dashboardPort)
    credentialsPath=$credentialPath;containerBaseUrl=$containerBaseUrl;generationTestStarted=$generationTestStarted
    ollamaMutationStarted=$ollamaMutationStarted;apiPublished=$false;capturedAt=(Get-Date -Format o)
  }
  foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
  $o|ConvertTo-Json -Depth 8 -Compress
}
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
try{
  $dockerCmd=Get-Command docker.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if(-not $dockerCmd){Emit $false 'HERMES_DOCKER_ENGINE_MISSING' @{retryable=$false;dockerReady=$false};exit 31}
  $docker=[string]$dockerCmd.Source
  $serverVersion=(& $docker version --format '{{.Server.Version}}' 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverVersion)){Emit $false 'HERMES_DOCKER_ENGINE_UNAVAILABLE' @{retryable=$true;dockerReady=$false};exit 32}

  $ipPresent=$false
  try{$ipPresent=[bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Where-Object{$_.IPAddress -eq $bindIp}|Select-Object -First 1)}catch{}
  if(-not $ipPresent){Emit $false 'HERMES_DOCKER_TAILSCALE_IP_MISSING' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion};exit 33}

  $hostOllama=$false;$hostModels=@()
  try{
    $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10
    $hostModels=@($tags.models|ForEach-Object{[string]$_.name});$hostOllama=$true
  }catch{}
  if(-not $hostOllama){Emit $false 'HERMES_DOCKER_HOST_OLLAMA_UNREACHABLE' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion};exit 34}
  $selectedModel=$(if($preferredModel -in $hostModels){$preferredModel}elseif($baseModel -in $hostModels){$baseModel}else{$baseModel})

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
    'HERMES_DASHBOARD=1',
    'HERMES_DASHBOARD_HOST=0.0.0.0',
    'HERMES_DASHBOARD_PORT=9119',
    'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=afz',
    ('HERMES_DASHBOARD_BASIC_AUTH_PASSWORD='+$password),
    ('HERMES_DASHBOARD_BASIC_AUTH_SECRET='+$secret)
  ) -join "`n"
  [IO.File]::WriteAllText($envPath,$envText+"`n",(New-Object Text.UTF8Encoding($false)))
  ProtectFile $envPath

  $config=@"
model:
  default: "$selectedModel"
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
  [IO.File]::WriteAllText($configPath,$config,(New-Object Text.UTF8Encoding($false)))
  $cred="Hermes Desktop H3`r`nURL: http://${bindIp}:9119`r`nUsername: afz`r`nPassword: $password`r`n"
  [IO.File]::WriteAllText($credentialPath,$cred,(New-Object Text.UTF8Encoding($false)))
  ProtectFile $credentialPath

  & $docker pull $image *> $null
  if($LASTEXITCODE -ne 0){Emit $false 'HERMES_DOCKER_IMAGE_PULL_FAILED' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion};exit 35}
  $exists=(& $docker ps -a --filter "name=^/${container}$" --format '{{.Names}}' 2>$null|Out-String).Trim()
  if($exists -eq $container){& $docker rm -f $container *> $null;if($LASTEXITCODE -ne 0){throw 'Could not replace existing Hermes container.'}}

  $runArgs=@(
    'run','-d','--name',$container,'--restart','unless-stopped','--memory=4g','--cpus=2','--shm-size=1g',
    '--env-file',$envPath,'-p',("${bindIp}:9119:9119"),'--mount',("type=bind,source=$dataRoot,target=/opt/data"),
    $image,'gateway','run'
  )
  $cid=(& $docker @runArgs 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cid)){Emit $false 'HERMES_DOCKER_CONTAINER_START_FAILED' @{retryable=$true;dockerReady=$true;dockerServerVersion=$serverVersion};exit 36}

  $status=$null;$statusReachable=$false;$containerRunning=$false
  for($i=0;$i -lt 45;$i++){
    Start-Sleep -Seconds 2
    $running=(& $docker inspect -f '{{.State.Running}}' $container 2>$null|Out-String).Trim().ToLowerInvariant()
    $containerRunning=($running -eq 'true')
    if(-not $containerRunning){break}
    try{
      $sr=(& $docker exec $container curl -fsS 'http://127.0.0.1:9119/api/status' 2>$null|Out-String).Trim()
      if($LASTEXITCODE -eq 0 -and $sr){$status=$sr|ConvertFrom-Json;$statusReachable=$true;break}
    }catch{}
  }
  $authRequired=$false;$basicAuth=$false
  if($statusReachable){
    try{$authRequired=[bool]$status.auth_required}catch{}
    try{$basicAuth=('basic' -in @($status.auth_providers|ForEach-Object{[string]$_}))}catch{}
  }
  $containerOllama=$false;$listedModels=@()
  if($containerRunning){
    try{
      $mr=(& $docker exec $container curl -fsS 'http://host.docker.internal:11434/v1/models' 2>$null|Out-String).Trim()
      if($LASTEXITCODE -eq 0 -and $mr){$mo=$mr|ConvertFrom-Json;$listedModels=@($mo.data|ForEach-Object{[string]$_.id});$containerOllama=$true}
    }catch{}
  }
  $modelListed=($selectedModel -in $listedModels)
  $version=$null
  if($containerRunning){try{$version=(& $docker exec $container hermes version 2>&1|Out-String).Trim()}catch{}}
  $ready=($containerRunning -and $statusReachable -and $authRequired -and $basicAuth -and $containerOllama -and $modelListed)
  $extra=@{
    retryable=(-not $ready);dockerReady=$true;dockerServerVersion=$serverVersion;containerRunning=$containerRunning
    dashboardStatusReachable=$statusReachable;authRequired=$authRequired;basicAuthProvider=$basicAuth
    hostOllamaReachable=$hostOllama;containerOllamaReachable=$containerOllama;selectedModel=$selectedModel;selectedModelListed=$modelListed
    hostModelCount=$hostModels.Count;hermesVersion=$version;resourceMemory='4g';resourceCpus=2;shmSize='1g'
  }
  if($ready){Emit $true 'HERMES_READY_LOCAL_OLLAMA_64K' $extra;exit 0}
  Emit $false 'HERMES_DOCKER_DESKTOP_SETUP_INCOMPLETE' $extra;exit 37
}catch{
  Emit $false 'HERMES_DOCKER_DESKTOP_SETUP_FAILED' @{retryable=$true;error=$_.Exception.Message};exit 75
}
'@

$inFile=Join-Path $env:TEMP ('afz-h3-hermes-docker-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-docker-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-docker-'+[guid]::NewGuid().ToString('n')+'.err')
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','-')
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(240000)){try{$p.Kill()}catch{};throw 'H3 Hermes Docker install exceeded 240 seconds.'}
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
  Save-State ([ordered]@{schema=1;ok=$false;classification='HERMES_DOCKER_DESKTOP_TRANSPORT_FAILED';deployment='docker-desktop';jobId=$id;retryable=$true;error=$_.Exception.Message;generationTestStarted=$false;ollamaMutationStarted=$false;capturedAt=(Get-Date -Format o)})
  exit 75
}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
