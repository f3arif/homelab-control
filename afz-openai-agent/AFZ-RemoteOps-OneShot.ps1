#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$taskName='AFZ Remote Ops'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\remoteops-start'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-REMOTEOPS-START-LATEST.json'
$h3HookMirror=Join-Path $mirrorRoot 'H3-TAILSCALE-UNATTENDED-HOOK-LATEST.txt'
$hermesHookMirror=Join-Path $mirrorRoot 'HPENVY-HERMES-OPENAI-CODEX-AUTH-HOOK-LATEST.txt'
$hermesPrimaryHookMirror=Join-Path $mirrorRoot 'HPENVY-HERMES-OPENAI-CODEX-PRIMARY-HOOK-LATEST.txt'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Write-Result($obj,[string]$path){
  $json=$obj | ConvertTo-Json -Depth 12
  $json | Set-Content -LiteralPath $path -Encoding UTF8
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){$json | Set-Content -LiteralPath $mirrorPath -Encoding UTF8}}catch{}
}
function Write-H3HookResult($obj){
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){($obj | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $h3HookMirror -Encoding UTF8}}catch{}
}
function Write-HermesHookResult($obj){
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){($obj | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $hermesHookMirror -Encoding UTF8}}catch{}
}
function Write-HermesPrimaryHookResult($obj){
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){($obj | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $hermesPrimaryHookMirror -Encoding UTF8}}catch{}
}
function Invoke-Phase1FamilyPttPrep {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Phase1-Apk-Prepare.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-phase1-apk-prepare.json'
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf) -or -not(Test-Path -LiteralPath $request -PathType Leaf)){return}
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request *> $null}catch{}
}
function Invoke-FamilyPttOnePlusInstall {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-OnePlus13R-Install.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-oneplus13r-install.json'
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf) -or -not(Test-Path -LiteralPath $request -PathType Leaf)){return}
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request *> $null}catch{}
}
function Invoke-H3SshKeyAclRepair {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Repair-H3-SshKeyAcl.ps1'
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){return}
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot *> $null}catch{}
}
function Invoke-H3TailscaleUnattended {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Enable-H3-Tailscale-Unattended.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-tailscale-unattended.json'
  $helperExists=Test-Path -LiteralPath $helper -PathType Leaf
  $requestExists=Test-Path -LiteralPath $request -PathType Leaf
  if(-not $helperExists -or -not $requestExists){
    Write-H3HookResult ([ordered]@{schema=1;status='not-invoked';helperExists=$helperExists;requestExists=$requestExists;helper=$helper;request=$request;time=(Get-Date -Format o)})
    return
  }
  try{
    $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request 2>&1 | Out-String).Trim()
    $code=$LASTEXITCODE
    $ErrorActionPreference=$oldEap
    Write-H3HookResult ([ordered]@{schema=1;status=$(if($code -eq 0){'completed'}else{'failed'});exitCode=$code;helperExists=$true;requestExists=$true;output=$raw;time=(Get-Date -Format o)})
  }catch{
    Write-H3HookResult ([ordered]@{schema=1;status='exception';exitCode=$LASTEXITCODE;helperExists=$true;requestExists=$true;error=$_.Exception.Message;detail=($_ | Out-String).Trim();time=(Get-Date -Format o)})
  }
}
function Invoke-HPEnvySurfsharkExitNode {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Surfshark-ExitNode.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\hpenvy-surfshark-exitnode.json'
  if(-not(Test-Path -LiteralPath $helper -PathType Leaf) -or -not(Test-Path -LiteralPath $request -PathType Leaf)){return}
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request *> $null}catch{}
}
function Invoke-HPEnvyHermesOpenAICodexAuth {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Hermes-OpenAICodexAuth.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\hpenvy-hermes-openai-codex-auth.json'
  $helperExists=Test-Path -LiteralPath $helper -PathType Leaf
  $requestExists=Test-Path -LiteralPath $request -PathType Leaf
  if(-not $helperExists -or -not $requestExists){
    Write-HermesHookResult ([ordered]@{schema=1;status='not-invoked';helperExists=$helperExists;requestExists=$requestExists;helper=$helper;request=$request;time=(Get-Date -Format o)})
    return
  }
  try{
    $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request 2>&1 | Out-String).Trim()
    $code=$LASTEXITCODE
    $ErrorActionPreference=$oldEap
    Write-HermesHookResult ([ordered]@{schema=1;status=$(if($code -eq 0){'completed'}else{'failed'});exitCode=$code;helperExists=$true;requestExists=$true;output=$raw;time=(Get-Date -Format o)})
  }catch{
    Write-HermesHookResult ([ordered]@{schema=1;status='exception';exitCode=$LASTEXITCODE;helperExists=$true;requestExists=$true;error=$_.Exception.Message;detail=($_ | Out-String).Trim();time=(Get-Date -Format o)})
  }
}
function Invoke-HPEnvyHermesOpenAICodexPrimary {
  $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Hermes-OpenAICodexPrimary.ps1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\hpenvy-hermes-openai-codex-primary.json'
  $helperExists=Test-Path -LiteralPath $helper -PathType Leaf
  $requestExists=Test-Path -LiteralPath $request -PathType Leaf
  if(-not $helperExists -or -not $requestExists){
    $hook=[ordered]@{schema=1;status='not-invoked';exitCode=$null;helperExists=$helperExists;requestExists=$requestExists;classification='HP_HERMES_CODEX_PRIMARY_INPUT_MISSING';time=(Get-Date -Format o)}
    Write-HermesPrimaryHookResult $hook
    return $hook
  }
  try{
    $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -RequestPath $request 2>&1 | Out-String).Trim()
    $code=$LASTEXITCODE
    $ErrorActionPreference=$oldEap
    $parsed=$null
    if(-not [string]::IsNullOrWhiteSpace($raw)){try{$parsed=$raw|ConvertFrom-Json}catch{}}
    $hook=[ordered]@{
      schema=1
      status=$(if($code -eq 0){'completed'}else{'failed'})
      exitCode=$code
      helperExists=$true
      requestExists=$true
      classification=$(if($parsed){[string]$parsed.classification}else{'HP_HERMES_CODEX_PRIMARY_INVALID_RESULT'})
      authVerified=$(if($parsed){[bool]$parsed.authVerified}else{$false})
      providerSwitched=$(if($parsed){[bool]$parsed.providerSwitched}else{$false})
      configuredProvider=$(if($parsed){[string]$parsed.configuredProvider}else{$null})
      configuredModel=$(if($parsed){[string]$parsed.configuredModel}else{$null})
      contextLength=$(if($parsed){[string]$parsed.contextLength}else{$null})
      baseUrlPresent=$(if($parsed){[bool]$parsed.baseUrlPresent}else{$false})
      generationStarted=$false
      gatewayStarted=$false
      secretValuesEmitted=$false
      time=(Get-Date -Format o)
    }
    Write-HermesPrimaryHookResult $hook
    return $hook
  }catch{
    $hook=[ordered]@{schema=1;status='exception';exitCode=$LASTEXITCODE;helperExists=$true;requestExists=$true;classification='HP_HERMES_CODEX_PRIMARY_HOOK_EXCEPTION';authVerified=$false;providerSwitched=$false;generationStarted=$false;gatewayStarted=$false;secretValuesEmitted=$false;error=$_.Exception.Message;time=(Get-Date -Format o)}
    Write-HermesPrimaryHookResult $hook
    return $hook
  }
}

if([string]::IsNullOrWhiteSpace($RequestPath)){throw 'RequestPath is required'}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw "Request missing: $RequestPath"}
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
$requestedTask=([string]$req.taskName).Trim()
$phase=''
try{$phase=([string]$req.phase).Trim().ToLowerInvariant()}catch{}
if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id'}
if($requestedTask -ne $taskName){throw "Unsupported task name: $requestedTask"}

$statePath=Join-Path $stateRoot ($id+'.json')

# Isolated post-login phase: verify the existing OAuth credential and configure only
# HP Envy Hermes primary routing. Do not regenerate a device code, start AFZ Remote
# Ops, or invoke any unrelated H3/Tailscale/Surfshark/FamilyPTT startup hook.
if($phase -eq 'hpenvy-hermes-codex-primary-only'){
  $hook=Invoke-HPEnvyHermesOpenAICodexPrimary
  $ok=([string]$hook.classification -eq 'HP_HERMES_CODEX_PRIMARY_CONFIGURED' -and [bool]$hook.authVerified -and [bool]$hook.providerSwitched -and [string]$hook.configuredProvider -eq 'openai-codex' -and [string]$hook.configuredModel -eq 'gpt-5.6-luna' -and -not [bool]$hook.baseUrlPresent)
  $r=[ordered]@{
    schema=1
    requestId=$id
    taskName=$taskName
    phase=$phase
    classification=$(if($ok){'REMOTEOPS_CODEX_PRIMARY_COMPLETED'}else{'REMOTEOPS_CODEX_PRIMARY_FAILED'})
    codex=$hook
    unrelatedHooksInvoked=$false
    remoteOpsTaskStarted=$false
    time=(Get-Date -Format o)
  }
  Write-Result $r $statePath
  Write-Output ($r | ConvertTo-Json -Depth 12 -Compress)
  if($ok){exit 0}else{exit 22}
}

# Targeted stale-worker recovery phase. This phase is intentionally narrow:
# it only inspects/restarts the pre-existing AFZ Remote Ops scheduled task.
# No H3/Tailscale/Surfshark/FamilyPTT/Hermes hooks are invoked.
if($phase -eq 'remoteops-recover-stale-only'){
  $heartbeatPath='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Heartbeat\windows-main.txt'
  function Get-HeartbeatAgeSeconds {
    param([string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{
      $line=Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -match '^Timestamp=(.+)$' } | Select-Object -First 1
      if(-not $line){return $null}
      $raw=([regex]::Match([string]$line,'^Timestamp=(.+)$')).Groups[1].Value
      $stamp=[DateTimeOffset]::Parse($raw,[Globalization.CultureInfo]::InvariantCulture)
      return [math]::Round(([DateTimeOffset]::Now-$stamp).TotalSeconds,1)
    }catch{return $null}
  }

  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if(-not $task){
    $r=[ordered]@{schema=1;requestId=$id;taskName=$taskName;phase=$phase;classification='REMOTEOPS_TASK_MISSING';unrelatedHooksInvoked=$false;time=(Get-Date -Format o)}
    Write-Result $r $statePath
    Write-Output ($r|ConvertTo-Json -Depth 8 -Compress)
    exit 20
  }

  $before=[string]$task.State
  $heartbeatAgeBefore=Get-HeartbeatAgeSeconds $heartbeatPath
  $heartbeatStale=($null -eq $heartbeatAgeBefore -or [double]$heartbeatAgeBefore -gt 180)
  $restartAttempted=$false
  $startAttempted=$false

  if($before -eq 'Running' -and $heartbeatStale){
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Start-Sleep -Seconds 1
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $restartAttempted=$true
  }elseif($before -ne 'Running'){
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $startAttempted=$true
  }

  Start-Sleep -Seconds 4
  $afterTask=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $after=[string]$afterTask.State
  $heartbeatAgeAfter=Get-HeartbeatAgeSeconds $heartbeatPath
  $class=$(if($after -eq 'Running'){'REMOTEOPS_TASK_RUNNING'}else{'REMOTEOPS_TASK_RECOVERY_FAILED'})
  $r=[ordered]@{
    schema=1
    requestId=$id
    taskName=$taskName
    phase=$phase
    classification=$class
    stateBefore=$before
    stateAfter=$after
    heartbeatAgeSecondsBefore=$heartbeatAgeBefore
    heartbeatAgeSecondsAfter=$heartbeatAgeAfter
    staleThresholdSeconds=180
    restartAttempted=$restartAttempted
    startAttempted=$startAttempted
    unrelatedHooksInvoked=$false
    radioHilalServicesTouched=$false
    time=(Get-Date -Format o)
  }
  Write-Result $r $statePath
  Write-Output ($r | ConvertTo-Json -Depth 8 -Compress)
  if($class -eq 'REMOTEOPS_TASK_RUNNING'){exit 0}else{exit 21}
}

# Legacy/default startup phase. The OAuth hook remains available for explicit future
# device-code regeneration requests; unrelated hooks retain their previous behavior.
Invoke-HPEnvyHermesOpenAICodexAuth
Invoke-H3SshKeyAclRepair
Invoke-H3TailscaleUnattended
Invoke-HPEnvySurfsharkExitNode
Invoke-Phase1FamilyPttPrep
Invoke-FamilyPttOnePlusInstall

if(Test-Path -LiteralPath $statePath -PathType Leaf){
  try{
    $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$existing.classification -eq 'REMOTEOPS_TASK_RUNNING'){
      Write-Result $existing $statePath
      Write-Output ($existing | ConvertTo-Json -Depth 12 -Compress)
      exit 0
    }
  }catch{}
}

$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $task){
  $r=[ordered]@{schema=1;requestId=$id;taskName=$taskName;classification='REMOTEOPS_TASK_MISSING';time=(Get-Date -Format o)}
  Write-Result $r $statePath
  Write-Output ($r|ConvertTo-Json -Compress)
  exit 20
}

$before=[string]$task.State
$startAttempted=$false
if($before -ne 'Running'){
  Start-ScheduledTask -TaskName $taskName
  $startAttempted=$true
  Start-Sleep -Seconds 3
}
$afterTask=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$after=[string]$afterTask.State
$info=$null
try{$info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop}catch{}
$class=$(if($after -eq 'Running'){'REMOTEOPS_TASK_RUNNING'}else{'REMOTEOPS_TASK_START_NOT_RUNNING'})
$r=[ordered]@{
  schema=1
  requestId=$id
  taskName=$taskName
  classification=$class
  startAttempted=$startAttempted
  stateBefore=$before
  stateAfter=$after
  lastRunTime=$(if($info){$info.LastRunTime}else{$null})
  lastTaskResult=$(if($info){$info.LastTaskResult}else{$null})
  nextRunTime=$(if($info){$info.NextRunTime}else{$null})
  time=(Get-Date -Format o)
}
Write-Result $r $statePath
Write-Output ($r | ConvertTo-Json -Depth 12 -Compress)
if($class -ne 'REMOTEOPS_TASK_RUNNING'){exit 21}
