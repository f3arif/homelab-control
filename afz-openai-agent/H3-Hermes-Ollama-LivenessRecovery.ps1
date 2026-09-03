#Requires -Version 5.1
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

$model='qwen3.6:35b-a3b'
$baseUrl='http://127.0.0.1:11434/v1'
$nativeUrl='http://127.0.0.1:11434'
$hermesRoot=Join-Path $env:LOCALAPPDATA 'hermes'
$hermes=Join-Path $hermesRoot 'bin\hermes.exe'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-H3-HERMES-OLLAMA-LIVENESS-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)

function Save-And-Emit($o,[int]$code){
  $json=$o|ConvertTo-Json -Depth 14
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){[IO.File]::WriteAllText($diagPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 14 -Compress)
  exit $code
}
function Test-OllamaModels {
  try{
    $r=Invoke-RestMethod -Uri ($baseUrl+'/models') -Method Get -TimeoutSec 8
    $ids=@($r.data|ForEach-Object{[string]$_.id})
    return [ordered]@{reachable=$true;modelListed=($model -in $ids);modelCount=$ids.Count}
  }catch{
    return [ordered]@{reachable=$false;modelListed=$false;modelCount=0;errorType=$_.Exception.GetType().Name}
  }
}
function Find-OllamaExe {
  $c=Get-Command ollama.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Path){return [string]$c.Path};if($c.Source){return [string]$c.Source}}
  foreach($p in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
    (Join-Path $env:LOCALAPPDATA 'Ollama\ollama.exe'),
    'C:\Program Files\Ollama\ollama.exe'
  )){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
  return $null
}
function Get-GatewayProcesses {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{
    ([string]$_.Name) -match '(?i)python|hermes' -and
    ([string]$_.CommandLine) -match '(?i)hermes_cli[.]main' -and
    ([string]$_.CommandLine) -match '(?i)gateway\s+run'
  })
}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_RECOVERY_WRONG_HOST';host=$env:COMPUTERNAME;mutation='NONE';observedAt=(Get-Date -Format o)}) 30
}
if(-not(Test-Path -LiteralPath $hermes -PathType Leaf)){
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_RECOVERY_HERMES_MISSING';host=$env:COMPUTERNAME;mutation='NONE';observedAt=(Get-Date -Format o)}) 31
}

$before=Test-OllamaModels
$ollamaStarted=$false
$ollamaExe=$null
$ollamaPid=$null
if(-not [bool]$before.reachable){
  $ollamaExe=Find-OllamaExe
  if([string]::IsNullOrWhiteSpace($ollamaExe)){
    Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_EXECUTABLE_NOT_FOUND';host=$env:COMPUTERNAME;endpointReachableBefore=$false;mutation='NONE';observedAt=(Get-Date -Format o)}) 32
  }
  try{
    $p=Start-Process -FilePath $ollamaExe -ArgumentList @('serve') -WindowStyle Hidden -PassThru
    $ollamaPid=[int]$p.Id
    $ollamaStarted=$true
  }catch{
    Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_START_FAILED';host=$env:COMPUTERNAME;endpointReachableBefore=$false;ollamaExe=$ollamaExe;errorType=$_.Exception.GetType().Name;mutation='OLLAMA_SERVER_START_ATTEMPTED';observedAt=(Get-Date -Format o)}) 33
  }
}

$live=$before
if(-not [bool]$live.reachable){
  for($i=0;$i -lt 45;$i++){
    Start-Sleep -Seconds 2
    $live=Test-OllamaModels
    if([bool]$live.reachable){break}
  }
}
if(-not [bool]$live.reachable){
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_ENDPOINT_STILL_UNREACHABLE';host=$env:COMPUTERNAME;endpointReachableBefore=[bool]$before.reachable;ollamaServerStarted=$ollamaStarted;ollamaPid=$ollamaPid;mutation=$(if($ollamaStarted){'OLLAMA_SERVER_START'}else{'NONE'});observedAt=(Get-Date -Format o)}) 34
}
if(-not [bool]$live.modelListed){
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_MODEL_NOT_LISTED';host=$env:COMPUTERNAME;endpointReachable=$true;model=$model;modelCount=[int]$live.modelCount;ollamaServerStarted=$ollamaStarted;ollamaPid=$ollamaPid;modelPullStarted=$false;mutation=$(if($ollamaStarted){'OLLAMA_SERVER_START'}else{'NONE'});observedAt=(Get-Date -Format o)}) 35
}

# HERMES_R35_MODEL_RUNTIME_CONFIG
# Telegram resolves the main model from config.yaml's top-level model block.
# Provider-registry health and a raw REST canary do not prove that runtime route.
$modelConfigBefore=$null
$modelConfigAfter=$null
$modelConfigChanged=$false
$oldHomeCfg=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$hermesRoot
  try{$modelConfigBefore=((& $hermes config get model --json 2>&1|Out-String).Trim())}catch{}
  foreach($setting in @(
    @('model.default',$model),
    @('model.provider','custom'),
    @('model.base_url',$baseUrl),
    @('model.context_length','65536'),
    @('model.api_mode','chat_completions')
  )){
    & $hermes config set $setting[0] $setting[1] *> $null
    if($LASTEXITCODE -ne 0){throw ('config set failed: '+$setting[0])}
  }
  $modelConfigAfter=((& $hermes config get model --json 2>&1|Out-String).Trim())
  if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($modelConfigAfter)){throw 'model readback failed'}
  $mc=$modelConfigAfter|ConvertFrom-Json
  if([string]$mc.default -ne $model -or [string]$mc.provider -ne 'custom' -or ([string]$mc.base_url).TrimEnd('/') -ne $baseUrl.TrimEnd('/') -or [int]$mc.context_length -ne 65536 -or [string]$mc.api_mode -ne 'chat_completions'){
    throw 'model runtime readback mismatch'
  }
  $modelConfigChanged=($modelConfigBefore -ne $modelConfigAfter)
}catch{
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_MAIN_MODEL_RUNTIME_CONFIG_FAILED';host=$env:COMPUTERNAME;model=$model;baseUrl=$baseUrl;modelConfigChanged=$modelConfigChanged;error=$_.Exception.Message;observedAt=(Get-Date -Format o)}) 38
}finally{
  if($null -eq $oldHomeCfg){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHomeCfg}
}

# Prove and pre-warm the exact OpenAI-compatible chat path Hermes uses.
$canaryOk=$false
$canarySeconds=$null
$canaryErrorType=$null
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
  $body=[ordered]@{
    model=$model
    messages=@([ordered]@{role='user';content='Reply only OK'})
    stream=$false
    max_tokens=2
    temperature=0
  }|ConvertTo-Json -Depth 6 -Compress
  $cr=Invoke-RestMethod -Uri ($baseUrl+'/chat/completions') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 240
  $canaryOk=($null -ne $cr -and @($cr.choices).Count -gt 0)
}catch{$canaryErrorType=$_.Exception.GetType().Name}
finally{$sw.Stop();$canarySeconds=[math]::Round($sw.Elapsed.TotalSeconds,2)}
if(-not $canaryOk){
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_OLLAMA_CHAT_CANARY_FAILED';host=$env:COMPUTERNAME;endpointReachable=$true;modelListed=$true;model=$model;ollamaServerStarted=$ollamaStarted;ollamaPid=$ollamaPid;chatCanaryIssued=$true;chatCanarySeconds=$canarySeconds;chatCanaryErrorType=$canaryErrorType;modelPullStarted=$false;mutation=$(if($ollamaStarted){'OLLAMA_SERVER_START_AND_CHAT_CANARY'}else{'CHAT_CANARY_ONLY'});observedAt=(Get-Date -Format o)}) 36
}

# HERMES_R35_HERMES_CLI_CANARY
# Prove Hermes itself resolves the configured default model to Ollama.
$hermesCliCanaryPassed=$false
$hermesCliCanaryExit=$null
$hermesCliCanarySeconds=$null
$hermesCliCanaryTimedOut=$false
$hermesCliOutFile=Join-Path $env:TEMP ('hermes-r35-cli-'+[guid]::NewGuid().ToString('n')+'.out')
$hermesCliErrFile=Join-Path $env:TEMP ('hermes-r35-cli-'+[guid]::NewGuid().ToString('n')+'.err')
$oldHomeCli=$env:HERMES_HOME
$swCli=[Diagnostics.Stopwatch]::StartNew()
try{
  $env:HERMES_HOME=$hermesRoot
  $cp=Start-Process -FilePath $hermes -ArgumentList @('chat','-q','ping') -RedirectStandardOutput $hermesCliOutFile -RedirectStandardError $hermesCliErrFile -PassThru -WindowStyle Hidden
  $hermesCliCanaryTimedOut=(-not $cp.WaitForExit(300000))
  if($hermesCliCanaryTimedOut){try{$cp.Kill()}catch{};try{$cp.WaitForExit()}catch{}}
  if(-not $hermesCliCanaryTimedOut){$hermesCliCanaryExit=[int]$cp.ExitCode;$hermesCliCanaryPassed=($hermesCliCanaryExit -eq 0)}
}finally{
  $swCli.Stop();$hermesCliCanarySeconds=[math]::Round($swCli.Elapsed.TotalSeconds,2)
  if($null -eq $oldHomeCli){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHomeCli}
}
if(-not $hermesCliCanaryPassed){
  $cliErr=''
  try{$cliErr=[IO.File]::ReadAllText($hermesCliErrFile)}catch{}
  $cliErr=[regex]::Replace($cliErr,'\b\d{7,12}:[A-Za-z0-9_-]{20,}\b','<REDACTED_TELEGRAM_TOKEN>')
  if($cliErr.Length -gt 1600){$cliErr=$cliErr.Substring($cliErr.Length-1600)}
  Remove-Item $hermesCliOutFile,$hermesCliErrFile -Force -ErrorAction SilentlyContinue
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_MAIN_RUNTIME_CLI_CANARY_FAILED';host=$env:COMPUTERNAME;endpointReachable=$true;modelListed=$true;chatCanaryPassed=$true;hermesCliCanaryPassed=$false;hermesCliCanaryTimedOut=$hermesCliCanaryTimedOut;hermesCliCanaryExit=$hermesCliCanaryExit;hermesCliCanarySeconds=$hermesCliCanarySeconds;errorTail=$cliErr;modelConfigChanged=$modelConfigChanged;observedAt=(Get-Date -Format o)}) 39
}
Remove-Item $hermesCliOutFile,$hermesCliErrFile -Force -ErrorAction SilentlyContinue

# Refresh Telegram gateway only after the exact model route has answered.
$beforeGateway=@(Get-GatewayProcesses)
$beforePids=@($beforeGateway|ForEach-Object{[int]$_.ProcessId})
$oldHome=$env:HERMES_HOME
$lifecycle=$(if($beforeGateway.Count -gt 0){'restart'}else{'start'})
$lifecycleExit=$null
try{
  $env:HERMES_HOME=$hermesRoot
  if($lifecycle -eq 'restart'){
    & $hermes gateway restart *> $null
  }else{
    & $hermes gateway start *> $null
  }
  $lifecycleExit=$LASTEXITCODE
}finally{
  if($null -eq $oldHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHome}
}

$afterGateway=@()
for($i=0;$i -lt 30;$i++){
  Start-Sleep -Seconds 1
  $afterGateway=@(Get-GatewayProcesses)
  if($afterGateway.Count -gt 0){break}
}
$afterPids=@($afterGateway|ForEach-Object{[int]$_.ProcessId})
if($afterGateway.Count -eq 0){
  Save-And-Emit ([ordered]@{schema=1;ok=$false;classification='HERMES_MODEL_READY_GATEWAY_NOT_RUNNING';host=$env:COMPUTERNAME;endpointReachable=$true;modelListed=$true;chatCanaryPassed=$true;chatCanarySeconds=$canarySeconds;ollamaServerStarted=$ollamaStarted;ollamaPid=$ollamaPid;gatewayLifecycle=$lifecycle;gatewayLifecycleExit=$lifecycleExit;beforeGatewayPids=$beforePids;afterGatewayPids=$afterPids;modelPullStarted=$false;providerChanged=$false;networkChanged=$false;observedAt=(Get-Date -Format o)}) 37
}

Save-And-Emit ([ordered]@{
  schema=1
  ok=$true
  classification='HERMES_OLLAMA_CHAT_AND_TELEGRAM_GATEWAY_READY'
  host=$env:COMPUTERNAME
  model=$model
  baseUrl=$baseUrl
  endpointReachableBefore=[bool]$before.reachable
  endpointReachableAfter=$true
  modelListed=$true
  modelCount=[int]$live.modelCount
  ollamaServerStarted=$ollamaStarted
  ollamaPid=$ollamaPid
  chatCanaryIssued=$true
  chatCanaryPassed=$true
  chatCanarySeconds=$canarySeconds
  hermesCliCanaryPassed=$hermesCliCanaryPassed
  hermesCliCanaryExit=$hermesCliCanaryExit
  hermesCliCanarySeconds=$hermesCliCanarySeconds
  modelRuntimeConfigured=$true
  modelConfigChanged=$modelConfigChanged
  gatewayLifecycle=$lifecycle
  gatewayLifecycleExit=$lifecycleExit
  beforeGatewayPids=$beforePids
  afterGatewayPids=$afterPids
  modelPullStarted=$false
  providerChanged=$false
  networkChanged=$false
  mutation=$(if($ollamaStarted){'OLLAMA_SERVER_START_CHAT_CANARY_GATEWAY_REFRESH'}else{'CHAT_CANARY_GATEWAY_REFRESH'})
  observedAt=(Get-Date -Format o)
}) 0
