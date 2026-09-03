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
