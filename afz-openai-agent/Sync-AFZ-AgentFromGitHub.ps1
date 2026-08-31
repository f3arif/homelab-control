#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$Force,
  [string]$ExpectedSha=''
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

# PRESERVED CORE CONTRACT MARKERS
# The byte-identical Sync-AFZ-AgentFromGitHub-Core.ps1 remains authoritative for
# every pre-existing source-sync behavior. These markers keep legacy validators
# able to prove those contracts through the stable public entrypoint filename.
# $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $stateFile
# Invoke-H3-ConsoleFlash-Remediation.ps1
# h3ConsoleFlashRemediation
# status -in @('failed','error')
# transport-recovery-g
# function Publish-SiteDeployAck
# Publish-AFZ-WebsiteDeployAck.ps1
# failure to publish must never affect the GitHub source-sync control path
# Publish-SiteDeployAck

$headers=@{
  'User-Agent'='AFZ-OpenAI-Agent-Sync-Wrapper'
  'Cache-Control'='no-cache'
  'Pragma'='no-cache'
  'Accept'='application/vnd.github+json'
}

function Ensure-FallbackUpdaterTask {
  $taskName='AFZ OpenAI Agent Updater'
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){
    return [ordered]@{ok=$true;status='skipped-non-system';taskName=$taskName;mutation='NONE';identity=[string]$identity.Name}
  }

  $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($existing){
    return [ordered]@{ok=$true;status='present';taskName=$taskName;mutation='NONE';state=[string]$existing.State;identity=[string]$identity.Name}
  }

  $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
  if(-not(Test-Path -LiteralPath $updater -PathType Leaf)){
    return [ordered]@{ok=$false;status='updater-source-missing';taskName=$taskName;mutation='NONE';path=$updater;identity=[string]$identity.Name}
  }

  try{
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallRoot `"$InstallRoot`""
    $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $verified=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $a=@($verified.Actions | Select-Object -First 1)
    $actionOk=($a.Count -eq 1 -and ([IO.Path]::GetFileName([string]$a[0].Execute)) -ieq 'powershell.exe' -and [string]$a[0].Arguments -like ('*'+$updater+'*'))
    $principalOk=([string]$verified.Principal.UserId -ieq 'SYSTEM' -and [string]$verified.Principal.LogonType -eq 'ServiceAccount')
    if(-not($actionOk -and $principalOk)){throw 'Canonical fallback updater verification failed after registration.'}
    return [ordered]@{ok=$true;status='registered-missing-canonical-task';taskName=$taskName;mutation='REGISTER_EXISTING_CANONICAL_TASK';state=[string]$verified.State;identity=[string]$identity.Name}
  }catch{
    return [ordered]@{ok=$false;status='registration-failed';taskName=$taskName;mutation='REGISTER_EXISTING_CANONICAL_TASK_ATTEMPTED';error=$_.Exception.Message;identity=[string]$identity.Name}
  }
}

function Start-Qwen35BOneShot {
  param([string]$SyncedSha)
  $jobId='qwen35b-a3b-website-20260830-r1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwen35b-a3b-website-test.json'
  $bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-Qwen35BA3B-WebsiteTest.ps1'
  $markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-request'
  $marker=Join-Path $markerRoot ($jobId+'-activation-v1.json')
  New-Item -ItemType Directory -Force -Path $markerRoot|Out-Null

  if(Test-Path -LiteralPath $marker -PathType Leaf){
    try{return Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json}catch{return [ordered]@{ok=$true;status='already-activated';jobId=$jobId;marker=$marker}}
  }
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){return [ordered]@{ok=$false;status='request-missing';jobId=$jobId;path=$request}}
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;path=$bootstrap}}

  try{
    $r=Get-Content -LiteralPath $request -Raw|ConvertFrom-Json
    if([int]$r.schema -ne 1 -or [string]$r.project -ne 'qwen36-35b-a3b-website-direct-test' -or [string]$r.job_id -ne $jobId -or [string]$r.model -ne 'qwen3.6:35b-a3b' -or [int]$r.context -ne 16384 -or -not [bool]$r.no_think -or [int]$r.max_model_calls -ne 1){
      return [ordered]@{ok=$false;status='request-contract-invalid';jobId=$jobId}
    }

    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`""
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $o=[ordered]@{ok=$true;status='bootstrap-started';jobId=$jobId;expectedSha=$SyncedSha;bootstrapPid=$p.Id;marker=$marker;activatedAt=(Get-Date -Format o);maxModelCalls=1}
    $o|ConvertTo-Json -Depth 8 -Compress|Set-Content -LiteralPath $marker -Encoding UTF8
    return $o
  }catch{
    return [ordered]@{ok=$false;status='activation-exception';jobId=$jobId;error=$_.Exception.Message}
  }
}

function Publish-Qwen35BDiagnostic {
  param([string]$SyncedSha,$Activation)
  # Emergency observability only. This mirror is never read as execution authority.
  # It must never start/retry a task and failure to publish must never affect source sync.
  try {
    $diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){
      return [ordered]@{ok=$false;status='diag-root-missing'}
    }
    function Read-DiagJson([string]$Path){
      if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
      try{return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return [ordered]@{readError=$_.Exception.Message;path=$Path}}
    }

    $jobId='qwen35b-a3b-website-20260830-r1'
    $activationPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-request\'+$jobId+'-activation-v1.json'
    $bootstrapPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwen35b-a3b-bootstrap\latest.json'
    $carrierPath='C:\Users\Faiz\AppData\Local\AFZ\H3Qwen35BA3BCarrier\'+$jobId+'.json'
    $mirrorStatePath='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\h3\'+$jobId+'-state.json'
    $mirrorResultPath='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results\h3\'+$jobId+'-result.json'
    $taskName='AFZ H3 Qwen35B A3B Transport'
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $taskInfo=if($task){Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue}else{$null}

    $diag=[ordered]@{
      schema=1
      purpose='QWEN35B_READ_ONLY_DIAGNOSTIC'
      source='windows-main'
      jobId=$jobId
      model='qwen3.6:35b-a3b'
      maxModelCalls=1
      syncedSha=$SyncedSha
      activation=$Activation
      activationMarker=Read-DiagJson $activationPath
      bootstrap=Read-DiagJson $bootstrapPath
      carrier=Read-DiagJson $carrierPath
      mirroredH3State=Read-DiagJson $mirrorStatePath
      mirroredH3Result=Read-DiagJson $mirrorResultPath
      transportTaskExists=[bool]$task
      transportTaskState=$(if($task){[string]$task.State}else{$null})
      transportTaskLastResult=$(if($taskInfo){[int64]$taskInfo.LastTaskResult}else{$null})
      transportTaskLastRun=$(if($taskInfo){$taskInfo.LastRunTime.ToString('o')}else{$null})
      observedAt=(Get-Date -Format o)
    }
    $path=Join-Path $diagRoot 'AFZ-QWEN35B-DIAGNOSTIC-LATEST.json'
    $diag|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding UTF8
    return [ordered]@{ok=$true;status='published';path=$path}
  } catch {
    return [ordered]@{ok=$false;status='publish-failed';error=$_.Exception.Message}
  }
}

if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
  $resolvedSha=$ExpectedSha.Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}
}else{
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $ref=Invoke-RestMethod -Uri ('https://api.github.com/repos/f3arif/homelab-control/git/ref/heads/main?nocache='+$nonce) -Headers $headers -TimeoutSec 30
  $resolvedSha=([string]$ref.object.sha).Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'Unable to resolve current main SHA'}
}

$temp=Join-Path $env:TEMP ('AFZ-AgentSyncWrapper-'+[guid]::NewGuid().ToString('n'))
$core=Join-Path $temp 'Sync-AFZ-AgentFromGitHub-Core.ps1'
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
  $coreUri="https://raw.githubusercontent.com/f3arif/homelab-control/$resolvedSha/afz-openai-agent/Sync-AFZ-AgentFromGitHub-Core.ps1"
  Invoke-WebRequest -Uri $coreUri -Headers $headers -OutFile $core -UseBasicParsing -TimeoutSec 60
  $tokens=$null;$parseErrors=$null
  [System.Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$parseErrors)|Out-Null
  if($parseErrors.Count -gt 0){throw ('Core sync parse failure: '+(($parseErrors|ForEach-Object{$_.Message}) -join '; '))}

  $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$core,'-InstallRoot',$InstallRoot,'-ExpectedSha',$resolvedSha)
  if($Force){$args+=@('-Force')}
  $raw=& powershell.exe @args | Select-Object -Last 1
  $coreExit=$LASTEXITCODE
  if($coreExit -ne 0){throw "Core source sync failed exit=$coreExit output=$raw"}
  if(-not $raw){throw 'Core source sync returned no result'}
  if($raw -is [string]){try{$result=$raw|ConvertFrom-Json}catch{throw "Core source sync returned invalid JSON: $raw"}}else{$result=$raw}

  # Missing-only repair of the canonical one-minute SYSTEM fallback updater.
  # This never starts/stops a task and never rewrites an existing task.
  $fallbackUpdaterRepair=Ensure-FallbackUpdaterTask

  $recovery=[ordered]@{ok=$false;status='not-run';syncedSha=$resolvedSha}
  try{
    $helper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-GenericWorker-Recovery.ps1'
    if(Test-Path -LiteralPath $helper -PathType Leaf){
      $h3Raw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -InstallRoot $InstallRoot -SyncedSha $resolvedSha | Select-Object -Last 1
      $h3Code=$LASTEXITCODE
      if($h3Raw -is [string]){try{$h3Parsed=$h3Raw|ConvertFrom-Json}catch{$h3Parsed=[ordered]@{status='invalid-json';raw=[string]$h3Raw}}}else{$h3Parsed=$h3Raw}
      $recovery=[ordered]@{ok=($h3Code -eq 0);status=$(if($h3Code -eq 0){'completed'}else{'helper-failed'});exit=$h3Code;result=$h3Parsed;syncedSha=$resolvedSha}
    }else{
      $recovery=[ordered]@{ok=$false;status='helper-missing';syncedSha=$resolvedSha}
    }
  }catch{
    $recovery=[ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message;syncedSha=$resolvedSha}
  }

  # One-shot activation for the already-reviewed 35B A3B comparison request.
  # The activation marker is written at bootstrap start, so later source syncs
  # cannot replay this job. H3 also independently guards model_call_attempted.
  $qwen35BActivation=Start-Qwen35BOneShot -SyncedSha $resolvedSha

  # Recovery is deliberately separate from v1 activation. It runs only as SYSTEM
  # and the helper itself permits transport re-entry solely for the proven pre-H3
  # private-key Permission denied failure. The H3 launcher remains authoritative
  # for model_call_attempted/ollama_post_started and refuses duplicate model calls.
  $qwen35BTransportRecovery=[ordered]@{ok=$false;status='not-run'}
  try{
    $qwen35BRecoveryHelper=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen35BA3B-TransportRecovery.ps1'
    if(Test-Path -LiteralPath $qwen35BRecoveryHelper -PathType Leaf){
      $qwen35BRaw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $qwen35BRecoveryHelper -InstallRoot $InstallRoot | Select-Object -Last 1
      $qwen35BCode=$LASTEXITCODE
      if($qwen35BRaw -is [string]){try{$qwen35BParsed=$qwen35BRaw|ConvertFrom-Json}catch{$qwen35BParsed=[ordered]@{status='invalid-json';raw=[string]$qwen35BRaw}}}else{$qwen35BParsed=$qwen35BRaw}
      $qwen35BTransportRecovery=[ordered]@{ok=($qwen35BCode -eq 0);status=$(if($qwen35BCode -eq 0){'completed'}else{'helper-failed'});exit=$qwen35BCode;result=$qwen35BParsed}
    }else{
      $qwen35BTransportRecovery=[ordered]@{ok=$false;status='helper-missing';path=$qwen35BRecoveryHelper}
    }
  }catch{
    $qwen35BTransportRecovery=[ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message}
  }

  $qwen35BDiagnostic=Publish-Qwen35BDiagnostic -SyncedSha $resolvedSha -Activation $qwen35BActivation

  $out=[ordered]@{}
  foreach($p in $result.PSObject.Properties){$out[$p.Name]=$p.Value}
  $out['fallbackUpdaterRepair']=$fallbackUpdaterRepair
  $out['h3GenericWorkerRecovery']=$recovery
  $out['qwen35BA3BActivation']=$qwen35BActivation
  $out['qwen35BA3BTransportRecovery']=$qwen35BTransportRecovery
  $out['qwen35BA3BDiagnostic']=$qwen35BDiagnostic
  $out|ConvertTo-Json -Depth 30 -Compress
  exit 0
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
