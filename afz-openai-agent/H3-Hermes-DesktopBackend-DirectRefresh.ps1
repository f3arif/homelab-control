#Requires -Version 5.1
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

function Emit($o,[int]$code=0){
  $o|ConvertTo-Json -Depth 14 -Compress
  exit $code
}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
  Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_WRONG_HOST';host=$env:COMPUTERNAME;mutation='NONE'}) 30
}

$hermesRoot=Join-Path $env:LOCALAPPDATA 'hermes'
$hermesPath=Join-Path $hermesRoot 'bin\hermes.exe'
$configPath=Join-Path $hermesRoot 'config.yaml'
$marker=Join-Path $hermesRoot 'afz-desktop-backend-direct-refresh-v1.json'
if(-not(Test-Path -LiteralPath $hermesPath -PathType Leaf)){
  Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_RUNTIME_MISSING';host=$env:COMPUTERNAME;mutation='NONE';path=$hermesPath}) 41
}
if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){
  Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_CONFIG_MISSING';host=$env:COMPUTERNAME;mutation='NONE';path=$configPath}) 42
}

# Idempotent: one successful recycle maximum for this recovery generation.
if(Test-Path -LiteralPath $marker -PathType Leaf){
  try{
    $prior=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json
    Emit ([ordered]@{ok=$true;classification='HERMES_DIRECT_REFRESH_ALREADY_APPLIED';host=$env:COMPUTERNAME;mutation='NONE';prior=$prior}) 0
  }catch{}
}

$oldHome=$env:HERMES_HOME
try{
  $env:HERMES_HOME=$hermesRoot
  $providerRaw=(& $hermesPath config get 'providers.ollama' --json 2>&1|Out-String).Trim()
  if($LASTEXITCODE -ne 0 -or $providerRaw -notmatch '127\.0\.0\.1:11434' -or $providerRaw -notmatch 'qwen3\.6:35b-a3b' -or $providerRaw -notmatch '65536'){
    Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_OLLAMA_PROVIDER_NOT_READY';host=$env:COMPUTERNAME;mutation='NONE';providerConfigured=$false}) 43
  }
  $modelRaw=(& $hermesPath config get 'model' --json 2>&1|Out-String).Trim()
  $modelProvider=''
  $modelDefault=''
  if($LASTEXITCODE -eq 0 -and $modelRaw){
    try{
      $m=$modelRaw|ConvertFrom-Json
      if($m.PSObject.Properties.Name -contains 'provider'){$modelProvider=[string]$m.provider}
      if($m.PSObject.Properties.Name -contains 'default'){$modelDefault=[string]$m.default}
    }catch{}
  }
  if([string]::IsNullOrWhiteSpace($modelProvider) -or $modelProvider -eq 'auto'){
    Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_MAIN_PROVIDER_NOT_READY';host=$env:COMPUTERNAME;mutation='NONE';providerConfigured=$true;modelProvider=$modelProvider;modelDefault=$modelDefault}) 44
  }
  try{$null=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -TimeoutSec 8}catch{
    Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_OLLAMA_UNREACHABLE';host=$env:COMPUTERNAME;mutation='NONE';providerConfigured=$true;modelProvider=$modelProvider;error=$_.Exception.Message}) 45
  }
}finally{
  if($null -eq $oldHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHome}
}

function Get-ProcessSnapshot {
  return @(Get-CimInstance Win32_Process -ErrorAction Stop)
}
function Build-ProcessMap($Processes){
  $map=@{}
  foreach($p in $Processes){$map[[int]$p.ProcessId]=$p}
  return $map
}
function Has-HermesElectronAncestor([int]$ProcessId,$Map){
  $seen=New-Object Collections.Generic.HashSet[int]
  $current=$ProcessId
  for($depth=0;$depth -lt 10;$depth++){
    if(-not $Map.ContainsKey($current)){return $false}
    $p=$Map[$current]
    $parent=[int]$p.ParentProcessId
    if($parent -le 0 -or $seen.Contains($parent)){return $false}
    [void]$seen.Add($parent)
    if(-not $Map.ContainsKey($parent)){return $false}
    $pp=$Map[$parent]
    if([string]$pp.Name -ieq 'Hermes.exe'){return $true}
    $current=$parent
  }
  return $false
}
function Is-DesktopEphemeralBackend($p,$Map){
  $cl=[string]$p.CommandLine
  if([string]::IsNullOrWhiteSpace($cl)){return $false}
  $isServeOrDashboard=($cl -match '(?i)(?:hermes(?:\.exe)?|hermes_cli[\\/]main(?:\.py)?)\s+(?:serve|dashboard)')
  $isPortZero=($cl -match '(?i)(?:--port\s+0(?:\s|$)|--port=0(?:\s|$))')
  if(-not($isServeOrDashboard -and $isPortZero)){return $false}
  return (Has-HermesElectronAncestor ([int]$p.ProcessId) $Map)
}

$before=Get-ProcessSnapshot
$map=Build-ProcessMap $before
$candidates=@($before|Where-Object{Is-DesktopEphemeralBackend $_ $map})
$safeCandidates=@($candidates|ForEach-Object{[ordered]@{pid=[int]$_.ProcessId;parentPid=[int]$_.ParentProcessId;name=[string]$_.Name;creationDate=[string]$_.CreationDate}})
if($candidates.Count -eq 0){
  Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_DESKTOP_BACKEND_NOT_FOUND';host=$env:COMPUTERNAME;mutation='NONE';providerConfigured=$true;modelProvider=$modelProvider;candidates=$safeCandidates;retryable=$false}) 46
}
if($candidates.Count -ne 1){
  Emit ([ordered]@{ok=$false;classification='HERMES_DIRECT_DESKTOP_BACKEND_AMBIGUOUS';host=$env:COMPUTERNAME;mutation='NONE';providerConfigured=$true;modelProvider=$modelProvider;candidates=$safeCandidates;retryable=$false}) 47
}

$oldPid=[int]$candidates[0].ProcessId
Stop-Process -Id $oldPid -Force -ErrorAction Stop
$deadline=(Get-Date).AddSeconds(30)
$newPid=$null
$newCommand=$null
do{
  Start-Sleep -Milliseconds 500
  try{
    $snap=Get-ProcessSnapshot
    $newMap=Build-ProcessMap $snap
    $hits=@($snap|Where-Object{([int]$_.ProcessId -ne $oldPid) -and (Is-DesktopEphemeralBackend $_ $newMap)})
    if($hits.Count -eq 1){$newPid=[int]$hits[0].ProcessId;$newCommand=[string]$hits[0].CommandLine;break}
  }catch{}
}while((Get-Date) -lt $deadline)

$result=[ordered]@{
  ok=$true
  classification=$(if($newPid){'HERMES_DIRECT_DESKTOP_BACKEND_REFRESHED'}else{'HERMES_DIRECT_DESKTOP_BACKEND_STOPPED_AWAITING_UI_RECONNECT'})
  host=$env:COMPUTERNAME
  mutation='STOP_EXACT_DESKTOP_EPHEMERAL_BACKEND_ONLY'
  providerConfigured=$true
  modelProvider=$modelProvider
  modelDefault=$modelDefault
  selectedOllamaModel='qwen3.6:35b-a3b'
  stoppedPid=$oldPid
  respawnedPid=$newPid
  electronUiTouched=$false
  messagingGatewayTouched=$false
  ollamaMutationStarted=$false
  generationTestStarted=$false
  finishedAt=(Get-Date -Format o)
}
$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $marker -Encoding UTF8
Emit $result 0
