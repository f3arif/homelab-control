#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('start','status')][string]$Action='status',
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){$RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\hermes-asus-fallback-install.json'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "ASUS Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid ASUS Hermes request identity.'}
if([string]$req.action -ne 'install-and-configure' -or [string]$req.status -ne 'active'){throw 'ASUS Hermes request must be active install-and-configure.'}
if([string]$req.target -ne 'windows-main' -or [string]$req.host -ne 'DESKTOP-10SKF0M' -or [string]$req.role -ne 'windows-execution-and-fallback'){throw 'ASUS Hermes target mismatch.'}
if([string]$req.provider -ne 'custom' -or [string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'ASUS Hermes provider must remain local custom Ollama.'}
if([string]$req.model -ne 'qwen3.5:4b' -or [int]$req.context_length -ne 65536 -or [int]$req.required_model_context -ne 64000){throw 'ASUS Hermes model/context mismatch.'}
if([string]$req.hermes_commit -ne 'f50b5bb0fa5b48caef753c790bf0b09a3570918a'){throw 'ASUS Hermes commit pin mismatch.'}
if([string]$req.install_scope -ne 'faiz-user-standard-native-windows'){throw 'ASUS Hermes install scope mismatch.'}
if(-not [bool]$req.skip_interactive_setup -or -not [bool]$req.skip_computer_use){throw 'ASUS Hermes unattended install flags mismatch.'}
if([bool]$req.start_gateway -or [bool]$req.run_generation_test -or [bool]$req.expose_ollama){throw 'ASUS Hermes safety flags mismatch.'}
if([string]$req.control_plane -ne 'github'){throw 'ASUS Hermes control plane must remain GitHub.'}
if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "ASUS Hermes wrong host: $env:COMPUTERNAME"}

$hermesHome=Join-Path $env:LOCALAPPDATA 'hermes'
$installDir=Join-Path $hermesHome 'hermes-agent'
$stateRoot=Join-Path $env:LOCALAPPDATA 'AFZ\Hermes\asus-fallback'
$statePath=Join-Path $stateRoot 'latest.json'
$workerPath=Join-Path $stateRoot 'install-worker.ps1'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'HERMES-ASUS-FALLBACK-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Write-State($o){
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
}
function Read-State{if(Test-Path -LiteralPath $statePath -PathType Leaf){try{return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}};return $null}
function Emit($o){$o|ConvertTo-Json -Depth 20 -Compress|Write-Output}
function Get-OllamaModelInfo([string]$Model){
  $body=@{model=$Model}|ConvertTo-Json -Compress
  return Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:11434/api/show' -ContentType 'application/json' -Body $body -TimeoutSec 15
}
function Get-ModelContext($Info){
  $best=[int64]0
  if($Info -and $Info.model_info){
    foreach($p in $Info.model_info.PSObject.Properties){
      if($p.Name -match '(?i)context_length$'){
        try{$v=[int64]$p.Value;if($v -gt $best){$best=$v}}catch{}
      }
    }
  }
  return $best
}

if($Action -eq 'status'){
  $s=Read-State
  if($s){Emit $s}else{Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_ASUS_NOT_STARTED';jobId=$id;gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;time=(Get-Date -Format o)})}
  exit 0
}

$prior=Read-State
if($prior){
  if([string]$prior.classification -eq 'HERMES_ASUS_FALLBACK_READY_LOCAL_OLLAMA_64K'){Emit $prior;exit 0}
  $pidValue=0;try{$pidValue=[int]$prior.workerPid}catch{}
  if([string]$prior.status -eq 'running' -and $pidValue -gt 0 -and (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)){Emit $prior;exit 0}
}

# Confirm the selected existing model supports the requested operating context.
# Use Ollama's HTTP API rather than `ollama show --json`, which is absent on some
# deployed Ollama builds even though /api/show is available and returns model_info.
$info=Get-OllamaModelInfo 'qwen3.5:4b'
$modelContext=Get-ModelContext $info
if($modelContext -lt [int64]$req.required_model_context){throw "qwen3.5:4b context is below Hermes requirement: $modelContext"}

$pin=[string]$req.hermes_commit
$worker=@'
#Requires -Version 5.1
param(
  [string]$JobId,
  [string]$HermesHome,
  [string]$InstallDir,
  [string]$Pin,
  [string]$Model,
  [int]$ContextLength,
  [string]$StatePath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$ProgressPreference='SilentlyContinue'
$utf8=New-Object Text.UTF8Encoding($false)
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'HERMES-ASUS-FALLBACK-LATEST.json'
function Save($o){
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($StatePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
}
function Get-OllamaModelInfo([string]$ModelName){
  $body=@{model=$ModelName}|ConvertTo-Json -Compress
  return Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:11434/api/show' -ContentType 'application/json' -Body $body -TimeoutSec 15
}
function Get-ModelContext($Info){
  $best=[int64]0
  if($Info -and $Info.model_info){
    foreach($p in $Info.model_info.PSObject.Properties){
      if($p.Name -match '(?i)context_length$'){
        try{$v=[int64]$p.Value;if($v -gt $best){$best=$v}}catch{}
      }
    }
  }
  return $best
}
$started=Get-Date
try{
  $env:HERMES_HOME=$HermesHome
  New-Item -ItemType Directory -Force -Path $HermesHome|Out-Null
  $installer=Join-Path $env:TEMP ('hermes-install-'+[guid]::NewGuid().ToString('n')+'.ps1')
  try{
    $uri=('https://raw.githubusercontent.com/NousResearch/hermes-agent/{0}/scripts/install.ps1' -f $Pin)
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $installer -TimeoutSec 120
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -SkipSetup -SkipComputerUse -Commit $Pin -HermesHome $HermesHome -InstallDir $InstallDir -NonInteractive
    if($LASTEXITCODE -ne 0){throw "Hermes installer failed exit=$LASTEXITCODE"}
  }finally{Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue}

  $launcher=Join-Path $HermesHome 'bin\hermes.exe'
  if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){throw "Hermes launcher missing after install: $launcher"}
  $version=(& $launcher --version 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)){throw 'Hermes version verification failed.'}

  $commitVerified=$false
  $git=(Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1)
  if($git){
    $gp=$(if($git.Path){[string]$git.Path}else{[string]$git.Source})
    $head=(& $gp -C $InstallDir rev-parse HEAD 2>$null|Out-String).Trim().ToLowerInvariant()
    $commitVerified=($head -eq $Pin.ToLowerInvariant())
  }
  if(-not $commitVerified){throw 'Hermes checkout commit verification failed.'}

  $config=Join-Path $HermesHome 'config.yaml'
  $expected=@"
model:
  default: \"$Model\"
  provider: \"custom\"
  api_key: \"ollama\"
  base_url: \"http://127.0.0.1:11434/v1\"
  context_length: $ContextLength
"@
  if(Test-Path -LiteralPath $config -PathType Leaf){
    $existing=[IO.File]::ReadAllText($config)
    $ok=($existing -match '(?m)^\s*default:\s*[\"'']?qwen3[.]5:4b[\"'']?\s*$' -and $existing -match '(?m)^\s*provider:\s*[\"'']?custom[\"'']?\s*$' -and $existing -match [regex]::Escape('http://127.0.0.1:11434/v1') -and $existing -match '(?m)^\s*context_length:\s*65536\s*$')
    if(-not $ok){throw 'Pre-existing Hermes config conflicts with guarded ASUS fallback configuration.'}
  }else{[IO.File]::WriteAllText($config,$expected,$utf8)}

  $mi=Get-OllamaModelInfo $Model
  $modelContext=Get-ModelContext $mi
  if($modelContext -lt 64000){throw "Ollama model context below 64K after install: $modelContext"}
  $models=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -TimeoutSec 10
  $names=@($models.data|ForEach-Object{[string]$_.id})
  if($Model -notin $names){throw "Selected model missing from local OpenAI-compatible endpoint: $Model"}

  Save ([ordered]@{schema=1;ok=$true;status='ready';classification='HERMES_ASUS_FALLBACK_READY_LOCAL_OLLAMA_64K';jobId=$JobId;host=$env:COMPUTERNAME;user=$env:USERNAME;hermesHome=$HermesHome;installDir=$InstallDir;version=$version;commit=$Pin;commitVerified=$true;provider='custom';baseUrl='http://127.0.0.1:11434/v1';model=$Model;configuredContextLength=$ContextLength;modelNativeContext=$modelContext;gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)})
}catch{
  Save ([ordered]@{schema=1;ok=$false;status='failed';classification='HERMES_ASUS_INSTALL_FAILED';jobId=$JobId;host=$env:COMPUTERNAME;user=$env:USERNAME;error=$_.Exception.Message;gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)})
  exit 1
}
'@
[IO.File]::WriteAllText($workerPath,$worker,$utf8)
$args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$workerPath,'-JobId',$id,'-HermesHome',$hermesHome,'-InstallDir',$installDir,'-Pin',$pin,'-Model',[string]$req.model,'-ContextLength',[string][int]$req.context_length,'-StatePath',$statePath)
$p=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
$running=[ordered]@{schema=1;ok=$false;status='running';classification='HERMES_ASUS_INSTALL_STARTED';jobId=$id;host=$env:COMPUTERNAME;user=$env:USERNAME;workerPid=$p.Id;hermesHome=$hermesHome;installDir=$installDir;model=[string]$req.model;modelNativeContext=$modelContext;configuredContextLength=[int]$req.context_length;commit=$pin;gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;startedAt=(Get-Date -Format o)}
Write-State $running
Emit $running
exit 0
