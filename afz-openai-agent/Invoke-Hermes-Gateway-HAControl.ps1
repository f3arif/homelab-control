#Requires -Version 5.1
# Request-gated control for the Hermes gateway HA system on ASUS/windows-main.
#
# Actions:
#   status    - read-only: emit gateway-ha.json plus task states.
#   simulate  - create the simulation flag (watcher treats H3 gateway as failed;
#               H3 itself is never touched). Requires unique request id.
#   clear     - remove the simulation flag; next cycles recover naturally.
#
# Request file: afz-openai-agent\requests\hermes-gateway-ha-control.json
#   {"schema":1,"id":"hermes-gateway-ha-control-<unique>","action":"simulate|clear|status",
#    "target":"windows-main","host":"DESKTOP-10SKF0M","status":"ACTIVE","reason":"..."}
# One-shot semantics per id: each control id applies at most once.
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if($env:COMPUTERNAME -ne 'DESKTOP-10SKF0M'){ throw "Gateway HA control wrong host: $env:COMPUTERNAME" }

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\hermes-gateway-ha-control.json'
}
if(-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)){ throw "Gateway HA control request missing: $RequestPath" }
$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){ throw 'Invalid gateway HA control request identity.' }
$action=([string]$req.action).Trim().ToLowerInvariant()
if([string]$req.target -ne 'windows-main' -or [string]$req.host -ne 'DESKTOP-10SKF0M'){ throw 'Gateway HA control target mismatch.' }
if($action -notin @('status','simulate','clear')){ throw 'Unsupported gateway HA control action.' }

$stateDir='C:\ProgramData\AFZ\HermesRouting'
$flag=Join-Path $stateDir 'gateway-ha-simulate.flag'
$stateFile=Join-Path $stateDir 'gateway-ha.json'
$controlStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\hermes-gateway-ha-control'
$controlMarker=Join-Path $controlStateRoot 'marker.json'
$controlAttempt=Join-Path $controlStateRoot 'attempt.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $controlStateRoot | Out-Null

function Emit($o){
  $j=$o|ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText($controlAttempt,$j,$utf8)
  Write-Output ($o|ConvertTo-Json -Depth 10 -Compress)
}

# One-shot semantics per id, recorded only on success.
$already=$false
if(Test-Path -LiteralPath $controlMarker -PathType Leaf){
  try{$m=Get-Content -LiteralPath $controlMarker -Raw|ConvertFrom-Json;$already=([string]$m.id -eq $id -and [int]$m.exitCode -eq 0)}catch{}
}
if($already){
  Emit ([ordered]@{ok=$true;classification='GATEWAY_HA_CONTROL_ALREADY_APPLIED';id=$id;action=$action})
  exit 0
}

switch($action){
  'status'{
    $ha=$null
    if(Test-Path -LiteralPath $stateFile -PathType Leaf){
      try{$ha=Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
    }
    $systemTask=Get-ScheduledTask -TaskName 'AFZ Hermes Gateway HA Watcher' -ErrorAction SilentlyContinue
    $userTask=Get-ScheduledTask -TaskName 'AFZ Hermes Gateway HA User Action' -ErrorAction SilentlyContinue
    Emit ([ordered]@{
      ok=$true
      classification='GATEWAY_HA_STATUS'
      id=$id
      activeHost=$(if($ha){[string]$ha.activeHost}else{$null})
      simulation=$(if($ha){[bool]$ha.simulation}else{$false})
      consecutivePrimaryFailures=$(if($ha){[int]$ha.consecutivePrimaryFailures}else{0})
      consecutivePrimarySuccesses=$(if($ha){[int]$ha.consecutivePrimarySuccesses}else{0})
      h3Classification=$(if($ha -and $ha.h3){[string]$ha.h3.classification}else{$null})
      asusGatewayPidCount=$(if($ha){[int]$ha.asus.gatewayPidCount}else{0})
      haStateFileExists=(Test-Path -LiteralPath $stateFile -PathType Leaf)
      systemTaskState=$(if($systemTask){[string]$systemTask.State}else{'Missing'})
      userTaskState=$(if($userTask){[string]$userTask.State}else{'Missing'})
      flagExists=(Test-Path -LiteralPath $flag -PathType Leaf)
      time=(Get-Date -Format o)
    })
    exit 0
  }
  'simulate'{
    $reason='requested'
    try{if($req.reason){$reason=[string]$req.reason}}catch{}
    $content=('SIMULATION reason=' + $reason + ' id=' + $id + ' at=' + (Get-Date -Format o))
    [IO.File]::WriteAllText($flag,$content,$utf8)
    Emit ([ordered]@{ok=$true;classification='GATEWAY_HA_SIMULATION_SET';id=$id;reason=$reason;flag=$flag;time=(Get-Date -Format o)})
    exit 0
  }
  'clear'{
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    Emit ([ordered]@{ok=$true;classification='GATEWAY_HA_SIMULATION_CLEARED';id=$id;time=(Get-Date -Format o)})
    exit 0
  }
}
