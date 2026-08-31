#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$ProgressPreference='SilentlyContinue'

$pin='f50b5bb0fa5b48caef753c790bf0b09a3570918a'
$model='qwen3.5:4b'
$contextLength=65536
$hermesHome=Join-Path $env:LOCALAPPDATA 'hermes'
$installDir=Join-Path $hermesHome 'hermes-agent'
$binDir=Join-Path $hermesHome 'bin'
$config=Join-Path $hermesHome 'config.yaml'
$stateRoot=Join-Path $env:LOCALAPPDATA 'AFZ\Hermes\asus-fallback'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'HERMES-ASUS-FALLBACK-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot,$hermesHome|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
}
function Get-OllamaModelInfo([string]$ModelName){
  $body=@{model=$ModelName}|ConvertTo-Json -Compress
  Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:11434/api/show' -ContentType 'application/json' -Body $body -TimeoutSec 15
}
function Get-ModelContext($Info){
  $best=[int64]0
  if($Info -and $Info.model_info){foreach($p in $Info.model_info.PSObject.Properties){if($p.Name -match '(?i)context_length$'){try{$v=[int64]$p.Value;if($v -gt $best){$best=$v}}catch{}}}}
  $best
}
function Get-Launcher{
  $exe=Join-Path $binDir 'hermes.exe'
  $cmd=Join-Path $binDir 'hermes.cmd'
  if(Test-Path -LiteralPath $exe -PathType Leaf){return $exe}
  if(Test-Path -LiteralPath $cmd -PathType Leaf){return $cmd}
  return $null
}

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){throw "Wrong ASUS host: $env:COMPUTERNAME"}
if(@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{[string]$_.CommandLine -match '(?i)hermes.*gateway'}).Count -gt 0){throw 'Hermes gateway is running; recovery safe-stop.'}
$mi=Get-OllamaModelInfo $model
$modelContext=Get-ModelContext $mi
if($modelContext -lt 64000){throw "Local model context below 64K: $modelContext"}
$models=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -TimeoutSec 10
if($model -notin @($models.data|ForEach-Object{[string]$_.id})){throw 'Required local model is missing.'}
$git=(Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $git){throw 'Git executable missing before recovery.'}
$gp=$(if($git.Path){[string]$git.Path}else{[string]$git.Source})

$existingLauncher=Get-Launcher
$venv=Join-Path $installDir 'venv'
if(Test-Path -LiteralPath $config -PathType Leaf){throw 'Pre-existing Hermes config detected; recovery will not overwrite it.'}
if($existingLauncher){throw "Pre-existing Hermes launcher detected; recovery will not overwrite it: $existingLauncher"}
if(Test-Path -LiteralPath $venv -PathType Container){throw 'Pre-existing Hermes venv detected; recovery will not overwrite it.'}

$backupDir=$null
$stage='preserve-incomplete-install'
try{
  if(Test-Path -LiteralPath $installDir -PathType Container){
    $backupDir=Join-Path $hermesHome ('hermes-agent.incomplete-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    if(Test-Path -LiteralPath $backupDir){throw "Backup path already exists: $backupDir"}
    Move-Item -LiteralPath $installDir -Destination $backupDir
  }

  # The upstream repository contains non-runtime paths that collide by case on
  # a case-insensitive Windows filesystem. Pre-stage only the runtime/source
  # worktree before handing control back to the official installer. The full
  # Git object database and exact commit remain authoritative; only checkout of
  # contributors/ and website/ is omitted.
  $stage='sparse-prestage-clone'
  & $gp clone --no-checkout --filter=blob:none https://github.com/NousResearch/hermes-agent.git $installDir
  if($LASTEXITCODE -ne 0){throw "Sparse pre-stage clone failed exit=$LASTEXITCODE"}
  & $gp -C $installDir config core.sparseCheckout true
  if($LASTEXITCODE -ne 0){throw 'Failed enabling sparse checkout.'}
  & $gp -C $installDir config core.sparseCheckoutCone false
  if($LASTEXITCODE -ne 0){throw 'Failed selecting non-cone sparse checkout.'}
  $sparseFile=Join-Path $installDir '.git\info\sparse-checkout'
  [IO.File]::WriteAllText($sparseFile,"/*`r`n!/contributors/`r`n!/website/`r`n",$utf8)
  & $gp -C $installDir fetch --depth 1 origin $pin
  if($LASTEXITCODE -ne 0){throw "Sparse pre-stage pin fetch failed exit=$LASTEXITCODE"}
  & $gp -C $installDir checkout --detach FETCH_HEAD
  if($LASTEXITCODE -ne 0){throw "Sparse pre-stage pin checkout failed exit=$LASTEXITCODE"}
  $prestageHead=(& $gp -C $installDir rev-parse HEAD 2>$null|Out-String).Trim().ToLowerInvariant()
  if($prestageHead -ne $pin){throw "Sparse pre-stage pin mismatch: $prestageHead"}
  if(Test-Path -LiteralPath (Join-Path $installDir 'contributors')){throw 'contributors tree unexpectedly materialized during sparse pre-stage.'}
  if(Test-Path -LiteralPath (Join-Path $installDir 'website')){throw 'website tree unexpectedly materialized during sparse pre-stage.'}
  $prestageStatus=(& $gp -C $installDir status --porcelain 2>$null|Out-String).Trim()
  if(-not [string]::IsNullOrWhiteSpace($prestageStatus)){throw "Sparse pre-stage worktree is not clean: $prestageStatus"}
  $sparsePrestageVerified=$true

  $stage='official-installer'
  $installer=Join-Path $env:TEMP ('hermes-install-'+[guid]::NewGuid().ToString('n')+'.ps1')
  try{
    $uri=('https://raw.githubusercontent.com/NousResearch/hermes-agent/{0}/scripts/install.ps1' -f $pin)
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $installer -TimeoutSec 120
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -SkipSetup -SkipComputerUse -Commit $pin -ForceCommit -HermesHome $hermesHome -InstallDir $installDir -NonInteractive
    if($LASTEXITCODE -ne 0){throw "Hermes official installer failed exit=$LASTEXITCODE"}
  }finally{Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue}

  $stage='postinstall-verification'
  $launcher=Get-Launcher
  if(-not $launcher){throw 'Neither hermes.exe nor hermes.cmd was staged after official install.'}
  $head=(& $gp -C $installDir rev-parse HEAD 2>$null|Out-String).Trim().ToLowerInvariant()
  if($head -ne $pin){throw "Hermes clean checkout pin mismatch: $head"}
  $version=(& $launcher --version 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)){throw 'Hermes launcher version check failed.'}

  $stage='local-provider-config'
  $templateBackup=$null
  if(Test-Path -LiteralPath $config -PathType Leaf){
    $templateBackup=$config+'.installer-template-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
    Copy-Item -LiteralPath $config -Destination $templateBackup
  }
  $expected=@"
model:
  default: "$model"
  provider: "custom"
  api_key: "ollama"
  base_url: "http://127.0.0.1:11434/v1"
  context_length: $contextLength
"@
  [IO.File]::WriteAllText($config,$expected,$utf8)

  $verify=[IO.File]::ReadAllText($config)
  if($verify -notmatch '(?m)^\s*default:\s*["'']?qwen3[.]5:4b["'']?\s*$' -or $verify -notmatch '(?m)^\s*provider:\s*["'']?custom["'']?\s*$' -or $verify -notmatch [regex]::Escape('http://127.0.0.1:11434/v1') -or $verify -notmatch '(?m)^\s*context_length:\s*65536\s*$'){throw 'ASUS Hermes local config verification failed.'}

  Save-State ([ordered]@{schema=1;ok=$true;status='ready';classification='HERMES_ASUS_FALLBACK_READY_LOCAL_OLLAMA_64K';host=$env:COMPUTERNAME;user=$env:USERNAME;hermesHome=$hermesHome;installDir=$installDir;preservedIncompleteInstall=$backupDir;installerTemplateBackup=$templateBackup;sparsePrestageVerified=$true;sparseExcludedTrees=@('contributors','website');launcher=$launcher;version=$version;commit=$pin;commitVerified=$true;provider='custom';baseUrl='http://127.0.0.1:11434/v1';model=$model;configuredContextLength=$contextLength;modelNativeContext=$modelContext;gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;finishedAt=(Get-Date -Format o)})
  Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
}catch{
  $err=$_.Exception.Message
  Save-State ([ordered]@{schema=1;ok=$false;status='failed';classification='HERMES_ASUS_RECOVERY_FAILED';stage=$stage;host=$env:COMPUTERNAME;user=$env:USERNAME;error=$err;hermesHome=$hermesHome;installDir=$installDir;preservedIncompleteInstall=$backupDir;gatewayStarted=$false;generationTestStarted=$false;ollamaExposureChanged=$false;finishedAt=(Get-Date -Format o)})
  throw
}
