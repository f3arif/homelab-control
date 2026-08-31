#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Hermes request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1){throw 'Hermes request schema must be 1.'}
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Hermes request id is invalid.'}
if([string]$req.action -ne 'install-and-configure'){throw 'Hermes request action mismatch.'}
if([string]$req.target -ne 'h3'){throw 'Hermes request target must be h3.'}
if([string]$req.host -ne 'DESKTOP-H3R6CQN'){throw 'Hermes request host mismatch.'}
if([string]$req.provider -ne 'custom'){throw 'Hermes provider must be custom.'}
if([string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){throw 'Hermes base_url must remain H3 loopback Ollama.'}
if([string]$req.base_model -ne 'qwen3.6:35b-a3b'){throw 'Hermes base model mismatch.'}
if([string]$req.hermes_model -ne 'qwen3.6:35b-a3b-hermes64k'){throw 'Hermes model alias mismatch.'}
if([int]$req.context_length -ne 65536){throw 'Hermes context length must be 65536.'}
if([string]$req.hermes_commit -ne 'fc0a10a924ce31a7badd0d7a202dcc0779ef7942'){throw 'Hermes commit pin mismatch.'}

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-agent'
$statePath=Join-Path $stateRoot ($id+'.json')
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$wakeUrl='http://100.91.50.9:8087/wake/h3'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  Write-Output $json
}
function Read-State{
  if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null}
}
function Test-H3Port{
  try{
    $tcp=New-Object Net.Sockets.TcpClient
    try{
      $iar=$tcp.BeginConnect('100.106.186.118',22,$null,$null)
      if(-not $iar.AsyncWaitHandle.WaitOne(2500,$false)){return $false}
      $tcp.EndConnect($iar);return $true
    }finally{$tcp.Dispose()}
  }catch{return $false}
}
function Ensure-H3Awake{
  if(Test-H3Port){return}
  try{Invoke-WebRequest -Uri $wakeUrl -UseBasicParsing -TimeoutSec 10|Out-Null}catch{}
  $deadline=(Get-Date).AddMinutes(3)
  do{Start-Sleep -Seconds 5;if(Test-H3Port){return}}while((Get-Date)-lt $deadline)
  throw 'H3 did not become reachable on SSH after bounded wake attempt.'
}
function Invoke-H3([string]$RemoteScript){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 Hermes stdin was empty.''};Invoke-Expression $script'
  $bootstrapEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $args=@(
    '-i',$key,
    '-o','IdentitiesOnly=yes',
    '-o','BatchMode=yes',
    '-o','ConnectTimeout=8',
    '-o','StrictHostKeyChecking=yes',
    '-o',('UserKnownHostsFile='+$known),
    $target,
    'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$bootstrapEncoded
  )
  $inFile=Join-Path $env:TEMP ('afz-h3-hermes-in-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-hermes-out-'+[guid]::NewGuid().ToString('n')+'.txt')
  $errFile=Join-Path $env:TEMP ('afz-h3-hermes-err-'+[guid]::NewGuid().ToString('n')+'.txt')
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(1200000)){
      try{$p.Kill()}catch{}
      throw 'H3 Hermes install command exceeded the 20-minute bounded execution window.'
    }
    $stdout=$(if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''})
    $stderr=$(if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    return [ordered]@{exit=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr}
  }finally{
    Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
}

$prior=Read-State
if($prior -and [bool]$prior.ok -and [string]$prior.classification -eq 'HERMES_READY_LOCAL_OLLAMA_64K'){
  Save-State $prior
  exit 0
}

foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required H3 transport path missing: $p"}}
Ensure-H3Awake

$remote=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$jobId='__JOB_ID__'
$hermesCommit='fc0a10a924ce31a7badd0d7a202dcc0779ef7942'
$baseModel='qwen3.6:35b-a3b'
$hermesModel='qwen3.6:35b-a3b-hermes64k'
$contextLength=65536
$endpoint='http://127.0.0.1:11434/v1'
$expectedHost='DESKTOP-H3R6CQN'
$utf8=New-Object Text.UTF8Encoding($false)
$hermesHome=Join-Path $env:LOCALAPPDATA 'hermes'
$repo=Join-Path $hermesHome 'hermes-agent'
$launcher=Join-Path $hermesHome 'bin\hermes.exe'
$config=Join-Path $hermesHome 'config.yaml'
$installedNow=$false
$modelCreated=$false
$configUpdated=$false
$published=$false
$selectedModel=$null
$version=$null
$classification=$null
$busyNames=@()

function Find-Ollama{
  $cmd=Get-Command ollama.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($cmd){if($cmd.Source){return [string]$cmd.Source};if($cmd.Path){return [string]$cmd.Path}}
  foreach($p in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
    'C:\Program Files\Ollama\ollama.exe'
  )){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Get-ModelfileContext([string]$Ollama,[string]$Model){
  $txt=(& $Ollama show --modelfile $Model 2>&1|Out-String)
  if($LASTEXITCODE -ne 0){return 0}
  $m=[regex]::Matches($txt,'(?im)^\s*PARAMETER\s+num_ctx\s+(\d+)\s*$')
  if($m.Count -eq 0){return 0}
  return [int]$m[$m.Count-1].Groups[1].Value
}
function Publish-Status($Result){
  try{
    $gh=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $gh){return $false}
    $body="[H3-HERMES] job=$jobId; classification=$($Result.classification); ok=$($Result.ok); hermes=$($Result.version); model=$($Result.model); context=$($Result.contextLength); endpoint=loopback-only; generationTestStarted=false."
    & $gh.Source issue comment 9 --repo f3arif/faiz-homelab --body $body *> $null
    return ($LASTEXITCODE -eq 0)
  }catch{return $false}
}
function Emit($Result,[int]$ExitCode){
  $Result.publishedToGitHub=Publish-Status $Result
  $json=$Result|ConvertTo-Json -Depth 12 -Compress
  Write-Output ('AFZ_HERMES_RESULT_JSON='+$json)
  exit $ExitCode
}

try{
  if($env:COMPUTERNAME -ne $expectedHost){throw "H3 host mismatch: $env:COMPUTERNAME"}

  $busyNames=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {
    $c=[string]$_.CommandLine
    $c -and ($c -match '(?i)Qwen27B|Qwen35B|Qwen38-27B-Website-Benchmark|WebsiteBenchmark|35B.*Website')
  }|ForEach-Object {[string]$_.Name+'#'+[string]$_.ProcessId})

  if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){
    $installerUrl='https://raw.githubusercontent.com/NousResearch/hermes-agent/'+$hermesCommit+'/scripts/install.ps1'
    $installerText=Invoke-RestMethod -Uri $installerUrl -TimeoutSec 60
    if([string]::IsNullOrWhiteSpace([string]$installerText)){throw 'Pinned Hermes installer download was empty.'}
    $installer=[scriptblock]::Create([string]$installerText)
    & $installer -SkipSetup -Commit $hermesCommit
    if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){throw "Hermes launcher missing after install: $launcher"}
    $installedNow=$true
  }

  $version=((& $launcher --version 2>&1|Out-String).Trim())
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)){throw 'hermes --version failed.'}

  if($busyNames.Count -gt 0){
    $classification='HERMES_INSTALLED_CONFIG_DEFERRED_PROTECTED_H3_BUSY'
    Emit ([ordered]@{
      schema=1;ok=$false;retryable=$true;classification=$classification;jobId=$jobId;host=$env:COMPUTERNAME;
      installedNow=$installedNow;version=$version;model=$null;contextLength=$contextLength;baseUrl=$endpoint;
      protectedWorkDetected=$busyNames;generationTestStarted=$false;capturedAt=(Get-Date -Format o)
    }) 75
  }

  $ollama=Find-Ollama
  if(-not $ollama){throw 'Ollama CLI was not found on H3.'}
  $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 15
  $names=@($tags.models|ForEach-Object {[string]$_.name})
  if($baseModel -notin $names){throw "Required H3 base model is not installed: $baseModel"}

  $baseContext=Get-ModelfileContext $ollama $baseModel
  if($baseContext -ge 64000){
    $selectedModel=$baseModel
  }else{
    $aliasPresent=($hermesModel -in $names)
    $aliasContext=$(if($aliasPresent){Get-ModelfileContext $ollama $hermesModel}else{0})
    if(-not $aliasPresent -or $aliasContext -lt 64000){
      $mf=Join-Path $env:TEMP ('afz-hermes-'+[guid]::NewGuid().ToString('n')+'.Modelfile')
      try{
        [IO.File]::WriteAllText($mf,("FROM $baseModel`r`nPARAMETER num_ctx $contextLength`r`n"),$utf8)
        & $ollama create $hermesModel -f $mf *> $null
        if($LASTEXITCODE -ne 0){throw 'ollama create for the Hermes 64K alias failed.'}
      }finally{Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue}
      $modelCreated=$true
    }
    $aliasContext=Get-ModelfileContext $ollama $hermesModel
    if($aliasContext -lt 64000){throw "Hermes Ollama alias context verification failed: $aliasContext"}
    $selectedModel=$hermesModel
  }

  $python=$null
  foreach($p in @(
    (Join-Path $repo 'venv\Scripts\python.exe'),
    (Join-Path $repo '.venv\Scripts\python.exe')
  )){if(Test-Path -LiteralPath $p -PathType Leaf){$python=$p;break}}
  if(-not $python){throw 'Hermes managed Python environment was not found.'}

  New-Item -ItemType Directory -Force -Path $hermesHome|Out-Null
  if(Test-Path -LiteralPath $config -PathType Leaf){
    $backup=$config+'.afz-pre-hermes-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
    Copy-Item -LiteralPath $config -Destination $backup -Force
  }
  $pyFile=Join-Path $env:TEMP ('afz-hermes-config-'+[guid]::NewGuid().ToString('n')+'.py')
  $py=@'
import os
from pathlib import Path
import yaml
p=Path(os.environ['AFZ_HERMES_CONFIG'])
if p.exists():
    raw=p.read_text(encoding='utf-8')
    cfg=yaml.safe_load(raw) if raw.strip() else {}
else:
    cfg={}
if cfg is None:
    cfg={}
if not isinstance(cfg, dict):
    raise SystemExit('config root is not a mapping')
model=cfg.get('model')
if not isinstance(model, dict):
    model={}
model['default']=os.environ['AFZ_HERMES_MODEL']
model['provider']='custom'
model['base_url']=os.environ['AFZ_HERMES_BASE_URL']
model['api_key']='ollama'
model['context_length']=int(os.environ['AFZ_HERMES_CONTEXT'])
cfg['model']=model
p.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding='utf-8')
'@
  try{
    [IO.File]::WriteAllText($pyFile,$py,$utf8)
    $env:AFZ_HERMES_CONFIG=$config
    $env:AFZ_HERMES_MODEL=$selectedModel
    $env:AFZ_HERMES_BASE_URL=$endpoint
    $env:AFZ_HERMES_CONTEXT=[string]$contextLength
    & $python $pyFile
    if($LASTEXITCODE -ne 0){throw 'Hermes config YAML update failed.'}
  }finally{
    Remove-Item -LiteralPath $pyFile -Force -ErrorAction SilentlyContinue
    Remove-Item Env:AFZ_HERMES_CONFIG,Env:AFZ_HERMES_MODEL,Env:AFZ_HERMES_BASE_URL,Env:AFZ_HERMES_CONTEXT -ErrorAction SilentlyContinue
  }
  $configUpdated=$true

  $models=Invoke-RestMethod -Uri ($endpoint+'/models') -TimeoutSec 15
  $modelIds=@($models.data|ForEach-Object {[string]$_.id})
  if($selectedModel -notin $modelIds){throw "Configured Hermes model is not visible through Ollama OpenAI API: $selectedModel"}

  $classification='HERMES_READY_LOCAL_OLLAMA_64K'
  Emit ([ordered]@{
    schema=1;ok=$true;retryable=$false;classification=$classification;jobId=$jobId;host=$env:COMPUTERNAME;
    installedNow=$installedNow;version=$version;model=$selectedModel;baseModel=$baseModel;modelAliasCreated=$modelCreated;
    contextLength=$contextLength;baseUrl=$endpoint;configPath=$config;configUpdated=$configUpdated;
    protectedWorkDetected=@();generationTestStarted=$false;capturedAt=(Get-Date -Format o)
  }) 0
}catch{
  $msg=$_.Exception.Message
  Emit ([ordered]@{
    schema=1;ok=$false;retryable=$false;classification='HERMES_SETUP_FAILED';jobId=$jobId;host=$env:COMPUTERNAME;
    installedNow=$installedNow;version=$version;model=$selectedModel;contextLength=$contextLength;baseUrl=$endpoint;
    error=$msg;generationTestStarted=$false;capturedAt=(Get-Date -Format o)
  }) 1
}
'@
$remote=$remote.Replace('__JOB_ID__',$id)

try{
  $run=Invoke-H3 $remote
  $marker=@(([string]$run.stdout -split "`r?`n")|Where-Object {$_.StartsWith('AFZ_HERMES_RESULT_JSON=')}|Select-Object -Last 1)
  if($marker.Count -eq 0){
    throw "H3 Hermes runner returned no result marker. exit=$($run.exit) stderr=$(([string]$run.stderr).Trim())"
  }
  $result=$marker[0].Substring('AFZ_HERMES_RESULT_JSON='.Length)|ConvertFrom-Json
  Save-State $result
  if([bool]$result.ok){exit 0}
  if([bool]$result.retryable){exit 75}
  exit 1
}catch{
  $o=[ordered]@{schema=1;ok=$false;retryable=$true;classification='HERMES_TRANSPORT_FAILED';jobId=$id;host='H3';error=$_.Exception.Message;capturedAt=(Get-Date -Format o)}
  Save-State $o
  exit 75
}
