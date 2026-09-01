#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-native-qwen35b.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "H3 native Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid H3 native Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure-native' -or [string]$req.status -ne 'ACTIVE'){throw 'H3 native Hermes request is not active.'}
if([string]$req.target -ne 'h3' -or [string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'H3 native Hermes target mismatch.'}
if([string]$req.provider -ne 'custom' -or [string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'H3 native Hermes provider must remain loopback Ollama.'}
if([string]$req.model -ne 'qwen3.6:35b-a3b' -or [int]$req.context_length -ne 65536){throw 'H3 native Hermes model/context mismatch.'}
if([string]$req.hermes_commit -ne 'f50b5bb0fa5b48caef753c790bf0b09a3570918a'){throw 'H3 native Hermes commit pin mismatch.'}
if([bool]$req.run_generation_test -or [bool]$req.expose_ollama -or [bool]$req.mutate_ollama -or [bool]$req.start_gateway){throw 'H3 native Hermes safety flags mismatch.'}

# Initialize local + mirrored state before transport prerequisite checks so every
# terminal preflight result is observable without exposing key material.
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-native-qwen35b'
$statePath=Join-Path $stateRoot ($id+'.json')
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-H3-HERMES-NATIVE-QWEN35B-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 16
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 16 -Compress)
}

$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$preflight=@(
  [pscustomobject]@{role='system_key';path=$key},
  [pscustomobject]@{role='known_hosts';path=$known},
  [pscustomobject]@{role='ssh_client';path=$ssh}
)
foreach($item in $preflight){
  if(-not(Test-Path -LiteralPath $item.path -PathType Leaf)){
    $r=[ordered]@{schema=1;ok=$false;classification='H3_HERMES_NATIVE_WINDOWS_PREREQ_MISSING';jobId=$id;target='h3';missingRole=[string]$item.role;retryable=$false;generationTestStarted=$false;gatewayStarted=$false;ollamaMutationStarted=$false;ollamaExposed=$false;time=(Get-Date -Format o)}
    Save-State $r;exit 43
  }
}

$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$model='qwen3.6:35b-a3b'
$context=65536
$pin='f50b5bb0fa5b48caef753c790bf0b09a3570918a'
$baseUrl='http://127.0.0.1:11434/v1'
$hermesHome=Join-Path $env:LOCALAPPDATA 'AFZ\HermesH3'
$installDir=Join-Path $hermesHome 'hermes-agent'
$launcher=Join-Path $hermesHome 'bin\hermes.exe'
$config=Join-Path $hermesHome 'config.yaml'
$generationStarted=$false
$gatewayStarted=$false
$ollamaMutation=$false
function Emit([bool]$ok,[string]$classification,[hashtable]$extra,[int]$code){
  $o=[ordered]@{schema=1;ok=$ok;classification=$classification;host=$env:COMPUTERNAME;user=$env:USERNAME;provider='custom';baseUrl=$baseUrl;model=$model;configuredContextLength=$context;generationTestStarted=$false;gatewayStarted=$false;ollamaMutationStarted=$false;ollamaExposed=$false;time=(Get-Date -Format o)}
  foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
  $o|ConvertTo-Json -Depth 10 -Compress
  exit $code
}
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){Emit $false 'H3_HERMES_NATIVE_WRONG_HOST' @{} 30}

# Verify existing Ollama/model without mutation.
try{$tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10}catch{Emit $false 'H3_HERMES_NATIVE_OLLAMA_UNREACHABLE' @{retryable=$true} 31}
$names=@($tags.models|ForEach-Object{[string]$_.name})
if($model -notin $names){Emit $false 'H3_HERMES_NATIVE_MODEL_MISSING' @{retryable=$false;modelListed=$false} 32}
try{
  $show=Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:11434/api/show' -ContentType 'application/json' -Body (@{model=$model}|ConvertTo-Json -Compress) -TimeoutSec 15
}catch{Emit $false 'H3_HERMES_NATIVE_MODEL_INSPECT_FAILED' @{retryable=$true;modelListed=$true} 33}
$nativeContext=[int64]0
if($show.model_info){foreach($p in $show.model_info.PSObject.Properties){if($p.Name -match '(?i)context_length$'){try{$v=[int64]$p.Value;if($v -gt $nativeContext){$nativeContext=$v}}catch{}}}}
if($nativeContext -lt $context){Emit $false 'H3_HERMES_NATIVE_MODEL_CONTEXT_BELOW_64K' @{retryable=$false;modelListed=$true;modelNativeContext=$nativeContext} 34}

# Reuse healthy pinned native Hermes if already present.
$commitVerified=$false
if(Test-Path -LiteralPath $launcher -PathType Leaf){
  $git=Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($git -and (Test-Path -LiteralPath $installDir -PathType Container)){
    $gp=$(if($git.Path){[string]$git.Path}else{[string]$git.Source})
    $head=(& $gp -C $installDir rev-parse HEAD 2>$null|Out-String).Trim().ToLowerInvariant()
    $commitVerified=($head -eq $pin)
  }
}
if(-not $commitVerified){
  New-Item -ItemType Directory -Force -Path $hermesHome|Out-Null
  $installer=Join-Path $env:TEMP ('hermes-h3-install-'+[guid]::NewGuid().ToString('n')+'.ps1')
  try{
    Invoke-WebRequest -UseBasicParsing -Uri ("https://raw.githubusercontent.com/NousResearch/hermes-agent/$pin/scripts/install.ps1") -OutFile $installer -TimeoutSec 120
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -SkipSetup -SkipComputerUse -Commit $pin -HermesHome $hermesHome -InstallDir $installDir -NonInteractive
    if($LASTEXITCODE -ne 0){throw "Hermes installer failed exit=$LASTEXITCODE"}
  }catch{Emit $false 'H3_HERMES_NATIVE_INSTALL_FAILED' @{retryable=$true;modelListed=$true;modelNativeContext=$nativeContext;error=$_.Exception.Message} 35}
  finally{Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue}
}
if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){Emit $false 'H3_HERMES_NATIVE_LAUNCHER_MISSING' @{retryable=$true;modelNativeContext=$nativeContext} 36}

# Configure only this isolated H3 Hermes home; do not modify Ollama or expose its API.
& $launcher config set model.default $model *> $null
if($LASTEXITCODE -ne 0){Emit $false 'H3_HERMES_NATIVE_CONFIG_FAILED' @{stage='model';modelNativeContext=$nativeContext} 37}
& $launcher config set model.provider custom *> $null
if($LASTEXITCODE -ne 0){Emit $false 'H3_HERMES_NATIVE_CONFIG_FAILED' @{stage='provider';modelNativeContext=$nativeContext} 37}
& $launcher config set model.api_key ollama *> $null
if($LASTEXITCODE -ne 0){Emit $false 'H3_HERMES_NATIVE_CONFIG_FAILED' @{stage='api_key';modelNativeContext=$nativeContext} 37}
& $launcher config set model.base_url $baseUrl *> $null
if($LASTEXITCODE -ne 0){Emit $false 'H3_HERMES_NATIVE_CONFIG_FAILED' @{stage='base_url';modelNativeContext=$nativeContext} 37}
& $launcher config set model.context_length ([string]$context) *> $null
if($LASTEXITCODE -ne 0){Emit $false 'H3_HERMES_NATIVE_CONFIG_FAILED' @{stage='context';modelNativeContext=$nativeContext} 37}

$version=(& $launcher --version 2>&1|Out-String).Trim()
if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)){Emit $false 'H3_HERMES_NATIVE_VERSION_FAILED' @{modelNativeContext=$nativeContext} 38}
$cfg=[IO.File]::ReadAllText($config)
$ok=($cfg -match '(?m)^\s*default:\s*["'']?qwen3[.]6:35b-a3b["'']?\s*$' -and $cfg -match '(?m)^\s*provider:\s*["'']?custom["'']?\s*$' -and $cfg.Contains($baseUrl) -and $cfg -match '(?m)^\s*context_length:\s*65536\s*$')
if(-not $ok){Emit $false 'H3_HERMES_NATIVE_CONFIG_VERIFY_FAILED' @{modelNativeContext=$nativeContext;hermesVersion=$version} 39}
Emit $true 'H3_HERMES_NATIVE_QWEN35B_READY' @{retryable=$false;modelListed=$true;modelNativeContext=$nativeContext;hermesVersion=$version;hermesHome=$hermesHome;installDir=$installDir} 0
'@

$bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 native Hermes stdin empty.''};Invoke-Expression $script'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
$inFile=Join-Path $env:TEMP ('afz-h3-hermes-native-'+[guid]::NewGuid().ToString('n')+'.ps1')
$outFile=Join-Path $env:TEMP ('afz-h3-hermes-native-'+[guid]::NewGuid().ToString('n')+'.out')
$errFile=Join-Path $env:TEMP ('afz-h3-hermes-native-'+[guid]::NewGuid().ToString('n')+'.err')
$sshArgs=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
try{
  [IO.File]::WriteAllText($inFile,$remote,$utf8)
  $p=Start-Process -FilePath $ssh -ArgumentList $sshArgs -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
  if(-not $p.WaitForExit(240000)){
    try{$p.Kill()}catch{}
    $r=[ordered]@{schema=1;ok=$false;classification='H3_HERMES_NATIVE_TIMEOUT';jobId=$id;target='h3';retryable=$true;generationTestStarted=$false;gatewayStarted=$false;ollamaMutationStarted=$false;time=(Get-Date -Format o)}
    Save-State $r;exit 40
  }
  $raw=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile).Trim()}else{''})
  $result=$null
  foreach($line in @($raw -split "`r?`n"|Where-Object{$_})){try{$result=$line|ConvertFrom-Json}catch{}}
  if($null -eq $result){
    $r=[ordered]@{schema=1;ok=$false;classification='H3_HERMES_NATIVE_NO_JSON';jobId=$id;target='h3';retryable=$true;sshExit=$p.ExitCode;generationTestStarted=$false;gatewayStarted=$false;ollamaMutationStarted=$false;time=(Get-Date -Format o)}
    Save-State $r;exit 41
  }
  $safe=[ordered]@{schema=1;ok=[bool]$result.ok;classification=[string]$result.classification;jobId=$id;target='h3';host=[string]$result.host;provider=[string]$result.provider;baseUrl=[string]$result.baseUrl;model=[string]$result.model;configuredContextLength=$result.configuredContextLength;modelNativeContext=$result.modelNativeContext;hermesVersion=$result.hermesVersion;retryable=$(if($result.PSObject.Properties.Name -contains 'retryable'){[bool]$result.retryable}else{$false});generationTestStarted=$false;gatewayStarted=$false;ollamaMutationStarted=$false;ollamaExposed=$false;time=(Get-Date -Format o)}
  Save-State $safe
  if(-not $safe.ok){exit 42}
  exit 0
}finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
