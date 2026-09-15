#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\windowsmain-docker-lifecycle.json'
}
if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){
  throw "Windows-main Docker lifecycle request missing: $RequestPath"
}

$req=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$id=([string]$req.id).Trim()
if([int]$req.schema -ne 1 -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){
  throw 'Invalid Windows-main Docker lifecycle request identity.'
}
if([string]$req.action -ne 'docker-lifecycle' -or [string]$req.status -ne 'ACTIVE'){
  throw 'Windows-main Docker lifecycle request is not active.'
}
if([string]$req.target -ne 'windows-main' -or [string]$req.host -ne 'DESKTOP-10SKF0M'){
  throw 'Windows-main Docker lifecycle target mismatch.'
}
if([bool]$req.allow_remove -or [bool]$req.allow_volume_delete -or [bool]$req.allow_prune){
  throw 'Destructive Docker operations are not permitted by this typed lane.'
}

$ops=@($req.operations)
if($ops.Count -lt 1 -or $ops.Count -gt 20){throw 'Docker lifecycle operation count must be 1..20.'}
$allowedActions=@('status','stop','start','restart')

$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\windowsmain-docker-lifecycle'
$statePath=Join-Path $stateRoot ($id+'.json')
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagPath=Join-Path $diagRoot 'AFZ-WINDOWSMAIN-DOCKER-LIFECYCLE-LATEST.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Save-State($o){
  $json=$o | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      [IO.File]::WriteAllText($diagPath,$json,$utf8)
    }
  }catch{}
  Write-Output ($o | ConvertTo-Json -Depth 12 -Compress)
}

if(Test-Path -LiteralPath $statePath -PathType Leaf){
  $prior=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  if([string]$prior.jobId -eq $id -and [string]$prior.status -eq 'completed'){
    Write-Output ($prior | ConvertTo-Json -Depth 12 -Compress)
    exit 0
  }
}

$dockerCmd=Get-Command docker.exe,docker -ErrorAction SilentlyContinue | Select-Object -First 1
if(-not $dockerCmd){
  Save-State ([ordered]@{
    schema=1;ok=$false;status='failed';classification='WINDOWSMAIN_DOCKER_CLI_MISSING';
    jobId=$id;host=$env:COMPUTERNAME;mutationStarted=$false;destructiveOperationStarted=$false;
    observedAt=(Get-Date -Format o);purpose='EMERGENCY_TYPED_REMOTEOPS_RESULT';controlPlane='github+local-watcher'
  })
  exit 40
}
$docker=[string]$dockerCmd.Source

function Get-ContainerState([string]$Name){
  $raw=(& $docker inspect $Name --format '{{.State.Status}}|{{.HostConfig.RestartPolicy.Name}}' 2>&1 | Out-String).Trim()
  if($LASTEXITCODE -ne 0){throw "Container inspect failed for $Name: $raw"}
  $parts=$raw -split '\|',2
  return [ordered]@{state=[string]$parts[0];restartPolicy=$(if($parts.Count -gt 1){[string]$parts[1]}else{''})}
}

$results=New-Object Collections.Generic.List[object]
$mutationStarted=$false
try{
  foreach($op in $ops){
    $name=([string]$op.container).Trim()
    $verb=([string]$op.action).Trim().ToLowerInvariant()
    if($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'){throw "Invalid Docker container name: $name"}
    if($verb -notin $allowedActions){throw "Unsupported Docker lifecycle action: $verb"}

    $before=Get-ContainerState $name
    $disabledRestart=$false

    if($verb -eq 'stop'){
      $disableRestart=$true
      if($op.PSObject.Properties.Name -contains 'disable_restart'){
        $disableRestart=[bool]$op.disable_restart
      }
      if($disableRestart -and [string]$before.restartPolicy -ne 'no'){
        $updateOut=(& $docker update --restart=no $name 2>&1 | Out-String).Trim()
        if($LASTEXITCODE -ne 0){throw "docker update --restart=no failed for $name: $updateOut"}
        $mutationStarted=$true
        $disabledRestart=$true
      }
      if([string]$before.state -eq 'running'){
        $stopOut=(& $docker stop --timeout 30 $name 2>&1 | Out-String).Trim()
        if($LASTEXITCODE -ne 0){throw "docker stop failed for $name: $stopOut"}
        $mutationStarted=$true
      }
    }elseif($verb -eq 'start'){
      if([string]$before.state -ne 'running'){
        $startOut=(& $docker start $name 2>&1 | Out-String).Trim()
        if($LASTEXITCODE -ne 0){throw "docker start failed for $name: $startOut"}
        $mutationStarted=$true
      }
    }elseif($verb -eq 'restart'){
      $restartOut=(& $docker restart --timeout 30 $name 2>&1 | Out-String).Trim()
      if($LASTEXITCODE -ne 0){throw "docker restart failed for $name: $restartOut"}
      $mutationStarted=$true
    }

    $after=Get-ContainerState $name
    $results.Add([ordered]@{
      container=$name
      action=$verb
      before=$before
      after=$after
      restartPolicyDisabled=$disabledRestart
      ok=$true
    }) | Out-Null
  }

  $result=[ordered]@{
    schema=1
    ok=$true
    status='completed'
    classification='WINDOWSMAIN_DOCKER_LIFECYCLE_COMPLETED'
    jobId=$id
    host=$env:COMPUTERNAME
    operations=@($results)
    mutationStarted=$mutationStarted
    destructiveOperationStarted=$false
    allowRemove=$false
    allowVolumeDelete=$false
    allowPrune=$false
    observedAt=(Get-Date -Format o)
    purpose='EMERGENCY_TYPED_REMOTEOPS_RESULT'
    controlPlane='github+local-watcher'
  }
  Save-State $result
  exit 0
}catch{
  $result=[ordered]@{
    schema=1
    ok=$false
    status='failed'
    classification='WINDOWSMAIN_DOCKER_LIFECYCLE_FAILED'
    jobId=$id
    host=$env:COMPUTERNAME
    operations=@($results)
    mutationStarted=$mutationStarted
    destructiveOperationStarted=$false
    error=$_.Exception.Message
    observedAt=(Get-Date -Format o)
    purpose='EMERGENCY_TYPED_REMOTEOPS_RESULT'
    controlPlane='github+local-watcher'
  }
  Save-State $result
  exit 41
}
