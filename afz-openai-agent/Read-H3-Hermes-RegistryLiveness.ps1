$ErrorActionPreference='Stop'

function Emit([object]$Payload,[int]$Code=0){
  $Payload | ConvertTo-Json -Depth 8 -Compress
  exit $Code
}

if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){
  Emit ([ordered]@{ok=$false;classification='WRONG_HOST';host=$env:COMPUTERNAME;mutation='NONE'}) 30
}

$root=Join-Path $env:LOCALAPPDATA 'hermes'
$registry=Join-Path $root 'runtime\active_sessions.json'
if(-not(Test-Path -LiteralPath $registry -PathType Leaf)){
  Emit ([ordered]@{ok=$false;classification='REGISTRY_MISSING';mutation='NONE';registry=$registry}) 42
}

try{
  $raw=Get-Content -LiteralPath $registry -Raw -Encoding UTF8
  $reg=$raw | ConvertFrom-Json
}catch{
  Emit ([ordered]@{ok=$false;classification='REGISTRY_UNREADABLE';mutation='NONE';error=$_.Exception.Message}) 43
}

if(-not($reg.PSObject.Properties.Name -contains 'entries')){
  Emit ([ordered]@{ok=$false;classification='REGISTRY_SCHEMA_NOT_CANONICAL';mutation='NONE'}) 44
}

$entries=@($reg.entries)
$rows=@()
$liveOwners=0
$staleCandidates=0
$indeterminate=0

foreach($entry in $entries){
  $pidValue=0
  try{$pidValue=[int]$entry.pid}catch{$pidValue=0}
  $tracked=($entry.PSObject.Properties.Name -contains 'track_liveness') -and [bool]$entry.track_liveness
  $expectedStart=$null
  if($entry.PSObject.Properties.Name -contains 'process_start_time'){
    try{$expectedStart=[double]$entry.process_start_time}catch{$expectedStart=$null}
  }

  $proc=$null
  if($pidValue -gt 0){
    $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
  }
  $alive=($null -ne $proc)
  $actualStart=$null
  $startMatch=$null
  if($alive -and $null -ne $proc.CreationDate){
    try{
      $actualStart=([DateTimeOffset]$proc.CreationDate).ToUnixTimeMilliseconds()/1000.0
      if($null -ne $expectedStart){$startMatch=([math]::Abs($actualStart-$expectedStart) -lt 1.0)}
    }catch{}
  }

  $provenLive=$alive -and (($null -eq $expectedStart) -or ($startMatch -eq $true))
  $provenStale=$tracked -and ((-not $alive) -or (($null -ne $expectedStart) -and ($startMatch -eq $false)))
  if($provenLive){$liveOwners++}
  elseif($provenStale){$staleCandidates++}
  else{$indeterminate++}

  $rows += [ordered]@{
    surface=[string]$entry.surface
    pid=$pidValue
    trackLiveness=$tracked
    processAlive=$alive
    processName=if($alive){[string]$proc.Name}else{$null}
    expectedProcessStart=$expectedStart
    actualProcessStart=$actualStart
    processStartMatches=$startMatch
    provenLive=$provenLive
    provenStaleCandidate=$provenStale
    liveSessionIdPresent=([bool](($entry.PSObject.Properties.Name -contains 'metadata') -and $null -ne $entry.metadata -and ($entry.metadata.PSObject.Properties.Name -contains 'live_session_id') -and -not [string]::IsNullOrWhiteSpace([string]$entry.metadata.live_session_id)))
  }
}

# HERMES_R5_READONLY_RUNTIME_AUDIT
# Read-only evidence for the actual Telegram model dependency. No provider/config,
# process, task, gateway, network, or model-generation mutation occurs here.
$ollamaReachable=$false;$ollamaModelListed=$false;$ollamaModelCount=0;$ollamaError=$null
try{
  $m=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/v1/models' -Method Get -TimeoutSec 8
  $ids=@($m.data|ForEach-Object{[string]$_.id})
  $ollamaReachable=$true;$ollamaModelListed=('qwen3.6:35b-a3b' -in $ids);$ollamaModelCount=$ids.Count
}catch{$ollamaError=$_.Exception.GetType().Name}

$ollamaProcs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{([string]$_.CommandLine) -match '(?i)ollama(?:[.]exe)?\s+serve'}|ForEach-Object{[ordered]@{pid=[int]$_.ProcessId;name=[string]$_.Name;parentPid=[int]$_.ParentProcessId}})

$watchdogName='AFZ H3 Ollama Liveness'
$watchdog=$null;$watchdogInfo=$null;$watchdogError=$null
try{$watchdog=Get-ScheduledTask -TaskName $watchdogName -ErrorAction Stop;$watchdogInfo=Get-ScheduledTaskInfo -TaskName $watchdogName -ErrorAction SilentlyContinue}catch{$watchdogError=$_.Exception.GetType().Name}

$modelConfig=[ordered]@{readable=$false;default=$null;provider=$null;baseUrl=$null;contextLength=$null;apiMode=$null;error=$null}
$hermes=Join-Path $root 'bin\hermes.exe'
if(Test-Path -LiteralPath $hermes -PathType Leaf){
  $oldHome=$env:HERMES_HOME
  try{
    $env:HERMES_HOME=$root
    $rawModel=((& $hermes config get model --json 2>&1|Out-String).Trim())
    if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rawModel)){
      $mc=$rawModel|ConvertFrom-Json
      $modelConfig.readable=$true
      if($mc.PSObject.Properties.Name -contains 'default'){$modelConfig.default=[string]$mc.default}
      if($mc.PSObject.Properties.Name -contains 'provider'){$modelConfig.provider=[string]$mc.provider}
      if($mc.PSObject.Properties.Name -contains 'base_url'){$modelConfig.baseUrl=[string]$mc.base_url}
      if($mc.PSObject.Properties.Name -contains 'context_length'){$modelConfig.contextLength=$mc.context_length}
      if($mc.PSObject.Properties.Name -contains 'api_mode'){$modelConfig.apiMode=[string]$mc.api_mode}
    }else{$modelConfig.error='CONFIG_GET_FAILED'}
  }catch{$modelConfig.error=$_.Exception.GetType().Name}
  finally{if($null -eq $oldHome){Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue}else{$env:HERMES_HOME=$oldHome}}
}else{$modelConfig.error='HERMES_EXE_MISSING'}

$gateway=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  ([string]$_.Name) -match '(?i)python|hermes' -and
  ([string]$_.CommandLine) -match '(?i)hermes_cli[.]main' -and
  ([string]$_.CommandLine) -match '(?i)gateway\s+run'
} | ForEach-Object {
  [ordered]@{pid=[int]$_.ProcessId;name=[string]$_.Name;parentPid=[int]$_.ParentProcessId}
})

$classification=if($entries.Count -eq 0){
  'REGISTRY_EMPTY'
}elseif($liveOwners -gt 0){
  'REGISTRY_LIVE_OWNERS_PRESENT'
}elseif($staleCandidates -eq $entries.Count){
  'REGISTRY_STALE_CANDIDATES_ONLY'
}else{
  'REGISTRY_INDETERMINATE'
}

$item=Get-Item -LiteralPath $registry
Emit ([ordered]@{
  ok=$true
  classification=$classification
  mutation='NONE'
  host=$env:COMPUTERNAME
  registryEntryCount=$entries.Count
  liveOwnerCount=$liveOwners
  staleCandidateCount=$staleCandidates
  indeterminateCount=$indeterminate
  registryLastWriteUtc=$item.LastWriteTimeUtc.ToString('o')
  entries=$rows
  gatewayProcesses=$gateway
  ollamaReachable=$ollamaReachable
  ollamaModelListed=$ollamaModelListed
  ollamaModelCount=$ollamaModelCount
  ollamaError=$ollamaError
  ollamaServeProcesses=$ollamaProcs
  ollamaWatchdog=[ordered]@{exists=($null -ne $watchdog);state=$(if($watchdog){[string]$watchdog.State}else{$null});lastTaskResult=$(if($watchdogInfo){$watchdogInfo.LastTaskResult}else{$null});lastRunTime=$(if($watchdogInfo){$watchdogInfo.LastRunTime.ToString('o')}else{$null});nextRunTime=$(if($watchdogInfo){$watchdogInfo.NextRunTime.ToString('o')}else{$null});error=$watchdogError}
  modelConfig=$modelConfig
  providerTouched=$false
  ollamaMutationStarted=$false
  networkChanged=$false
  modelGenerationStarted=$false
  observedAt=(Get-Date).ToString('o')
}) 0
