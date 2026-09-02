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
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1' -or [string]$req.container_base_url -ne 'http://host.docker.internal:11434/v1'){throw 'H3 Hermes Ollama route mismatch.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b' -or [string]$req.preferred_model -ne 'qwen3.6:35b-a3b-hermes64k' -or [int]$req.context_length -ne 65536){throw 'H3 Hermes model request mismatch.'}
if($req.PSObject.Properties.Name -contains 'qwen_alias'){if([string]$req.qwen_alias -ne 'qwen-h3'){throw 'H3 Hermes Qwen alias mismatch.'}}
if($req.PSObject.Properties.Name -contains 'preserve_existing_default_model'){if(-not [bool]$req.preserve_existing_default_model){throw 'H3 Hermes default-preservation policy mismatch.'}}
if([bool]$req.expose_api -or [bool]$req.run_generation_test -or [bool]$req.mutate_ollama){throw 'H3 Hermes safety flags mismatch.'}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$core=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-HermesAgent-Install.Core.ps1'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-DOCKER-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 SSH path missing: $p"}}

function Save-Result($o){
  $json=$o|ConvertTo-Json -Depth 16 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      $safe=[ordered]@{
        schema=1;purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY';controlPlane='github';source='windows-main';target='h3'
        host=$(if($o.PSObject.Properties.Name -contains 'host'){[string]$o.host}else{$null})
        jobId=$id;ok=[bool]$o.ok;classification=[string]$o.classification
        retryable=$(if($o.PSObject.Properties.Name -contains 'retryable'){[bool]$o.retryable}else{$false})
        deployment=$(if($o.PSObject.Properties.Name -contains 'deployment'){[string]$o.deployment}else{'adaptive'})
        nativeHermesPath=$(if($o.PSObject.Properties.Name -contains 'nativeHermesPath'){[string]$o.nativeHermesPath}else{$null})
        hermesVersion=$(if($o.PSObject.Properties.Name -contains 'hermesVersion'){[string]$o.hermesVersion}else{$null})
        qwenAlias=$(if($o.PSObject.Properties.Name -contains 'qwenAlias'){[string]$o.qwenAlias}else{'qwen-h3'})
        qwenAliasConfigured=$(if($o.PSObject.Properties.Name -contains 'qwenAliasConfigured'){[bool]$o.qwenAliasConfigured}else{$false})
        selectedModel=$(if($o.PSObject.Properties.Name -contains 'selectedModel'){[string]$o.selectedModel}else{$null})
        defaultModelPreserved=$(if($o.PSObject.Properties.Name -contains 'defaultModelPreserved'){[bool]$o.defaultModelPreserved}else{$true})
        hostOllamaReachable=$(if($o.PSObject.Properties.Name -contains 'hostOllamaReachable'){[bool]$o.hostOllamaReachable}else{$false})
        generationTestStarted=$false;ollamaMutationStarted=$false;apiPublished=$false
        observedAt=(Get-Date -Format o)
      }
      [IO.File]::WriteAllText($diagPath,($safe|ConvertTo-Json -Depth 8),$utf8)
    }
  }catch{}
  Write-Output $json
}

# First discover the runtime actually present on H3. This is read-only.
$probe=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
function Emit($o,[int]$code){$o|ConvertTo-Json -Depth 8 -Compress;exit $code}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=$false;classification='HERMES_WRONG_HOST';host=$env:COMPUTERNAME;retryable=$false}) 30}
$dockerReady=$false
try{
  $d=Get-Command docker.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if(-not $d -and (Test-Path -LiteralPath 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' -PathType Leaf)){$d=[pscustomobject]@{Source='C:\Program Files\Docker\Docker\resources\bin\docker.exe'}}
  if($d){$dp=$(if($d.Source){[string]$d.Source}else{[string]$d.Path});$sv=(& $dp version --format '{{.Server.Version}}' 2>$null|Out-String).Trim();$dockerReady=($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sv))}
}catch{$dockerReady=$false}
$candidates=New-Object Collections.Generic.List[string]
foreach($n in @('hermes.exe','hermes')){try{$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){$p=$(if($c.Source){[string]$c.Source}else{[string]$c.Path});if($p){$candidates.Add($p)}}}catch{}}
foreach($p in @(
  (Join-Path $env:LOCALAPPDATA 'AFZ\HermesH3\bin\hermes.exe'),
  (Join-Path $env:USERPROFILE '.hermes\bin\hermes.exe'),
  (Join-Path $env:LOCALAPPDATA 'Hermes\bin\hermes.exe')
)){if(Test-Path -LiteralPath $p -PathType Leaf){$candidates.Add($p)}}
$native=@($candidates|Select-Object -Unique|Select-Object -First 1)
$nativePath=$(if($native.Count){[string]$native[0]}else{$null})
Emit ([ordered]@{ok=$true;classification='HERMES_RUNTIME_DISCOVERED';host=$env:COMPUTERNAME;dockerReady=$dockerReady;nativeHermesPath=$nativePath;nativeHermesPresent=(-not [string]::IsNullOrWhiteSpace($nativePath));retryable=$false}) 0
'@
$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
function Invoke-H3Remote([string]$scriptText,[int]$timeoutMs=60000){
  $inFile=Join-Path $env:TEMP ('afz-h3-hermes-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-hermes-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('afz-h3-hermes-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    [IO.File]::WriteAllText($inFile,$scriptText,$utf8)
    $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit($timeoutMs)){try{$p.Kill()}catch{};return [ordered]@{ok=$false;classification='HERMES_REMOTE_TIMEOUT';retryable=$true;error='H3 remote command timed out.'}}
    $raw=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
    $err=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile).Trim()}else{''})
    $r=$null
    foreach($line in @($raw -split "`r?`n"|Where-Object{$_})){try{$r=$line|ConvertFrom-Json}catch{}}
    if($null -eq $r){return [ordered]@{ok=$false;classification='HERMES_REMOTE_NO_JSON';retryable=$true;error=$(if($err){$err}else{"SSH exit=$($p.ExitCode)"})}}
    return $r
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

$runtime=Invoke-H3Remote $probe 45000
if(-not [bool]$runtime.ok){Save-Result $runtime;exit 75}

# Keep the existing Docker implementation available when Docker is genuinely healthy.
if([bool]$runtime.dockerReady){
  if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "H3 Hermes Docker core missing: $core"}
  $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $core -InstallRoot $InstallRoot -RequestPath $RequestPath 2>&1|Out-String).Trim()
  $code=$LASTEXITCODE;$result=$null
  foreach($line in @($raw -split "`r?`n"|Where-Object{$_})){try{$result=$line|ConvertFrom-Json}catch{}}
  if($null -eq $result){$result=[pscustomobject]@{ok=$false;classification='HERMES_DOCKER_WRAPPER_NO_JSON';deployment='docker-desktop';host=[string]$runtime.host;jobId=$id;retryable=$true;generationTestStarted=$false;ollamaMutationStarted=$false}}
  Save-Result $result
  exit $(if([bool]$result.ok){0}elseif($code -gt 0){$code}else{75})
}

if(-not [bool]$runtime.nativeHermesPresent){
  $r=[pscustomobject]@{ok=$false;classification='HERMES_NATIVE_RUNTIME_NOT_FOUND';deployment='native';host=[string]$runtime.host;jobId=$id;retryable=$false;nativeHermesPath=$null;qwenAlias='qwen-h3';qwenAliasConfigured=$false;defaultModelPreserved=$true;generationTestStarted=$false;ollamaMutationStarted=$false}
  Save-Result $r;exit 41
}

$nativePath=[string]$runtime.nativeHermesPath
$nativeEsc=$nativePath.Replace("'","''")
$native=@"
`$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
`$hermes='$nativeEsc'
`$baseModel='qwen3.6:35b-a3b'
`$preferredModel='qwen3.6:35b-a3b-hermes64k'
`$baseUrl='http://127.0.0.1:11434/v1'
`$alias='qwen-h3'
function Emit(`$o,[int]`$code){`$o|ConvertTo-Json -Depth 8 -Compress;exit `$code}
if(`$env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit ([ordered]@{ok=`$false;classification='HERMES_WRONG_HOST';host=`$env:COMPUTERNAME;retryable=`$false}) 30}
if(-not(Test-Path -LiteralPath `$hermes -PathType Leaf)){Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_RUNTIME_NOT_FOUND';host=`$env:COMPUTERNAME;retryable=`$false;nativeHermesPath=`$hermes}) 41}
try{`$models=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -TimeoutSec 10}catch{Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_OLLAMA_UNREACHABLE';host=`$env:COMPUTERNAME;retryable=`$true;nativeHermesPath=`$hermes;hostOllamaReachable=`$false}) 42}
`$ids=@(`$models.data|ForEach-Object{[string]`$_.id})
`$selected=$(if(`$preferredModel -in `$ids){`$preferredModel}elseif(`$baseModel -in `$ids){`$baseModel}else{`$null})
if([string]::IsNullOrWhiteSpace(`$selected)){Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_QWEN_MODEL_MISSING';host=`$env:COMPUTERNAME;retryable=`$false;nativeHermesPath=`$hermes;hostOllamaReachable=`$true;qwenAlias=`$alias;qwenAliasConfigured=`$false}) 43}
`$before=(& `$hermes config get model --json 2>&1|Out-String).Trim()
`$version=(& `$hermes --version 2>&1|Out-String).Trim()
`$spec=[ordered]@{model=`$selected;provider='custom';base_url=`$baseUrl;api_key='none'}|ConvertTo-Json -Compress
`$set=(& `$hermes config set ("model_aliases.{0}" -f `$alias) `$spec 2>&1|Out-String).Trim()
if(`$LASTEXITCODE -ne 0){Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_QWEN_ALIAS_SET_FAILED';deployment='native';host=`$env:COMPUTERNAME;retryable=`$true;nativeHermesPath=`$hermes;hermesVersion=`$version;hostOllamaReachable=`$true;selectedModel=`$selected;qwenAlias=`$alias;qwenAliasConfigured=`$false;defaultModelPreserved=`$true;error=`$set}) 44}
`$get=(& `$hermes config get ("model_aliases.{0}" -f `$alias) --json 2>&1|Out-String).Trim()
if(`$LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(`$get)){Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_QWEN_ALIAS_VERIFY_FAILED';deployment='native';host=`$env:COMPUTERNAME;retryable=`$true;nativeHermesPath=`$hermes;hermesVersion=`$version;hostOllamaReachable=`$true;selectedModel=`$selected;qwenAlias=`$alias;qwenAliasConfigured=`$false;defaultModelPreserved=`$true;error=`$get}) 45}
try{`$a=`$get|ConvertFrom-Json}catch{Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_QWEN_ALIAS_VERIFY_FAILED';deployment='native';host=`$env:COMPUTERNAME;retryable=`$true;nativeHermesPath=`$hermes;hermesVersion=`$version;hostOllamaReachable=`$true;selectedModel=`$selected;qwenAlias=`$alias;qwenAliasConfigured=`$false;defaultModelPreserved=`$true;error='Alias state was not JSON.'}) 45}
`$after=(& `$hermes config get model --json 2>&1|Out-String).Trim()
`$preserved=(`$before -eq `$after)
`$ok=([string]`$a.model -eq `$selected -and [string]`$a.provider -eq 'custom' -and [string]`$a.base_url -eq `$baseUrl -and `$preserved)
if(-not `$ok){Emit ([ordered]@{ok=`$false;classification='HERMES_NATIVE_QWEN_ALIAS_VERIFY_FAILED';deployment='native';host=`$env:COMPUTERNAME;retryable=`$true;nativeHermesPath=`$hermes;hermesVersion=`$version;hostOllamaReachable=`$true;selectedModel=`$selected;qwenAlias=`$alias;qwenAliasConfigured=`$false;defaultModelPreserved=`$preserved;error='Alias or default-model verification mismatch.'}) 45}
Emit ([ordered]@{ok=`$true;classification='HERMES_NATIVE_QWEN_ALIAS_READY';deployment='native';host=`$env:COMPUTERNAME;retryable=`$false;nativeHermesPath=`$hermes;hermesVersion=`$version;hostOllamaReachable=`$true;selectedModel=`$selected;qwenAlias=`$alias;qwenAliasConfigured=`$true;defaultModelPreserved=`$true;generationTestStarted=`$false;ollamaMutationStarted=`$false;apiPublished=`$false}) 0
"@
$result=Invoke-H3Remote $native 90000
$result|Add-Member -NotePropertyName jobId -NotePropertyValue $id -Force
Save-Result $result
exit $(if([bool]$result.ok){0}else{75})
