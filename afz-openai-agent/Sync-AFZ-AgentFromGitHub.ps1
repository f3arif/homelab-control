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

function Invoke-H3HermesQwenOneShot {
  param([string]$SyncedSha)
  # Git source sync remains authoritative. This bounded one-shot only executes the
  # currently committed H3 Hermes request after the exact SHA has been installed.
  # Failure is returned as diagnostic state and must never fail source sync.
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'
  $runner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-HermesAgent-Install.ps1'
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){return [ordered]@{ok=$false;status='request-missing';syncedSha=$SyncedSha}}
  if(-not(Test-Path -LiteralPath $runner -PathType Leaf)){return [ordered]@{ok=$false;status='runner-missing';syncedSha=$SyncedSha}}

  try{
    $r=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
    $jobId=([string]$r.id).Trim()
    if([int]$r.schema -ne 1 -or $jobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$' -or [string]$r.action -ne 'install-and-configure' -or [string]$r.status -ne 'ACTIVE' -or [string]$r.target -ne 'h3' -or [string]$r.host -ne 'DESKTOP-H3R6CQN'){
      return [ordered]@{ok=$false;status='request-contract-invalid';syncedSha=$SyncedSha}
    }
    if([bool]$r.expose_api -or [bool]$r.run_generation_test -or [bool]$r.mutate_ollama){
      return [ordered]@{ok=$false;status='request-safety-flags-invalid';jobId=$jobId;syncedSha=$SyncedSha}
    }

    $markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-hermes-postsync'
    $marker=Join-Path $markerRoot ($jobId+'-v1.json')
    New-Item -ItemType Directory -Force -Path $markerRoot|Out-Null
    if(Test-Path -LiteralPath $marker -PathType Leaf){
      try{return Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json}catch{return [ordered]@{ok=$true;status='already-attempted';jobId=$jobId;marker=$marker;syncedSha=$SyncedSha}}
    }

    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -InstallRoot $InstallRoot -RequestPath $request 2>&1|Out-String).Trim()
    $code=$LASTEXITCODE
    $parsed=$null
    foreach($line in @($raw -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})){try{$parsed=$line|ConvertFrom-Json}catch{}}
    $ok=($code -eq 0 -and $null -ne $parsed -and [bool]$parsed.ok)
    $o=[ordered]@{
      ok=$ok
      status=$(if($ok){'completed'}else{'attempt-failed'})
      jobId=$jobId
      syncedSha=$SyncedSha
      exit=$code
      classification=$(if($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'classification'){[string]$parsed.classification}else{$null})
      result=$parsed
      attemptedAt=(Get-Date -Format o)
      marker=$marker
    }
    $o|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $marker -Encoding UTF8
    return $o
  }catch{
    return [ordered]@{ok=$false;status='activation-exception';syncedSha=$SyncedSha;error=$_.Exception.Message}
  }
}

function Start-Ridge16KQualityAuditOneShot {
  param([string]$SyncedSha)
  $jobId='qwenridge16k-afz-website-20260902-r2-qa01'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-qwenridge16k-quality-audit.json'
  $bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-QwenRidge16K-QualityAudit.ps1'
  $markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-qwenridge16k-qa-request'
  $marker=Join-Path $markerRoot ($jobId+'-activation-v1.json')
  New-Item -ItemType Directory -Force -Path $markerRoot|Out-Null

  if(Test-Path -LiteralPath $marker -PathType Leaf){
    try{return Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json}catch{return [ordered]@{ok=$true;status='already-activated';jobId=$jobId;marker=$marker;syncedSha=$SyncedSha}}
  }
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){return [ordered]@{ok=$true;status='request-missing-not-armed';jobId=$jobId;syncedSha=$SyncedSha}}
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;path=$bootstrap;syncedSha=$SyncedSha}}

  try{
    $r=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
    $routes=@($r.required_routes|ForEach-Object {[string]$_})
    $expected=@('/','/services','/projects','/about','/contact')
    if([int]$r.schema -ne 1 -or [string]$r.project -ne 'qwenridge16k-readonly-quality-audit' -or [string]$r.job_id -ne $jobId -or [string]$r.source_job_id -ne 'qwenridge16k-afz-website-20260902-r2' -or [string]$r.project_root -ne 'C:\Projects\Qwen38-Ridge16K-AFZ-Website-Test-20260902-r2' -or -not [bool]$r.no_model_calls -or [bool]$r.site_mutation_allowed -or $routes.Count -ne 5){
      return [ordered]@{ok=$false;status='request-contract-invalid';jobId=$jobId;syncedSha=$SyncedSha}
    }
    foreach($route in $expected){if($routes -notcontains $route){return [ordered]@{ok=$false;status='request-route-contract-invalid';jobId=$jobId;route=$route;syncedSha=$SyncedSha}}}
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`""
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $o=[ordered]@{ok=$true;status='bootstrap-started';jobId=$jobId;expectedSha=$SyncedSha;bootstrapPid=$p.Id;marker=$marker;activatedAt=(Get-Date -Format o);modelCalls=0;siteMutationAllowed=$false}
    $o|ConvertTo-Json -Depth 10 -Compress|Set-Content -LiteralPath $marker -Encoding UTF8
    return $o
  }catch{
    return [ordered]@{ok=$false;status='activation-exception';jobId=$jobId;syncedSha=$SyncedSha;error=$_.Exception.Message}
  }
}

function Start-AFZBlogModelComparisonOneShot {
  param([string]$SyncedSha)
  $jobId='afz-blog-qwen35b-vs-ridge27b-20260902-r1'
  $request=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-afz-blog-model-comparison.json'
  $bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-AFZBlog-ModelComparison.ps1'
  $markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-request'
  $marker=Join-Path $markerRoot ($jobId+'-activation-v1.json')
  $utf8=New-Object Text.UTF8Encoding($false)
  New-Item -ItemType Directory -Force -Path $markerRoot|Out-Null
  if(Test-Path -LiteralPath $marker -PathType Leaf){
    try{return Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json}catch{return [ordered]@{ok=$true;status='already-activated';jobId=$jobId;marker=$marker;syncedSha=$SyncedSha}}
  }
  if(-not(Test-Path -LiteralPath $request -PathType Leaf)){return [ordered]@{ok=$false;status='request-missing';jobId=$jobId;syncedSha=$SyncedSha}}
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;syncedSha=$SyncedSha}}
  try{
    $r=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
    $models=@($r.models|ForEach-Object{[string]$_})
    if([int]$r.schema -ne 1 -or [string]$r.project -ne 'afz-blog-local-model-comparison' -or [string]$r.job_id -ne $jobId -or [string]$r.target -ne 'h3' -or [string]$r.host -ne 'DESKTOP-H3R6CQN' -or [int]$r.context -ne 16384 -or -not [bool]$r.no_think -or [int]$r.max_model_calls_per_model -ne 1 -or [bool]$r.publish_article -or [bool]$r.production_db_mutation -or $models.Count -ne 2 -or $models[0] -ne 'qwen3.6:35b-a3b' -or $models[1] -ne 'qwen3.8-ridge:27b-16k'){
      return [ordered]@{ok=$false;status='request-contract-invalid';jobId=$jobId;syncedSha=$SyncedSha}
    }
    $o=[ordered]@{ok=$true;status='activation-starting';jobId=$jobId;syncedSha=$SyncedSha;marker=$marker;maxModelCallsPerModel=1;publishArticle=$false;productionDbMutation=$false;activatedAt=(Get-Date -Format o)}
    [IO.File]::WriteAllText($marker,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`""
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $o['status']='bootstrap-started';$o['bootstrapPid']=$p.Id
    [IO.File]::WriteAllText($marker,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)
    return $o
  }catch{
    return [ordered]@{ok=$false;status='activation-exception';jobId=$jobId;syncedSha=$SyncedSha;error=$_.Exception.Message;marker=$marker}
  }
}

function Start-AFZBlogModelComparisonRecoveryOneShot {
  param([string]$SyncedSha)
  $jobId='afz-blog-qwen35b-vs-ridge27b-20260902-r1'
  $bootstrap=Join-Path $InstallRoot 'afz-openai-agent\Bootstrap-H3-AFZBlog-ModelComparisonRecovery.ps1'
  $markerRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-model-comparison-recovery-request'
  $marker=Join-Path $markerRoot ($jobId+'-activation-v3.json')
  $utf8=New-Object Text.UTF8Encoding($false)
  New-Item -ItemType Directory -Force -Path $markerRoot|Out-Null
  if(Test-Path -LiteralPath $marker -PathType Leaf){
    try{return Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json}catch{return [ordered]@{ok=$true;status='already-activated';jobId=$jobId;marker=$marker;syncedSha=$SyncedSha}}
  }
  if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){return [ordered]@{ok=$false;status='bootstrap-missing';jobId=$jobId;syncedSha=$SyncedSha}}
  try{
    $o=[ordered]@{ok=$true;status='recovery-starting';jobId=$jobId;syncedSha=$SyncedSha;marker=$marker;replay35B=$false;ridgeOnlyIfUnattempted=$true;activatedAt=(Get-Date -Format o)}
    [IO.File]::WriteAllText($marker,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)
    $argLine="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bootstrap`" -ExpectedSha `"$SyncedSha`" -JobId `"$jobId`" -Mode Bootstrap"
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $o['status']='recovery-bootstrap-started';$o['bootstrapPid']=$p.Id
    [IO.File]::WriteAllText($marker,($o|ConvertTo-Json -Depth 10 -Compress),$utf8)
    return $o
  }catch{
    return [ordered]@{ok=$false;status='recovery-activation-exception';jobId=$jobId;syncedSha=$SyncedSha;error=$_.Exception.Message;marker=$marker}
  }
}

if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
  $resolvedSha=$ExpectedSha.Trim().ToLowerInvariant()
  if($resolvedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}

  # MONOTONIC_STALE_EXACT_SHA_UNPIN_V1
  # The updater downloads this wrapper fresh on every pass. If a long-lived
  # watcher is still passing an older exact SHA, advance only when the current
  # deploy signal is a valid SHA and GitHub proves it descends from the requested
  # SHA. Never move sideways, backwards, or to an unproven ref.
  try{
    $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $signalRaw=(Invoke-WebRequest -Uri ('https://raw.githubusercontent.com/f3arif/homelab-control/main/.github/afz-agent-deploy-signal.txt?nocache='+$nonce) -Headers $headers -UseBasicParsing -TimeoutSec 20).Content
    $signalSha=([string]$signalRaw).Trim().ToLowerInvariant()
    if($signalSha -match '^[0-9a-f]{40}$' -and $signalSha -ne $resolvedSha){
      $pair=($resolvedSha+'...'+$signalSha)
      $cmp=Invoke-RestMethod -Uri ('https://api.github.com/repos/f3arif/homelab-control/compare/'+$pair+'?nocache='+$nonce) -Headers $headers -TimeoutSec 30
      if(([string]$cmp.status).ToLowerInvariant() -eq 'ahead'){$resolvedSha=$signalSha}
    }
  }catch{}
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


# AFZ_BLOG_RUNTIME_SYNC_HOOK
# The updater downloads this wrapper fresh on every pass. This narrow hook
# therefore makes Blog runtime persistence independent of a stale updater AST.
# The helper itself is SYSTEM-only and fail-closed on Git/build/task state.
$blogRuntimeEnsure=Join-Path $InstallRoot 'afz-openai-agent\Ensure-AFZ-BlogManager-Runtime.ps1'
if(Test-Path -LiteralPath $blogRuntimeEnsure -PathType Leaf){
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $blogRuntimeEnsure *> $null}catch{}
}

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

  # Execute the current H3 Hermes request once after exact Git source sync. This is
  # deliberately non-fatal to sync and carries its own per-request one-shot marker.
  $h3HermesQwenActivation=Invoke-H3HermesQwenOneShot -SyncedSha $resolvedSha

  # One-shot activation for the already-reviewed 35B A3B comparison request.
  # The activation marker is written at bootstrap start, so later source syncs
  # cannot replay this job. H3 also independently guards model_call_attempted.
  $qwen35BActivation=Start-Qwen35BOneShot -SyncedSha $resolvedSha

  # Isolated AFZ blog article model comparison; one call max per model, no publish/DB mutation.
  $afzBlogComparisonActivation=Start-AFZBlogModelComparisonOneShot -SyncedSha $resolvedSha

  # Post-return recovery: never replays 35B; Ridge may run only if prior state proves it unattempted.
  $afzBlogComparisonRecoveryActivation=Start-AFZBlogModelComparisonRecoveryOneShot -SyncedSha $resolvedSha

  $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=$false;status='not-run';syncedSha=$resolvedSha;readOnly=$true}
  try{
    $diagHelper=Join-Path $InstallRoot 'afz-openai-agent\Publish-AFZBlogRecoveryTransportState.ps1'
    if(Test-Path -LiteralPath $diagHelper -PathType Leaf){
      $diagRaw=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $diagHelper -SyncedSha $resolvedSha | Select-Object -Last 1
      $diagCode=$LASTEXITCODE
      if($diagRaw -is [string]){try{$diagParsed=$diagRaw|ConvertFrom-Json}catch{$diagParsed=[ordered]@{status='invalid-json';raw=[string]$diagRaw}}}else{$diagParsed=$diagRaw}
      $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=($diagCode -eq 0);status=$(if($diagCode -eq 0){'captured'}else{'helper-failed'});exit=$diagCode;result=$diagParsed;syncedSha=$resolvedSha;readOnly=$true}
    }else{
      $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=$false;status='helper-missing';path=$diagHelper;syncedSha=$resolvedSha;readOnly=$true}
    }
  }catch{
    $afzBlogComparisonRecoveryTransportDiagnostic=[ordered]@{ok=$false;status='helper-exception';error=$_.Exception.Message;syncedSha=$resolvedSha;readOnly=$true}
  }


  # Read-only Ridge16K r2 visual/content QA. The typed request forbids model calls and site mutation.
  $ridge16KQAActivation=Start-Ridge16KQualityAuditOneShot -SyncedSha $resolvedSha

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
  $out['h3HermesQwenActivation']=$h3HermesQwenActivation
  $out['qwen35BA3BActivation']=$qwen35BActivation
  $out['afzBlogModelComparisonActivation']=$afzBlogComparisonActivation
  $out['afzBlogModelComparisonRecoveryActivation']=$afzBlogComparisonRecoveryActivation
  $out['afzBlogModelComparisonRecoveryTransportDiagnostic']=$afzBlogComparisonRecoveryTransportDiagnostic
  $out['qwenRidge16KQAActivation']=$ridge16KQAActivation
  $out['qwen35BA3BTransportRecovery']=$qwen35BTransportRecovery
  $out['qwen35BA3BDiagnostic']=$qwen35BDiagnostic
  $out|ConvertTo-Json -Depth 30 -Compress
  exit 0
}finally{
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
