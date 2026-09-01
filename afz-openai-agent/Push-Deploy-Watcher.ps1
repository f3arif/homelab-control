#Requires -Version 5.1
# HOTRELOAD_CANARY=20260901T0147Z hermes-r3-runtime-refresh
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [int]$IntervalSeconds=3
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$IntervalSeconds=[math]::Max(2,[math]::Min($IntervalSeconds,30))
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent'
$sourceState=Join-Path $stateRoot 'source-state.json'
$watchState=Join-Path $stateRoot 'push-watcher.json'
$logRoot=Join-Path $stateRoot 'logs'
$logFile=Join-Path $logRoot 'push-watcher.log'
$r17RefreshMarker=Join-Path $stateRoot 'familyptt-r17-watcher-source.txt'
$signalBase='https://raw.githubusercontent.com/f3arif/homelab-control/main/.github/afz-agent-deploy-signal.txt'
$compareBase='https://api.github.com/repos/f3arif/homelab-control/compare'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'AFZ-GITHUB-TRANSPORT-ACK-LATEST.json'
$runtimeProofFile=Join-Path $diagRoot 'AFZ-PUSH-WATCHER-RUNTIME-LATEST.txt'
$sharedDiagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$runtimeProofSharedFile=Join-Path $sharedDiagRoot 'AFZ-PUSH-WATCHER-RUNTIME-LATEST.txt'
$jellyfinRequestRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Jellyfin-Visibility-Request.ps1'
$familyPttPhase1ApkRunner=Join-Path $InstallRoot 'afz-openai-agent\FamilyPTT-Phase1-ApkPrepare.ps1'
$familyPttPhase1ApkRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-phase1-apk-prepare.json'
$familyPttPhase1LastAttempt=[DateTime]::MinValue
$hpEnvySurfsharkRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Surfshark-ExitNode.ps1'
$hpEnvySurfsharkRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\hpenvy-surfshark-exitnode.json'
$hpEnvySurfsharkStateRoot=Join-Path $stateRoot 'jobs\hpenvy-surfshark-exitnode'
$h3HermesRunner=Join-Path $InstallRoot 'afz-openai-agent\Invoke-H3-HermesAgent-Install.ps1'
$h3HermesRequest=Join-Path $InstallRoot 'afz-openai-agent\requests\h3-hermes-agent-install.json'
$h3HermesStateRoot=Join-Path $stateRoot 'jobs\h3-hermes-agent'
$h3HermesLastAttempt=[DateTime]::MinValue
New-Item -ItemType Directory -Force -Path $stateRoot,$logRoot | Out-Null
function Log([string]$m){Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $m" -Encoding UTF8}
function Current-Sha{
  if(Test-Path $sourceState){try{return ([string]((Get-Content $sourceState -Raw|ConvertFrom-Json).remoteSha)).Trim().ToLowerInvariant()}catch{}}
  return ''
}
function Handled-Signal{
  if(Test-Path $watchState){
    try{
      $s=Get-Content $watchState -Raw|ConvertFrom-Json
      if($s.status -in @('idle','deployed') -and ([string]$s.signalSha) -match '^[0-9a-fA-F]{40}$'){return ([string]$s.signalSha).ToLowerInvariant()}
    }catch{}
  }
  return ''
}
function Current-ContainsSignal([string]$Current,[string]$Signal){
  if($Current -notmatch '^[0-9a-f]{40}$' -or $Signal -notmatch '^[0-9a-f]{40}$'){return $false}
  if($Current -eq $Signal){return $true}
  try{
    $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $headers=@{'User-Agent'='AFZ-Push-Watcher';'Cache-Control'='no-cache';'Pragma'='no-cache';'Accept'='application/vnd.github+json'}
    $pair=("{0}...{1}" -f $Signal,$Current)
    $compare=Invoke-RestMethod -Uri ($compareBase+'/'+$pair+'?nocache='+$nonce) -Headers $headers -TimeoutSec 15
    $status=([string]$compare.status).ToLowerInvariant()
    return ($status -in @('ahead','identical'))
  }catch{
    Log "ANCESTRY_CHECK_ERROR signal=$Signal current=$Current error=$($_.Exception.Message)"
    return $false
  }
}
function Save-State([string]$signal,[string]$status,[string]$message){
  [ordered]@{ok=($status -eq 'idle' -or $status -eq 'deployed');signalSha=$signal;currentSha=(Current-Sha);status=$status;message=$message;intervalSeconds=$IntervalSeconds;time=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $watchState -Encoding UTF8
}
function Read-DiagJson([string]$path){
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
  try{return Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return [ordered]@{readError=$_.Exception.Message}}
}
function Refresh-FamilyPttR17IfSafe{
  try{
    $requestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\familyptt-edge-provision-r17.json'
    if(-not(Test-Path -LiteralPath $requestPath -PathType Leaf)){return}
    $req=Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$req.action -ne 'edge-provision' -or [string]$req.job_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'){return}
    $r17State=Read-DiagJson 'C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-edge-provision-r17\latest.json'
    if($r17State -and [string]$r17State.jobId -eq [string]$req.job_id -and [string]$r17State.status -in @('arming','rtc-remediating','running','completed','failed')){return}
    $sha=Current-Sha
    if($sha -notmatch '^[0-9a-f]{40}$'){return}
    $prior='';if(Test-Path -LiteralPath $r17RefreshMarker -PathType Leaf){$prior=([string](Get-Content -LiteralPath $r17RefreshMarker -Raw -Encoding UTF8)).Trim().ToLowerInvariant()}
    if($prior -eq $sha){return}
    $carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
    if($carrier -and [string]$carrier.State -eq 'Running'){return}
    $taskName='AFZ FamilyPTT Edge Provision Watcher R17'
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if(-not $task){return}
    if([string]$task.State -eq 'Running'){
      Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
      Start-Sleep -Milliseconds 600
    }
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Set-Content -LiteralPath $r17RefreshMarker -Value $sha -Encoding ASCII
    Log "FAMILYPTT_R17_REFRESH job=$($req.job_id) source=$sha"
    Save-DiagnosticAck '' 'familyptt-r17-refreshed' "R17 watcher refreshed for job=$($req.job_id) source=$sha"
  }catch{Log "FAMILYPTT_R17_REFRESH_ERROR $($_.Exception.Message)"}
}
function Save-DiagnosticAck([string]$signal,[string]$status,[string]$message){
  # OneDrive is emergency observability only. It is never read as a control/request
  # input and failure to sync/write it does not affect the GitHub control path.
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $pushTask=Get-ScheduledTask -TaskName 'AFZ OpenAI Agent Push Deploy Watcher' -ErrorAction SilentlyContinue
    $siteTask=Get-ScheduledTask -TaskName 'AFZ Website Git Deploy Request Watcher' -ErrorAction SilentlyContinue
    $r17Task=Get-ScheduledTask -TaskName 'AFZ FamilyPTT Edge Provision Watcher R17' -ErrorAction SilentlyContinue
    $r12Task=Get-ScheduledTask -TaskName 'AFZ FamilyPTT Edge Preflight Watcher R12' -ErrorAction SilentlyContinue
    $carrier=Get-ScheduledTask -TaskName 'AFZ Edge Backup' -ErrorAction SilentlyContinue
    $r17State=Read-DiagJson 'C:\ProgramData\AFZ\OpenAIAgent\jobs\familyptt-edge-provision-r17\latest.json'
    $r12Result=Read-DiagJson 'C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgePreflight\latest.json'
    $rtcResult=Read-DiagJson 'C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTRtcRemediation\latest.json'
    $r17Result=Read-DiagJson 'C:\Users\Faiz\AppData\Local\AFZ\FamilyPTTEdgeProvision\latest.json'
    [ordered]@{
      schema=1
      purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
      source='windows-main'
      controlPlane='github'
      component='AFZ OpenAI Agent Push Deploy Watcher'
      signalSha=$(if($signal){$signal}else{$null})
      currentSha=(Current-Sha)
      status=$status
      message=$message
      pushWatcherTaskState=$(if($pushTask){[string]$pushTask.State}else{'missing'})
      siteWatcherTaskState=$(if($siteTask){[string]$siteTask.State}else{'missing'})
      familyPttR17TaskState=$(if($r17Task){[string]$r17Task.State}else{'missing'})
      familyPttR12TaskState=$(if($r12Task){[string]$r12Task.State}else{'missing'})
      edgeBackupCarrierState=$(if($carrier){[string]$carrier.State}else{'missing'})
      familyPttR17State=$r17State
      familyPttR12Result=$r12Result
      familyPttRtcResult=$rtcResult
      familyPttR17Result=$r17Result
      processId=$PID
      time=(Get-Date -Format o)
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $diagFile -Encoding UTF8
  }catch{}
}
function Save-RuntimeProof{
  # Startup-only emergency observability. These files are never consumed as control
  # input and record no secrets; they only prove which watcher script is in memory.
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container) -and -not(Test-Path -LiteralPath $sharedDiagRoot -PathType Container)){return}
    $task=Get-ScheduledTask -TaskName 'AFZ OpenAI Agent Push Deploy Watcher' -ErrorAction SilentlyContinue
    $proc=Get-Process -Id $PID -ErrorAction SilentlyContinue
    $scriptHash=$null
    if($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)){
      $scriptHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $phase1RequestStatus=$null
    try{
      if(Test-Path -LiteralPath $familyPttPhase1ApkRequest -PathType Leaf){
        $phase1RequestStatus=[string]((Get-Content -LiteralPath $familyPttPhase1ApkRequest -Raw -Encoding UTF8|ConvertFrom-Json).status)
      }
    }catch{}
    $proof=[ordered]@{
      schema=1
      purpose='EMERGENCY_DIAGNOSTIC_ACK_ONLY'
      source='windows-main'
      controlPlane='github'
      component='AFZ OpenAI Agent Push Deploy Watcher Runtime Proof'
      currentSha=(Current-Sha)
      processId=$PID
      processStartTime=$(if($proc){$proc.StartTime.ToString('o')}else{$null})
      scriptPath=$PSCommandPath
      scriptSha256=$scriptHash
      intervalSeconds=$IntervalSeconds
      taskState=$(if($task){[string]$task.State}else{'missing'})
      familyPttPhase1Binding='typed-active-only'
      familyPttPhase1RequestStatus=$phase1RequestStatus
      h3HermesBinding='typed-fixed-target-no-generation'
      time=(Get-Date -Format o)
    }
    $json=$proof|ConvertTo-Json -Depth 5
    if(Test-Path -LiteralPath $diagRoot -PathType Container){
      $json | Set-Content -LiteralPath $runtimeProofFile -Encoding UTF8
    }
    if(Test-Path -LiteralPath $sharedDiagRoot -PathType Container){
      [IO.File]::WriteAllText($runtimeProofSharedFile,$json,(New-Object Text.UTF8Encoding($false)))
    }
  }catch{}
}
function Invoke-UpdaterPass([string]$Updater,[string]$Sha,[int]$Pass){
  Log "UPDATER_PASS_START pass=$Pass signal=$Sha"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Updater -InstallRoot $InstallRoot -ExpectedSha $Sha *> $null
  $code=$LASTEXITCODE
  Log "UPDATER_PASS_DONE pass=$Pass signal=$Sha exit=$code source=$(Current-Sha)"
  return $code
}
function Handle-JellyfinVisibilityRequest{
  if(-not(Test-Path -LiteralPath $jellyfinRequestRunner -PathType Leaf)){return}
  try{
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $jellyfinRequestRunner -InstallRoot $InstallRoot *> $null
    if($LASTEXITCODE -ne 0){Log "JELLYFIN_VISIBILITY_REQUEST_ERROR exit=$LASTEXITCODE source=$(Current-Sha)"}
  }catch{Log "JELLYFIN_VISIBILITY_REQUEST_ERROR $($_.Exception.Message)"}
}
function Handle-HPEnvySurfsharkRequest{
  if(-not(Test-Path -LiteralPath $hpEnvySurfsharkRunner -PathType Leaf)){return}
  if(-not(Test-Path -LiteralPath $hpEnvySurfsharkRequest -PathType Leaf)){return}
  try{
    $req=Get-Content -LiteralPath $hpEnvySurfsharkRequest -Raw -Encoding UTF8|ConvertFrom-Json
    $id=([string]$req.id).Trim()
    $mode=([string]$req.mode).Trim().ToLowerInvariant()
    if([int]$req.schema -ne 1){return}
    if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){return}
    if([string]$req.taskName -ne 'HP Envy Surfshark Exit Node'){return}
    if([string]$req.target -ne 'coolyo@100.71.26.69'){return}
    if($mode -notin @('audit','apply')){return}
    $statePath=Join-Path $hpEnvySurfsharkStateRoot ($id+'.json')
    if(Test-Path -LiteralPath $statePath -PathType Leaf){
      try{
        $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
        if([string]$existing.classification -match '^(AUDIT_|APPLY_)'){return}
      }catch{}
    }
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hpEnvySurfsharkRunner -InstallRoot $InstallRoot -RequestPath $hpEnvySurfsharkRequest 2>&1|Out-String).Trim()
    $code=$LASTEXITCODE
    $classification='NO_CLASSIFICATION'
    if(-not [string]::IsNullOrWhiteSpace($raw)){
      try{$classification=[string](($raw|ConvertFrom-Json).classification)}catch{}
    }
    Log "HPENVY_SURFSHARK_REQUEST mode=$mode classification=$classification exit=$code source=$(Current-Sha)"
  }catch{Log "HPENVY_SURFSHARK_REQUEST_ERROR $($_.Exception.Message)"}
}
function Handle-H3HermesRequest{
  if(-not(Test-Path -LiteralPath $h3HermesRunner -PathType Leaf)){return}
  if(-not(Test-Path -LiteralPath $h3HermesRequest -PathType Leaf)){return}
  try{
    $req=Get-Content -LiteralPath $h3HermesRequest -Raw -Encoding UTF8|ConvertFrom-Json
    $id=([string]$req.id).Trim()
    if([int]$req.schema -ne 1 -or [string]$req.action -ne 'install-and-configure' -or [string]$req.target -ne 'h3'){return}
    if([string]$req.host -ne 'DESKTOP-H3R6CQN' -or [string]$req.base_url -ne 'http://127.0.0.1:11434/v1'){return}
    if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){return}
    $statePath=Join-Path $h3HermesStateRoot ($id+'.json')
    if(Test-Path -LiteralPath $statePath -PathType Leaf){
      try{
        $existing=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
        if([bool]$existing.ok -and [string]$existing.classification -eq 'HERMES_READY_LOCAL_OLLAMA_64K'){return}
        if(-not [bool]$existing.retryable -and [string]$existing.classification -eq 'HERMES_SETUP_FAILED'){return}
      }catch{}
    }
    $now=Get-Date
    if(($now-$script:h3HermesLastAttempt).TotalSeconds -lt 60){return}
    $script:h3HermesLastAttempt=$now
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $h3HermesRunner -InstallRoot $InstallRoot -RequestPath $h3HermesRequest 2>&1|Out-String).Trim()
    $code=$LASTEXITCODE
    $classification='NO_CLASSIFICATION'
    if(-not [string]::IsNullOrWhiteSpace($raw)){
      try{$classification=[string](($raw|ConvertFrom-Json).classification)}catch{}
    }
    Log "H3_HERMES_REQUEST classification=$classification exit=$code source=$(Current-Sha)"
  }catch{Log "H3_HERMES_REQUEST_ERROR $($_.Exception.Message)"}
}
# BEGIN FAMILYPTT_PHASE1_APK_ACTIVE_BINDING
function Handle-FamilyPttPhase1ApkRequest{
  if(-not(Test-Path -LiteralPath $familyPttPhase1ApkRunner -PathType Leaf)){return}
  if(-not(Test-Path -LiteralPath $familyPttPhase1ApkRequest -PathType Leaf)){return}
  try{
    $req=Get-Content -LiteralPath $familyPttPhase1ApkRequest -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$req.schema -ne 1 -or [string]$req.project -ne 'familyptt' -or [string]$req.action -ne 'prepare-phase1-acceptance-apk'){return}
    if([string]$req.status -ne 'active'){return}
    $now=Get-Date
    if(($now-$script:familyPttPhase1LastAttempt).TotalSeconds -lt 10){return}
    $script:familyPttPhase1LastAttempt=$now
    $raw=(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $familyPttPhase1ApkRunner -InstallRoot $InstallRoot -RequestPath $familyPttPhase1ApkRequest 2>&1|Out-String).Trim()
    $code=$LASTEXITCODE
    if($code -ne 0){
      Log "FAMILYPTT_PHASE1_APK_REQUEST_ERROR exit=$code source=$(Current-Sha) output=$raw"
      return
    }
    if(-not [string]::IsNullOrWhiteSpace($raw)){
      try{
        $result=$raw|ConvertFrom-Json
        Log "FAMILYPTT_PHASE1_APK_REQUEST status=$([string]$result.status) job=$([string]$result.jobId) source=$(Current-Sha)"
      }catch{Log "FAMILYPTT_PHASE1_APK_REQUEST_OK source=$(Current-Sha)"}
    }
  }catch{Log "FAMILYPTT_PHASE1_APK_REQUEST_ERROR $($_.Exception.Message)"}
}
# END FAMILYPTT_PHASE1_APK_ACTIVE_BINDING
$mutex=New-Object Threading.Mutex($false,'Global\AFZOpenAIAgentPushWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  $lastAttemptSha=''
  $lastAttempt=[DateTime]::MinValue
  $lastError=''
  Log "START interval=${IntervalSeconds}s transport=github-fast-signal updater_bootstrap=two-pass persistent_task=true monotonic=true jellyfinVisibilityRequest=typed-one-shot hpEnvySurfsharkRequest=typed-fixed-target familyPttPhase1ApkRequest=typed-active-only h3HermesRequest=typed-fixed-target-no-generation"
  Save-RuntimeProof
  Save-DiagnosticAck '' 'watcher-started' 'Persistent GitHub fast-signal consumer is running.'
  while($true){
    try{
      $nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $headers=@{'User-Agent'='AFZ-Push-Watcher';'Cache-Control'='no-cache';'Pragma'='no-cache'}
      $r=Invoke-WebRequest -Uri ($signalBase+'?nocache='+$nonce) -Headers $headers -UseBasicParsing -TimeoutSec 10
      $sha=([string]$r.Content).Trim().ToLowerInvariant()
      if($sha -notmatch '^[0-9a-f]{40}$'){throw "Invalid deploy signal: $sha"}
      $handled=Handled-Signal
      if($sha -ne $handled){
        $now=Get-Date
        if($sha -ne $lastAttemptSha -or ($now-$lastAttempt).TotalSeconds -ge 30){
          $lastAttemptSha=$sha;$lastAttempt=$now
          $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
          if(-not(Test-Path $updater)){throw "Updater missing: $updater"}
          $before=Current-Sha
          if(Current-ContainsSignal $before $sha){
            Save-State $sha 'deployed' "Signal already contained by current source=$before; downgrade skipped."
            Save-DiagnosticAck $sha 'source-already-newer' "Signal already contained by current source=$before; downgrade skipped."
            Log "DEPLOY_SKIP_ANCESTOR signal=$sha current=$before"
            $lastAttemptSha=''
          }else{
            Save-State $sha 'deploying' 'Exact-SHA two-pass update started.'
            Save-DiagnosticAck $sha 'signal-consumed' "Fast signal observed; source before update=$before"
            Log "DEPLOY signal=$sha current=$before"
            $code=Invoke-UpdaterPass $updater $sha 1
            if($code -eq 0){$code=Invoke-UpdaterPass $updater $sha 2}
            $after=Current-Sha
            if($code -eq 0 -and $after -eq $sha){
              Save-State $sha 'deployed' "Exact-SHA two-pass update completed. source=$after"
              Save-DiagnosticAck $sha 'source-synced' "Exact-SHA two-pass update completed; source=$after"
              Log "DEPLOY_OK signal=$sha source=$after passes=2"
              $lastAttemptSha=''
            }else{
              Save-State $sha 'failed' "Updater exit=$code current=$after expected=$sha"
              Save-DiagnosticAck $sha 'source-sync-failed' "Updater exit=$code current=$after expected=$sha"
              Log "DEPLOY_FAIL signal=$sha exit=$code current=$after expected=$sha"
            }
          }
        }
      }else{
        Save-State $sha 'idle' 'Deploy signal already handled.'
        $lastAttemptSha=''
      }
      Refresh-FamilyPttR17IfSafe
      Handle-JellyfinVisibilityRequest
      Handle-HPEnvySurfsharkRequest
      Handle-H3HermesRequest
      Handle-FamilyPttPhase1ApkRequest
      $lastError=''
    }catch{
      $msg=$_.Exception.Message
      if($msg -ne $lastError){Log "WATCH_ERROR $msg";Save-DiagnosticAck '' 'watch-error' $msg;$lastError=$msg}
      Save-State '' 'error' $msg
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
