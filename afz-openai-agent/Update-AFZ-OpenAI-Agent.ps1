#Requires -Version 5.1
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$ExpectedSha=''
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$statusFile=Join-Path $stateRoot 'last-update.json'
$pushWatcherHashMarker=Join-Path $stateRoot 'push-watcher-source.sha256'
$started=Get-Date
$mutex=New-Object Threading.Mutex($false,'Global\AFZOpenAIAgentUpdater')
$locked=$false

function Write-TransportDiagnosticAck {
  param(
    [string]$RemoteSha,
    [string]$Expected,
    [string]$TriggerName,
    [string]$PushTaskState,
    [string]$SiteTaskState
  )
  # Emergency observability only. This file is never read as a command, request,
  # lease, approval, or deployment authority. Failure to write it never blocks GitHub.
  try {
    $diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    function Read-DiagnosticJson([string]$Path){
      if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
      try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return [ordered]@{readError=$_.Exception.Message;path=$Path}}
    }
    $h3HotfixPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix\gh-argument-binding-v1.json'
    $h3PostHookPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-hotfix\postmortem-hook-latest.json'
    $h3PostMarkerPath='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-return-publisher-postmortem\postmortem-v1.json'
    # H3_OLLAMA_WATCHDOG_AUDIT_ACK_BIND_V1
    $h3OllamaWatchdogAuditPath='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius\H3-GENERIC-WORKER-RECOVERY-LATEST.json'
    $movierecommenderCatalogV2StatePath='C:\ProgramData\AFZ\OpenAIAgent\jobs\movierecommender-catalog-v2-github\movierecommender-catalog-v2-github-20260903-r1.json'
    $h3Hotfix=Read-DiagnosticJson $h3HotfixPath
    $h3PostHook=Read-DiagnosticJson $h3PostHookPath
    $h3PostMarker=Read-DiagnosticJson $h3PostMarkerPath

    # Read-only R5 post-cleanup proof. This mirrors only process presence into the
    # existing transport ACK and never stops, starts, or mutates any process/task.
    $r5JobId='afz-site-git-cutover-r5-20260828T1151'
    $r5Core=@();$r5CorePids=@();$r5Ssh=@()
    try {
      $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
      $r5Core=@($all | Where-Object {
        [string]$_.Name -ieq 'powershell.exe' -and
        ([string]$_.CommandLine) -match '(?i)Deploy-AFZ-WebsiteToPi-Core[.]ps1' -and
        ([string]$_.CommandLine) -match [regex]::Escape($r5JobId)
      })
      $r5CorePids=@($r5Core | ForEach-Object {[int]$_.ProcessId})
      $r5Ssh=@($all | Where-Object {
        ([string]$_.Name) -match '(?i)^ssh[.]exe$' -and
        $r5CorePids -contains [int]$_.ParentProcessId -and
        ([string]$_.CommandLine) -match [regex]::Escape('192.168.50.68') -and
        ([string]$_.CommandLine) -match '(?i)mkdir -p' -and
        ([string]$_.CommandLine) -match [regex]::Escape('/opt/edge/afz-site/git-deploy/stage')
      })
    } catch {}

    $diag=[ordered]@{
      schema=1
      purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
      source='windows-main'
      controlPlane='github'
      component='AFZ OpenAI Agent Updater'
      remoteSha=$RemoteSha
      expectedSha=$(if($Expected){$Expected}else{$null})
      trigger=$TriggerName
      updaterTask='AFZ OpenAI Agent Updater'
      pushWatcherTask='AFZ OpenAI Agent Push Deploy Watcher'
      pushWatcherTaskState=$PushTaskState
      siteWatcherTask='AFZ Website Git Deploy Request Watcher'
      siteWatcherTaskState=$SiteTaskState
      r5ProbeReadOnly=$true
      r5CoreProcessCount=@($r5Core).Count
      r5CorePids=@($r5CorePids)
      r5SshProcessCount=@($r5Ssh).Count
      r5SshPids=@($r5Ssh | ForEach-Object {[int]$_.ProcessId})
      h3ReturnHotfixMarkerExists=(Test-Path -LiteralPath $h3HotfixPath -PathType Leaf)
      h3ReturnHotfix=$h3Hotfix
      h3ReturnPostmortemHookExists=(Test-Path -LiteralPath $h3PostHookPath -PathType Leaf)
      h3ReturnPostmortemHook=$h3PostHook
      h3ReturnPostmortemMarkerExists=(Test-Path -LiteralPath $h3PostMarkerPath -PathType Leaf)
      h3ReturnPostmortem=$h3PostMarker
      h3OllamaWatchdogAudit=Read-DiagnosticJson $h3OllamaWatchdogAuditPath
      movierecommenderCatalogV2State=Read-DiagnosticJson $movierecommenderCatalogV2StatePath
      time=(Get-Date -Format o)
    }
    $diagJson=$diag | ConvertTo-Json -Depth 30
    $diagJson | Set-Content -LiteralPath (Join-Path $diagRoot 'AFZ-GITHUB-TRANSPORT-ACK-LATEST.json') -Encoding UTF8
    $diagJson | Set-Content -LiteralPath (Join-Path $diagRoot 'AFZ-R5-PROCESS-PROOF-LATEST.txt') -Encoding UTF8
  } catch {}
}

try{
  try{
    $locked=$mutex.WaitOne([TimeSpan]::FromSeconds(60))
  }catch [System.Threading.AbandonedMutexException]{
    # WaitOne grants this thread ownership before reporting an abandoned owner.
    # Continue under the acquired mutex so a crashed prior updater cannot deadlock recovery.
    $locked=$true
  }
  if(-not $locked){throw 'Another AFZ updater instance remained active for more than 60 seconds'}

  if(-not [string]::IsNullOrWhiteSpace($ExpectedSha)){
    $ExpectedSha=$ExpectedSha.Trim().ToLowerInvariant()
    if($ExpectedSha -notmatch '^[0-9a-f]{40}$'){throw 'ExpectedSha must be a 40-character Git commit SHA'}
  }

  # Always bootstrap the current sync helper so stale local source cannot pin updates.
  $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $tmpSync=Join-Path $env:TEMP ('Sync-AFZ-AgentFromGitHub-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $syncUri="https://raw.githubusercontent.com/f3arif/homelab-control/main/afz-openai-agent/Sync-AFZ-AgentFromGitHub.ps1?nocache=$nonce"
  $syncHeaders=@{'User-Agent'='AFZ-OpenAI-Agent-Updater';'Cache-Control'='no-cache';'Pragma'='no-cache'}
  Invoke-WebRequest -Uri $syncUri -Headers $syncHeaders -OutFile $tmpSync -UseBasicParsing -TimeoutSec 60
  try{
    $syncArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$tmpSync,'-InstallRoot',$InstallRoot)
    if($ExpectedSha){$syncArgs+=@('-ExpectedSha',$ExpectedSha)}
    $syncRaw=@(& powershell.exe @syncArgs 2>&1)
    $syncExit=$LASTEXITCODE
  }finally{Remove-Item -LiteralPath $tmpSync -Force -ErrorAction SilentlyContinue}
  if($syncExit -ne 0){
    $syncText=($syncRaw|ForEach-Object{[string]$_}) -join [Environment]::NewLine
    throw "Agent source sync failed exit=$syncExit output=$syncText"
  }
  $syncLine=($syncRaw|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Select-Object -Last 1)
  if([string]::IsNullOrWhiteSpace($syncLine)){throw 'Agent source sync returned no result'}
  try{$syncResult=$syncLine|ConvertFrom-Json -ErrorAction Stop}catch{throw "Agent source sync returned invalid JSON: $syncLine"}
  $remoteSha=([string]$syncResult.remoteSha).Trim().ToLowerInvariant()
  if($remoteSha -notmatch '^[0-9a-f]{40}$'){throw "Agent source sync returned invalid remoteSha: $remoteSha"}
  if($ExpectedSha -and $remoteSha -ne $ExpectedSha){throw "Agent source sync returned unexpected remoteSha: actual=$remoteSha expected=$ExpectedSha"}
  $changed=[bool]$syncResult.changed

# RADIOHILAL_GIT_TRACKING_REPAIR_POSTSYNC_HOOK_V1
  # Bootstrap the private RadioHilal checkout out of stale remote-tracking refs.
  # The helper is fixed-target and fail-closed: clean checkout, approved origin,
  # fast-forward only, backup ref before main movement, no live service mutation.
  $radioHilalGitRepairRunner=Join-Path $InstallRoot 'afz-openai-agent\Repair-RadioHilal-GitTracking.ps1'
  if(Test-Path -LiteralPath $radioHilalGitRepairRunner -PathType Leaf){
    try{
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $radioHilalGitRepairRunner -InstallRoot $InstallRoot *> $null
    }catch{}
  }

# RADIOHILAL_GITHUB_API_DEPLOY_POSTSYNC_HOOK_V1
  # Fixed-target exact-SHA RadioHilal deployment. The helper is fail-closed,
  # requires a successful BuildApi validation for the exact RadioHilal main SHA,
  # stages and backs up before mutation, preserves appsettings, health-checks,
  # and rolls back automatically on post-mutation failure.
  $radioHilalApiDeployRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-RadioHilal-GitHubApiDeploy.ps1'
  if(Test-Path -LiteralPath $radioHilalApiDeployRunner -PathType Leaf){
    try{
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $radioHilalApiDeployRunner -InstallRoot $InstallRoot *> $null
    }catch{}
  }


# RADIOHILAL_GITHUB_FRONTEND_QUEUE_POSTSYNC_HOOK_V1
  # GitHub-first recovery path for the RadioHilal admin UI. This helper does not
  # deploy directly: it requires the exact BuildApi validation, confirms the
  # RadioHilal checkout is at the requested SHA, writes one rollback-protected
  # github-main-frontend-deploy job into the local RemoteOps queue, and starts
  # the existing AFZ Remote Ops task. The downstream action retains RAM/CPU
  # admission control and restarts only RadioHilal.Frontend.
  $radioHilalFrontendQueueRunner=Join-Path $InstallRoot 'afz-openai-agent\Queue-RadioHilal-FrontendDeploy.ps1'
  $radioHilalFrontendQueueRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\radiohilal-frontend-deploy.json'
  if((Test-Path -LiteralPath $radioHilalFrontendQueueRunner -PathType Leaf) -and (Test-Path -LiteralPath $radioHilalFrontendQueueRequest -PathType Leaf)){
    try{
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $radioHilalFrontendQueueRunner -InstallRoot $InstallRoot -RequestPath $radioHilalFrontendQueueRequest *> $null
    }catch{}
  }

# RADIOHILAL_HERMES_CRON_AUDIT_POSTSYNC_HOOK_V1
  # Read-only fixed-job audit for Hermes cron 9d9eea1b7618. The helper emits
  # sanitized routing/state only; this hook mirrors that JSON for remote
  # observability without exposing config.yaml or credential material.
  $radioHilalHermesAuditRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Hermes-RadioHilalCronAudit.ps1'
  if(Test-Path -LiteralPath $radioHilalHermesAuditRunner -PathType Leaf){
    $auditStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\radiohilal-hermes-cron'
    $auditStatePath=Join-Path $auditStateRoot 'latest.json'
    $auditMirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
    $auditMirrorPath=Join-Path $auditMirrorRoot 'RADIOHILAL-HERMES-CRON-AUDIT-LATEST.json'
    try{
      New-Item -ItemType Directory -Force -Path $auditStateRoot | Out-Null
      $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
      $auditRaw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $radioHilalHermesAuditRunner -JobId '9d9eea1b7618' 2>&1 | Out-String).Trim()
      $auditCode=$LASTEXITCODE
      $ErrorActionPreference=$oldEap
      if([string]::IsNullOrWhiteSpace($auditRaw)){throw 'RadioHilal Hermes cron audit returned empty output'}
      $auditObj=$auditRaw|ConvertFrom-Json -ErrorAction Stop
      $auditEnvelope=[ordered]@{
        schema=1
        sourceSha=$remoteSha
        hook='RADIOHILAL_HERMES_CRON_AUDIT_POSTSYNC_HOOK_V1'
        auditExitCode=$auditCode
        audit=$auditObj
        time=(Get-Date -Format o)
      }
      $auditJson=$auditEnvelope|ConvertTo-Json -Depth 16
      $auditJson|Set-Content -LiteralPath $auditStatePath -Encoding UTF8
      try{
        if(Test-Path -LiteralPath $auditMirrorRoot -PathType Container){
          $auditJson|Set-Content -LiteralPath $auditMirrorPath -Encoding UTF8
        }
      }catch{}
    }catch{
      try{
        New-Item -ItemType Directory -Force -Path $auditStateRoot | Out-Null
        $auditEnvelope=[ordered]@{
          schema=1
          sourceSha=$remoteSha
          hook='RADIOHILAL_HERMES_CRON_AUDIT_POSTSYNC_HOOK_V1'
          auditExitCode=$LASTEXITCODE
          audit=[ordered]@{ok=$false;classification='RADIOHILAL_HERMES_CRON_AUDIT_HOOK_EXCEPTION';secretValuesEmitted=$false;error=$_.Exception.Message}
          time=(Get-Date -Format o)
        }
        $auditJson=$auditEnvelope|ConvertTo-Json -Depth 16
        $auditJson|Set-Content -LiteralPath $auditStatePath -Encoding UTF8
        if(Test-Path -LiteralPath $auditMirrorRoot -PathType Container){
          $auditJson|Set-Content -LiteralPath $auditMirrorPath -Encoding UTF8
        }
      }catch{}
    }
  }


# RADIOHILAL_H3_WAKE_POSTSYNC_HOOK_V1
  # One-shot fixed-target H3 wake request for the paused RadioHilal Hermes cron.
  # The helper can only send WOL from windows-main to the predeclared H3 identity.
  # A state file makes each request id single-attempt; retries require a new id.
  $radioHilalH3WakeRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-RadioHilal-Wake.ps1'
  $radioHilalH3WakeRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-radiohilal-wake.json'
  if((Test-Path -LiteralPath $radioHilalH3WakeRunner -PathType Leaf) -and (Test-Path -LiteralPath $radioHilalH3WakeRequest -PathType Leaf)){
    $radioHilalH3WakeStateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\radiohilal-h3-wake'
    $radioHilalH3WakeMirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
    $radioHilalH3WakeMirrorPath=Join-Path $radioHilalH3WakeMirrorRoot 'RADIOHILAL-H3-WAKE-LATEST.json'
    try{
      $wakeReq=Get-Content -LiteralPath $radioHilalH3WakeRequest -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
      $wakeId=([string]$wakeReq.id).Trim()
      if([int]$wakeReq.schema -ne 1 -or $wakeId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid RadioHilal H3 wake request identity'}
      if([string]$wakeReq.action -ne 'wake-h3-for-radiohilal-cron-repair' -or [string]$wakeReq.status -ne 'ACTIVE'){throw 'RadioHilal H3 wake request is not active/allowlisted'}
      if([string]$wakeReq.target.host -ne 'DESKTOP-H3R6CQN' -or [string]$wakeReq.target.tailscaleIp -ne '100.106.186.118' -or [string]$wakeReq.target.lanIp -ne '192.168.50.185' -or [string]$wakeReq.target.mac -ne '4C-ED-FB-3F-B0-9E' -or [string]$wakeReq.target.broadcast -ne '192.168.50.255'){throw 'RadioHilal H3 wake target contract mismatch'}
      New-Item -ItemType Directory -Force -Path $radioHilalH3WakeStateRoot | Out-Null
      $wakeStatePath=Join-Path $radioHilalH3WakeStateRoot ($wakeId+'.json')
      if(-not(Test-Path -LiteralPath $wakeStatePath -PathType Leaf)){
        $oldEap=$ErrorActionPreference;$ErrorActionPreference='Continue'
        $wakeRaw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $radioHilalH3WakeRunner -InstallRoot $InstallRoot -RequestPath $radioHilalH3WakeRequest 2>&1|Out-String).Trim()
        $wakeCode=$LASTEXITCODE
        $ErrorActionPreference=$oldEap
        $wakeParsed=$null
        if(-not [string]::IsNullOrWhiteSpace($wakeRaw)){try{$wakeParsed=$wakeRaw|ConvertFrom-Json -ErrorAction Stop}catch{}}
        $wakeEnvelope=[ordered]@{
          schema=1
          sourceSha=$remoteSha
          hook='RADIOHILAL_H3_WAKE_POSTSYNC_HOOK_V1'
          requestId=$wakeId
          exitCode=$wakeCode
          result=$(if($wakeParsed){$wakeParsed}else{[ordered]@{ok=$false;classification='H3_WAKE_OUTPUT_PARSE_FAILED'}})
          time=(Get-Date -Format o)
        }
        $wakeJson=$wakeEnvelope|ConvertTo-Json -Depth 16
        $wakeJson|Set-Content -LiteralPath $wakeStatePath -Encoding UTF8
        try{
          if(Test-Path -LiteralPath $radioHilalH3WakeMirrorRoot -PathType Container){
            $wakeJson|Set-Content -LiteralPath $radioHilalH3WakeMirrorPath -Encoding UTF8
          }
        }catch{}
      }
    }catch{
      try{
        New-Item -ItemType Directory -Force -Path $radioHilalH3WakeStateRoot | Out-Null
        $wakeFailure=[ordered]@{
          schema=1
          sourceSha=$remoteSha
          hook='RADIOHILAL_H3_WAKE_POSTSYNC_HOOK_V1'
          requestId=$(if($wakeId){$wakeId}else{$null})
          exitCode=$LASTEXITCODE
          result=[ordered]@{ok=$false;classification='H3_WAKE_HOOK_EXCEPTION';error=$_.Exception.Message}
          time=(Get-Date -Format o)
        }
        $wakeFailureJson=$wakeFailure|ConvertTo-Json -Depth 16
        if($wakeId){$wakeFailureJson|Set-Content -LiteralPath (Join-Path $radioHilalH3WakeStateRoot ($wakeId+'.json')) -Encoding UTF8}
        if(Test-Path -LiteralPath $radioHilalH3WakeMirrorRoot -PathType Container){
          $wakeFailureJson|Set-Content -LiteralPath $radioHilalH3WakeMirrorPath -Encoding UTF8
        }
      }catch{}
    }
  }

# MOVIERECOMMENDER_STREMIO_POSTSYNC_HOOK_V1
  # Fixed typed request only. Runs before nonessential runtime hooks so updater
  # contention elsewhere cannot starve MovieRecommender acceptance.
  $movieRecommenderRunner=Join-Path $InstallRoot 'afz-openai-agent\\Invoke-MovieRecommender-Stremio-Rebind.ps1'
  if(Test-Path -LiteralPath $movieRecommenderRunner -PathType Leaf){
    try{
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $movieRecommenderRunner -InstallRoot $InstallRoot *> $null
    }catch{}
  }


# MOVIERECOMMENDER_CATALOG_AUDIT_POSTSYNC_HOOK_V1
  # Read-only one-shot audit of the fixed MovieRecommender Stremio sidecar.
  $movieCatalogAuditRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-MovieRecommender-Catalog-Audit.ps1'
  if(Test-Path -LiteralPath $movieCatalogAuditRunner -PathType Leaf){
    try{
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $movieCatalogAuditRunner -InstallRoot $InstallRoot *> $null
    }catch{}
  }

# Narrow Blog runtime persistence hook. The helper is SYSTEM-only and
# fail-closed: it requires a clean canonical Blog checkout and existing
# successful .next build before it may recreate the exact Blog Manager task.
# Failure is isolated from source sync and is mirrored by the helper itself.
$blogRuntimeEnsure=Join-Path $InstallRoot 'afz-openai-agent\Ensure-AFZ-BlogManager-Runtime.ps1'
if(Test-Path -LiteralPath $blogRuntimeEnsure -PathType Leaf){
  try{& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $blogRuntimeEnsure *> $null}catch{}
}


# Exact-SHA AFZ Blog production deployment is request-gated, one-shot,
# SYSTEM-only, and rollback-protected. The helper blocks database/schema
# changes and website publication, and mirrors its own terminal result.
$blogProductionDeploy=Join-Path $InstallRoot 'afz-openai-agent\Invoke-AFZBlog-ProductionDeploy.ps1'
$blogProductionDeployRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-production-deploy.json'
if((Test-Path -LiteralPath $blogProductionDeploy -PathType Leaf) -and (Test-Path -LiteralPath $blogProductionDeployRequest -PathType Leaf)){
  try{
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $blogProductionDeploy -InstallRoot $InstallRoot -RequestPath $blogProductionDeployRequest *> $null
  }catch{}
}

  $allowFile=Join-Path $InstallRoot 'afz-openai-agent\allowed-clients.txt'
  $wrapper=Join-Path $InstallRoot 'afz-openai-agent\Start-AFZ-OpenAI-Agent.ps1'
  $control=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Agent-Control.ps1'
  $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
  $pushWatcher=Join-Path $InstallRoot 'afz-openai-agent\Push-Deploy-Watcher.ps1'
  $benchmarkRelay=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-Qwen27B-WebsiteBenchmark.ps1'
  $benchmarkRequestWatcher=Join-Path $InstallRoot 'afz-openai-agent\H3-Qwen27B-Request-Watcher.ps1'
  $siteDeployRequestWatcher=Join-Path $InstallRoot 'afz-openai-agent\AFZ-Site-Deploy-Request-Watcher.ps1'
  $siteDeployExecutor=Join-Path $InstallRoot 'afz-openai-agent\Deploy-AFZ-WebsiteToPi.ps1'
  $familyPttEdgeWatcher=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Edge-Preflight-Watcher-R12.ps1'
  $familyPttProvisionWatcher=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Edge-Provision-Watcher-R17.ps1'
  $familyPttProvisionExecutor=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Edge-Provision-R17.ps1'
  $prospectModule=Join-Path $InstallRoot 'afz-openai-agent\prospect-engine\ProspectEngine.ps1'
  $prospectUi=Join-Path $InstallRoot 'afz-openai-agent\prospect-engine\index.html'
  foreach($p in @($allowFile,$wrapper,$control,$updater,$pushWatcher,$benchmarkRelay,$benchmarkRequestWatcher,$siteDeployRequestWatcher,$siteDeployExecutor,$familyPttEdgeWatcher,$familyPttProvisionWatcher,$familyPttProvisionExecutor,$prospectModule,$prospectUi)){if(-not(Test-Path $p)){throw "Required agent file missing after sync: $p"}}

  # The push watcher is a long-lived PowerShell process. Updating its script on disk
  # does not update the already-running AST. Track the installed watcher hash and let
  # only the independent fallback updater restart it when the source hash changes.
  # Exact-SHA updater passes invoked by the watcher itself must never stop their parent.
  $pushWatcherSourceHash=(Get-FileHash -LiteralPath $pushWatcher -Algorithm SHA256).Hash.ToLowerInvariant()
  $pushWatcherAppliedHash=''
  if(Test-Path -LiteralPath $pushWatcherHashMarker -PathType Leaf){
    try{$pushWatcherAppliedHash=([string](Get-Content -LiteralPath $pushWatcherHashMarker -Raw -Encoding ASCII)).Trim().ToLowerInvariant()}catch{}
  }
  $pushWatcherNeedsRefresh=([string]::IsNullOrWhiteSpace($ExpectedSha) -and $pushWatcherAppliedHash -ne $pushWatcherSourceHash)

  $ips=@(Get-Content -LiteralPath $allowFile | ForEach-Object {$_.Trim()} | Where-Object {$_ -and -not $_.StartsWith('#') -and $_ -match '^100\.(?:\d{1,3}\.){2}\d{1,3}$'} | Sort-Object -Unique)
  if($ips.Count -eq 0){throw 'No Tailscale client IPs configured'}

  $agentFw=Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue
  $controlFw=Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -ErrorAction SilentlyContinue
  $controlFwHasDeploySubnet=$false
  if($controlFw){
    try{
      $controlRemote=@(($controlFw|Get-NetFirewallAddressFilter -ErrorAction Stop).RemoteAddress)
      $controlFwHasDeploySubnet=(([string]::Join(',',@($controlRemote))) -match '100\.64\.0\.0')
    }catch{}
  }
  if($changed -or -not $agentFw -or -not $controlFw -or -not $controlFwHasDeploySubnet){
    Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - HP Tailscale' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $controlRemoteAddresses=@($ips)
    $controlRemoteAddresses+='100.64.0.0/10'
    $controlRemoteAddresses=@($controlRemoteAddresses|Sort-Object -Unique)
    New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8796 -RemoteAddress $ips -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName 'AFZ OpenAI Agent Control - Tailscale Fleet' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8797 -RemoteAddress $controlRemoteAddresses -Profile Any | Out-Null
  }

  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $serviceSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

  $agentTaskName='AFZ OpenAI Agent'
  $agentAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -InstallRoot `"$InstallRoot`" -Port 8796 -BindHost `"100.70.25.8`""
  $agentTask=Get-ScheduledTask -TaskName $agentTaskName -ErrorAction SilentlyContinue
  if($agentTask){Set-ScheduledTask -TaskName $agentTaskName -Action $agentAction | Out-Null}else{Register-ScheduledTask -TaskName $agentTaskName -Action $agentAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $controlTaskName='AFZ OpenAI Agent Control'
  $controlAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$control`" -InstallRoot `"$InstallRoot`" -Port 8797 -BindHost `"100.70.25.8`""
  $controlTask=Get-ScheduledTask -TaskName $controlTaskName -ErrorAction SilentlyContinue
  if($controlTask){Set-ScheduledTask -TaskName $controlTaskName -Action $controlAction | Out-Null}else{Register-ScheduledTask -TaskName $controlTaskName -Action $controlAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $pushWatcherTaskName='AFZ OpenAI Agent Push Deploy Watcher'
  $pushWatcherAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$pushWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 3"
  $pushWatcherTask=Get-ScheduledTask -TaskName $pushWatcherTaskName -ErrorAction SilentlyContinue
  if($pushWatcherTask){Set-ScheduledTask -TaskName $pushWatcherTaskName -Action $pushWatcherAction | Out-Null}else{Register-ScheduledTask -TaskName $pushWatcherTaskName -Action $pushWatcherAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $benchmarkWatcherTaskName='AFZ H3 Qwen27B Request Watcher'
  $benchmarkWatcherAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$benchmarkRequestWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $benchmarkWatcherTask=Get-ScheduledTask -TaskName $benchmarkWatcherTaskName -ErrorAction SilentlyContinue
  if($benchmarkWatcherTask){Set-ScheduledTask -TaskName $benchmarkWatcherTaskName -Action $benchmarkWatcherAction | Out-Null}else{Register-ScheduledTask -TaskName $benchmarkWatcherTaskName -Action $benchmarkWatcherAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $siteWatcherTaskName='AFZ Website Git Deploy Request Watcher'
  $siteWatcherAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$siteDeployRequestWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $siteWatcherTask=Get-ScheduledTask -TaskName $siteWatcherTaskName -ErrorAction SilentlyContinue
  if($siteWatcherTask){Set-ScheduledTask -TaskName $siteWatcherTaskName -Action $siteWatcherAction | Out-Null}else{Register-ScheduledTask -TaskName $siteWatcherTaskName -Action $siteWatcherAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $familyPttEdgeTaskName='AFZ FamilyPTT Edge Preflight Watcher R12'
  $familyPttEdgeTaskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$familyPttEdgeWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $familyPttEdgeTask=Get-ScheduledTask -TaskName $familyPttEdgeTaskName -ErrorAction SilentlyContinue
  if($familyPttEdgeTask){Set-ScheduledTask -TaskName $familyPttEdgeTaskName -Action $familyPttEdgeTaskAction | Out-Null}else{Register-ScheduledTask -TaskName $familyPttEdgeTaskName -Action $familyPttEdgeTaskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $familyPttProvisionTaskName='AFZ FamilyPTT Edge Provision Watcher R17'
  $familyPttProvisionTaskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$familyPttProvisionWatcher`" -InstallRoot `"$InstallRoot`" -IntervalSeconds 5"
  $familyPttProvisionTask=Get-ScheduledTask -TaskName $familyPttProvisionTaskName -ErrorAction SilentlyContinue
  if($familyPttProvisionTask){Set-ScheduledTask -TaskName $familyPttProvisionTaskName -Action $familyPttProvisionTaskAction | Out-Null}else{Register-ScheduledTask -TaskName $familyPttProvisionTaskName -Action $familyPttProvisionTaskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $serviceSettings -Principal $principal -Force | Out-Null;$changed=$true}

  $updaterTaskName='AFZ OpenAI Agent Updater'
  $updaterAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$updater`" -InstallRoot `"$InstallRoot`""
  $updaterTrigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $updaterSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  $updaterTask=Get-ScheduledTask -TaskName $updaterTaskName -ErrorAction SilentlyContinue
  if($updaterTask){Set-ScheduledTask -TaskName $updaterTaskName -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings | Out-Null}else{Register-ScheduledTask -TaskName $updaterTaskName -Action $updaterAction -Trigger $updaterTrigger -Settings $updaterSettings -Principal $principal -Force | Out-Null}

  function Ensure-Running([string]$taskName,[bool]$restart){
    $t=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if(-not $t){return}
    if($restart){try{Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}catch{};Start-Sleep -Milliseconds 700;Start-ScheduledTask -TaskName $taskName}
    elseif($t.State -ne 'Running'){Start-ScheduledTask -TaskName $taskName}
  }
  # CONTROL_PARENT_SAFE_REFRESH_V1
  # Exact-SHA updates may be spawned by the Control service itself. Restarting
  # that parent task inline can deadlock while Task Scheduler waits for this
  # child updater to exit. Persist a marker and let the independent fallback
  # updater perform the restart on its next pass.
  $controlRefreshMarker=Join-Path $stateRoot 'control-refresh.pending'
  $controlRefreshPending=(Test-Path -LiteralPath $controlRefreshMarker -PathType Leaf)
  if($ExpectedSha){
    if($changed){
      try{Set-Content -LiteralPath $controlRefreshMarker -Value $remoteSha -Encoding ASCII}catch{}
      $controlRefreshPending=$true
    }
    $controlRestartNow=$false
  }else{
    $controlRestartNow=($changed -or $controlRefreshPending)
  }

  Ensure-Running $agentTaskName $changed
  Ensure-Running $controlTaskName $controlRestartNow
  if((-not $ExpectedSha) -and $controlRestartNow -and (Test-Path -LiteralPath $controlRefreshMarker -PathType Leaf)){
    Remove-Item -LiteralPath $controlRefreshMarker -Force -ErrorAction SilentlyContinue
  }
  $pushWatcherRestarted=$false
  if($pushWatcherNeedsRefresh){
    Ensure-Running $pushWatcherTaskName $true
    Set-Content -LiteralPath $pushWatcherHashMarker -Value $pushWatcherSourceHash -Encoding ASCII
    $pushWatcherRestarted=$true
  }else{
    Ensure-Running $pushWatcherTaskName $false
  }
  Ensure-Running $benchmarkWatcherTaskName $changed
  Ensure-Running $siteWatcherTaskName $changed
  $familyPttCarrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
  $safeToRefreshFamilyPttWatchers=($changed -and (-not $familyPttCarrier -or [string]$familyPttCarrier.State -ne 'Running'))
  Ensure-Running $familyPttEdgeTaskName $safeToRefreshFamilyPttWatchers
  Ensure-Running $familyPttProvisionTaskName $safeToRefreshFamilyPttWatchers

  $trigger=$(if($ExpectedSha){'fast-signal-exact-sha'}else{'fallback-poll'})
  $pushTaskState=[string](Get-ScheduledTask -TaskName $pushWatcherTaskName -ErrorAction SilentlyContinue).State
  $siteTaskState=[string](Get-ScheduledTask -TaskName $siteWatcherTaskName -ErrorAction SilentlyContinue).State
  $familyPttEdgeTaskState=[string](Get-ScheduledTask -TaskName $familyPttEdgeTaskName -ErrorAction SilentlyContinue).State
  $familyPttProvisionTaskState=[string](Get-ScheduledTask -TaskName $familyPttProvisionTaskName -ErrorAction SilentlyContinue).State
  Write-TransportDiagnosticAck $remoteSha $ExpectedSha $trigger $pushTaskState $siteTaskState

  $result=[ordered]@{ok=$true;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o);remoteSha=$remoteSha;expectedSha=$(if($ExpectedSha){$ExpectedSha}else{$null});trigger=$trigger;changed=$changed;fastSignalIntervalSeconds=3;fallbackCadenceSeconds=60;agentPort=8796;controlPort=8797;pushDeployWatcherTask=$pushWatcherTaskName;pushDeployWatcherState=$pushTaskState;pushWatcherSourceHash=$pushWatcherSourceHash;pushWatcherAppliedHash=$pushWatcherAppliedHash;pushWatcherRestarted=$pushWatcherRestarted;benchmarkRequestWatcherTask=$benchmarkWatcherTaskName;siteDeployRequestWatcherTask=$siteWatcherTaskName;siteDeployRequestWatcherState=$siteTaskState;familyPttEdgePreflightWatcherTask=$familyPttEdgeTaskName;familyPttEdgePreflightWatcherState=$familyPttEdgeTaskState;familyPttEdgeProvisionWatcherTask=$familyPttProvisionTaskName;familyPttEdgeProvisionWatcherState=$familyPttProvisionTaskState;diagnosticAck='OneDrive emergency observability only';clients=$ips;transport=[string]$syncResult.refTransport}
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusFile -Encoding UTF8
} catch {
  $result=[ordered]@{ok=$false;startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o);expectedSha=$(if($ExpectedSha){$ExpectedSha}else{$null});error=$_.Exception.Message}
  $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $statusFile -Encoding UTF8
  throw
} finally {
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
