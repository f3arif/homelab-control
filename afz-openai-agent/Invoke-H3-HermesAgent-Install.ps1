#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 Hermes request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 Hermes target mismatch.'}
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'H3 Hermes host Ollama route mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [int]$req.context_length -ne 65536){throw 'H3 Hermes model request mismatch.'}
if($req.PSObject.Properties.Name -contains 'provider_name'){if([string]$req.provider_name -ne 'ollama'){throw 'H3 Hermes provider mismatch.'}}
if($req.PSObject.Properties.Name -contains 'preserve_existing_default_model'){if(-not [bool]$req.preserve_existing_default_model){throw 'H3 Hermes default-preservation policy mismatch.'}}
if([bool]$req.expose_api -or [bool]$req.run_generation_test -or [bool]$req.mutate_ollama){throw 'H3 Hermes safety flags mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-DOCKER-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 SSH path missing: $p"}}

function Save-Result($o){
  $json=$o|ConvertTo-Json -Depth 18 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      $safe=[ordered]@{
        schema=1
        purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
        controlPlane='github'
        source='windows-main'
        target='h3'
        host=$(if($o.PSObject.Properties.Name -contains 'host'){[string]$o.host}else{$null})
        jobId=$id
        ok=[bool]$o.ok
        classification=[string]$o.classification
        retryable=$(if($o.PSObject.Properties.Name -contains 'retryable'){[bool]$o.retryable}else{$false})
        deployment='native'
        nativeHermesPath=$(if($o.PSObject.Properties.Name -contains 'nativeHermesPath'){[string]$o.nativeHermesPath}else{$null})
        hermesVersion=$(if($o.PSObject.Properties.Name -contains 'hermesVersion'){[string]$o.hermesVersion}else{$null})
        activeProfile=$(if($o.PSObject.Properties.Name -contains 'activeProfile'){[string]$o.activeProfile}else{$null})
        targetHermesHome=$(if($o.PSObject.Properties.Name -contains 'targetHermesHome'){[string]$o.targetHermesHome}else{$null})
        targetConfigPath=$(if($o.PSObject.Properties.Name -contains 'targetConfigPath'){[string]$o.targetConfigPath}else{$null})
        providerName='ollama'
        providerConfigured=$(if($o.PSObject.Properties.Name -contains 'providerConfigured'){[bool]$o.providerConfigured}else{$false})
        selectedModel=$(if($o.PSObject.Properties.Name -contains 'selectedModel'){[string]$o.selectedModel}else{$null})
        priorModelProvider=$(if($o.PSObject.Properties.Name -contains 'priorModelProvider'){[string]$o.priorModelProvider}else{$null})
        finalModelProvider=$(if($o.PSObject.Properties.Name -contains 'finalModelProvider'){[string]$o.finalModelProvider}else{$null})
        defaultModelPreserved=$(if($o.PSObject.Properties.Name -contains 'defaultModelPreserved'){[bool]$o.defaultModelPreserved}else{$true})
        activationFallbackApplied=$(if($o.PSObject.Properties.Name -contains 'activationFallbackApplied'){[bool]$o.activationFallbackApplied}else{$false})
        hostOllamaReachable=$(if($o.PSObject.Properties.Name -contains 'hostOllamaReachable'){[bool]$o.hostOllamaReachable}else{$false})
        error=$(if($o.PSObject.Properties.Name -contains 'error'){[string]$o.error}else{$null})
        generationTestStarted=$false
        ollamaMutationStarted=$false
        apiPublished=$false
        observedAt=(Get-Date -Format o)
      }
      [IO.File]::WriteAllText($diagPath,($safe|ConvertTo-Json -Depth 10),$utf8)
    }
  }catch{}
  Write-Output $json
}

$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$baseModel='qwen3.6:35b-a3b'
$preferredModel='qwen3.6:35b-a3b-hermes64k'
$baseUrl='http://127.0.0.1:11434/v1'
$provider='ollama'
$context=65536
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 14 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_WRONG_HOST';host=$env:COMPUTERNAME;retryable=$false}) 30}

$hermesRoot=Join-Path $env:LOCALAPPDATA 'hermes'
$hermesPath=Join-Path $hermesRoot 'bin\hermes.exe'
if(-not(Test-Path -LiteralPath $hermesPath -PathType Leaf)){
  $cmd=Get-Command hermes.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($cmd){$hermesPath=$(if($cmd.Source){[string]$cmd.Source}else{[string]$cmd.Path})}
}
if(-not(Test-Path -LiteralPath $hermesPath -PathType Leaf)){Emit ([ordered]@{ok=$false;classification='HERMES_NATIVE_RUNTIME_NOT_FOUND';deployment='native';host=$env:COMPUTERNAME;retryable=$false;nativeHermesPath=$hermesPath;providerConfigured=$false;hostOllamaReachable=$false}) 41}

$activeProfile='default'
$activeFile=Join-Path $hermesRoot 'active_profile'
if(Test-Path -LiteralPath $activeFile -PathType Leaf){
  try{
    $candidate=([string](Get-Content -LiteralPath $activeFile -Raw -Encoding UTF8)).Trim().ToLowerInvariant()
    if($candidate -match '^[a-z0-9][a-z0-9_-]{0,63}$'){$activeProfile=$candidate}
  }catch{}
}
$targetHome=$hermesRoot
if($activeProfile -ne 'default'){$targetHome=Join-Path (Join-Path $hermesRoot 'profiles') $activeProfile}
if(-not(Test-Path -LiteralPath $targetHome -PathType Container)){Emit ([ordered]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_HOME_MISSING';deployment='native';host=$env:COMPUTERNAME;retryable=$false;nativeHermesPath=$hermesPath;activeProfile=$activeProfile;targetHermesHome=$targetHome;providerConfigured=$false;hostOllamaReachable=$false}) 42}
$targetConfig=Join-Path $targetHome 'config.yaml'

try{$models=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -TimeoutSec 10}catch{Emit ([ordered]@{ok=$false;classification='HERMES_NATIVE_OLLAMA_UNREACHABLE';deployment='native';host=$env:COMPUTERNAME;retryable=$true;nativeHermesPath=$hermesPath;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;providerConfigured=$false;hostOllamaReachable=$false;error=$_.Exception.Message}) 43}
$ids=@($models.data|ForEach-Object{[string]$_.id})
$selected=$null
if($preferredModel -in $ids){$selected=$preferredModel}elseif($baseModel -in $ids){$selected=$baseModel}
if([string]::IsNullOrWhiteSpace($selected)){Emit ([ordered]@{ok=$false;classification='HERMES_NATIVE_QWEN_MODEL_MISSING';deployment='native';host=$env:COMPUTERNAME;retryable=$false;nativeHermesPath=$hermesPath;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;providerConfigured=$false;hostOllamaReachable=$true;ollamaModelCount=$ids.Count}) 44}

$oldHome=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$targetHome
  $version=(& $hermesPath --version 2>&1|Out-String).Trim()

  function Get-ConfigValue([string]$path){
    $raw=(& $hermesPath config get $path --json 2>&1|Out-String).Trim()
    if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)){return $raw}
    $raw=(& $hermesPath config get $path 2>&1|Out-String).Trim()
    if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)){return $raw}
    return $null
  }

  $modelBefore=Get-ConfigValue 'model'
  $priorProvider=''
  $priorDefault=''
  if($modelBefore){
    try{
      $mb=$modelBefore|ConvertFrom-Json
      if($mb.PSObject.Properties.Name -contains 'provider'){$priorProvider=[string]$mb.provider}
      if($mb.PSObject.Properties.Name -contains 'default'){$priorDefault=[string]$mb.default}
    }catch{}
  }

  $modelMap=[ordered]@{}
  $modelMap[$selected]=[ordered]@{context_length=$context}
  $providerSpec=[ordered]@{
    name='H3 Ollama'
    base_url=$baseUrl
    api_mode='chat_completions'
    discover_models=$false
    models=$modelMap
  }|ConvertTo-Json -Depth 8 -Compress

  $setProvider=(& $hermesPath config set 'providers.ollama' $providerSpec 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_PROVIDER_SET_FAILED';deployment='native';host=$env:COMPUTERNAME;retryable=$true;nativeHermesPath=$hermesPath;hermesVersion=$version;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;selectedModel=$selected;providerConfigured=$false;hostOllamaReachable=$true;priorModelProvider=$priorProvider;error=$setProvider}) 45}

  $activationFallback=$false
  if([string]::IsNullOrWhiteSpace($priorProvider) -or $priorProvider -eq 'auto'){
    $setModelProvider=(& $hermesPath config set 'model.provider' $provider 2>&1|Out-String).Trim()
    if($LASTEXITCODE -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_MODEL_PROVIDER_SET_FAILED';deployment='native';host=$env:COMPUTERNAME;retryable=$true;nativeHermesPath=$hermesPath;hermesVersion=$version;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;selectedModel=$selected;providerConfigured=$true;hostOllamaReachable=$true;priorModelProvider=$priorProvider;error=$setModelProvider}) 46}
    $setModelDefault=(& $hermesPath config set 'model.default' $selected 2>&1|Out-String).Trim()
    if($LASTEXITCODE -ne 0){Emit ([ordered]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_MODEL_DEFAULT_SET_FAILED';deployment='native';host=$env:COMPUTERNAME;retryable=$true;nativeHermesPath=$hermesPath;hermesVersion=$version;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;selectedModel=$selected;providerConfigured=$true;hostOllamaReachable=$true;priorModelProvider=$priorProvider;error=$setModelDefault}) 47}
    $activationFallback=$true
  }

  $providerAfter=Get-ConfigValue 'providers.ollama'
  $modelAfter=Get-ConfigValue 'model'
  $finalProvider=''
  $finalDefault=''
  if($modelAfter){
    try{
      $ma=$modelAfter|ConvertFrom-Json
      if($ma.PSObject.Properties.Name -contains 'provider'){$finalProvider=[string]$ma.provider}
      if($ma.PSObject.Properties.Name -contains 'default'){$finalDefault=[string]$ma.default}
    }catch{}
  }
  $providerOk=($providerAfter -match [regex]::Escape($baseUrl) -and $providerAfter -match [regex]::Escape($selected) -and $providerAfter -match '65536')
  $defaultPreserved=$true
  if(-not $activationFallback -and $priorDefault){$defaultPreserved=($finalDefault -eq $priorDefault)}
  $routeReady=(-not [string]::IsNullOrWhiteSpace($finalProvider) -and $finalProvider -ne 'auto')
  if(-not($providerOk -and $defaultPreserved -and $routeReady)){
    Emit ([ordered]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_PROVIDER_VERIFY_FAILED';deployment='native';host=$env:COMPUTERNAME;retryable=$true;nativeHermesPath=$hermesPath;hermesVersion=$version;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;selectedModel=$selected;providerConfigured=$providerOk;priorModelProvider=$priorProvider;finalModelProvider=$finalProvider;defaultModelPreserved=$defaultPreserved;activationFallbackApplied=$activationFallback;hostOllamaReachable=$true;error='Active-profile provider or model route verification mismatch.'}) 48
  }

  Emit ([ordered]@{ok=$true;classification='HERMES_DESKTOP_ACTIVE_PROFILE_OLLAMA_READY';deployment='native';host=$env:COMPUTERNAME;retryable=$false;nativeHermesPath=$hermesPath;hermesVersion=$version;activeProfile=$activeProfile;targetHermesHome=$targetHome;targetConfigPath=$targetConfig;providerName=$provider;providerConfigured=$true;selectedModel=$selected;priorModelProvider=$priorProvider;finalModelProvider=$finalProvider;defaultModelPreserved=$defaultPreserved;activationFallbackApplied=$activationFallback;hostOllamaReachable=$true;generationTestStarted=$false;ollamaMutationStarted=$false;apiPublished=$false}) 0
}finally{
  if($null -eq $oldHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHome}
}
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$inFile=Join-Path $env:TEMP ('afz-h3-hermes-active-profile-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-active-profile-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-active-profile-'+[guid]::NewGuid().ToString('n')+'.err')
$args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(120000)){try{$p.Kill()}catch{};Save-Result ([pscustomobject]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_REMOTE_TIMEOUT';deployment='native';host='DESKTOP-H3R6CQN';retryable=$true;providerConfigured=$false;hostOllamaReachable=$false;error='H3 Hermes active-profile registration exceeded 120 seconds.'});exit 75}
  $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
  $result=$null
  foreach($line in @($stdout -split "`r?`n"|Where-Object{$_})){try{$result=$line|ConvertFrom-Json}catch{}}
  if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_REMOTE_NO_JSON';deployment='native';host='DESKTOP-H3R6CQN';retryable=$true;providerConfigured=$false;hostOllamaReachable=$false;error=$(if($stderr){$stderr}else{"SSH exit=$($p.ExitCode)"})}}
  $result|Add-Member -NotePropertyName jobId -NotePropertyValue $id -Force
  Save-Result $result
  if([bool]$result.ok){exit 0}
  exit 75
}catch{
  Save-Result ([pscustomobject]@{ok=$false;classification='HERMES_ACTIVE_PROFILE_WRAPPER_EXCEPTION';deployment='native';host='DESKTOP-H3R6CQN';retryable=$true;providerConfigured=$false;hostOllamaReachable=$false;error=$_.Exception.Message})
  exit 75
}finally{
  Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
}
