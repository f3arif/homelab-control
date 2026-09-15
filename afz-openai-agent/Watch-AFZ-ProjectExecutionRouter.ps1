#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$stateRoot='C:\ProgramData\AFZ\ProjectExecution'
$watcherTaskName='AFZ Project Task Router Watcher'
$userTaskName='AFZ Hermes Project Task User Action'
$watchdogState=Join-Path $stateRoot 'watchdog.json'
$latestPath=Join-Path $stateRoot 'latest.json'
$resultPath=Join-Path $stateRoot 'result.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Read-JsonFile([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}
}
function Get-Prop($Object,[string]$Name,$Default=$null){
  if($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name){return $Object.$Name}
  return $Default
}
function Write-State($Object){
  try{[IO.File]::WriteAllText($watchdogState,($Object|ConvertTo-Json -Depth 12),$utf8)}catch{}
}

try{
  if($env:COMPUTERNAME -ne $expectedHost){throw "Project router watchdog wrong host: $env:COMPUTERNAME"}

  $watcher=Get-ScheduledTask -TaskName $watcherTaskName -ErrorAction SilentlyContinue
  $userTask=Get-ScheduledTask -TaskName $userTaskName -ErrorAction SilentlyContinue
  $watcherStarted=$false

  if(-not $watcher){
    $state=[ordered]@{schema=1;ok=$false;classification='PROJECT_ROUTER_WATCHER_TASK_MISSING';watcherTask=$watcherTaskName;userTaskPresent=[bool]$userTask;commanderMutation=$false;time=(Get-Date -Format o)}
    Write-State $state
    Write-Output ($state|ConvertTo-Json -Depth 12 -Compress)
    exit 20
  }

  if([string]$watcher.State -ne 'Running'){
    Start-ScheduledTask -TaskName $watcherTaskName -ErrorAction Stop
    $watcherStarted=$true
    Start-Sleep -Milliseconds 350
    $watcher=Get-ScheduledTask -TaskName $watcherTaskName -ErrorAction SilentlyContinue
  }

  # Never auto-rerun a stopped Hermes user action. Once a request was dispatched,
  # project mutation may already have started even if no result envelope exists.
  # The request watcher owns that ambiguity and will fail closed to review_required.
  $latest=Read-JsonFile $latestPath
  $result=Read-JsonFile $resultPath
  $latestStatus=[string](Get-Prop $latest 'status' '')
  $latestRequestId=[string](Get-Prop $latest 'requestId' '')
  $userState=$(if($userTask){[string]$userTask.State}else{'Missing'})
  $orphanedHermesPossible=($latestStatus -in @('dispatched','running') -and $userState -ne 'Running' -and (-not $result -or [string](Get-Prop $result 'requestId' '') -ne $latestRequestId))

  $state=[ordered]@{
    schema=1
    ok=([string]$watcher.State -eq 'Running')
    classification=$(if([string]$watcher.State -eq 'Running'){'PROJECT_ROUTER_WATCHER_HEALTHY'}else{'PROJECT_ROUTER_WATCHER_START_FAILED'})
    watcherTask=$watcherTaskName
    watcherState=[string]$watcher.State
    watcherStarted=$watcherStarted
    userTask=$userTaskName
    userTaskState=$userState
    requestStatus=$latestStatus
    requestId=$latestRequestId
    orphanedHermesPossible=$orphanedHermesPossible
    hermesAutoRestarted=$false
    commanderMutation=$false
    note=$(if($orphanedHermesPossible){'Hermes user action is not auto-restarted because prior mutation state is unknown; request watcher must fail closed to review_required.'}else{'No ambiguous Hermes restart required.'})
    time=(Get-Date -Format o)
  }
  Write-State $state
  Write-Output ($state|ConvertTo-Json -Depth 12 -Compress)
  if($state.ok){exit 0}else{exit 21}
}catch{
  $state=[ordered]@{schema=1;ok=$false;classification='PROJECT_ROUTER_WATCHDOG_EXCEPTION';error=$_.Exception.Message;hermesAutoRestarted=$false;commanderMutation=$false;time=(Get-Date -Format o)}
  Write-State $state
  Write-Output ($state|ConvertTo-Json -Depth 12 -Compress)
  exit 22
}
