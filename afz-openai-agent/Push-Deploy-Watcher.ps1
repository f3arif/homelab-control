#Requires -Version 5.1
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
$signalBase='https://raw.githubusercontent.com/f3arif/homelab-control/main/.github/afz-agent-deploy-signal.txt'
$compareBase='https://api.github.com/repos/f3arif/homelab-control/compare'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\ChatGPT_Termius'
$diagFile=Join-Path $diagRoot 'AFZ-GITHUB-TRANSPORT-ACK-LATEST.json'
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
function Save-DiagnosticAck([string]$signal,[string]$status,[string]$message){
  # OneDrive is emergency observability only. It is never read as a control/request
  # input and failure to sync/write it does not affect the GitHub control path.
  try{
    if(-not(Test-Path -LiteralPath $diagRoot -PathType Container)){return}
    $pushTask=Get-ScheduledTask -TaskName 'AFZ OpenAI Agent Push Deploy Watcher' -ErrorAction SilentlyContinue
    $siteTask=Get-ScheduledTask -TaskName 'AFZ Website Git Deploy Request Watcher' -ErrorAction SilentlyContinue
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
      processId=$PID
      time=(Get-Date -Format o)
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $diagFile -Encoding UTF8
  }catch{}
}
function Invoke-UpdaterPass([string]$Updater,[string]$Sha,[int]$Pass){
  Log "UPDATER_PASS_START pass=$Pass signal=$Sha"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Updater -InstallRoot $InstallRoot -ExpectedSha $Sha *> $null
  $code=$LASTEXITCODE
  Log "UPDATER_PASS_DONE pass=$Pass signal=$Sha exit=$code source=$(Current-Sha)"
  return $code
}
$mutex=New-Object Threading.Mutex($false,'Global\AFZOpenAIAgentPushWatcher')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){exit 0}
  $lastAttemptSha=''
  $lastAttempt=[DateTime]::MinValue
  $lastError=''
  Log "START interval=${IntervalSeconds}s transport=github-fast-signal updater_bootstrap=two-pass persistent_task=true monotonic=true"
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

          # A delayed/cached fast-signal must never roll a machine backward. If the
          # currently deployed source is already the signal itself or a Git
          # descendant of it, mark the signal handled without invoking the updater.
          if(Current-ContainsSignal $before $sha){
            Save-State $sha 'deployed' "Signal already contained by current source=$before; downgrade skipped."
            Save-DiagnosticAck $sha 'source-already-newer' "Signal already contained by current source=$before; downgrade skipped."
            Log "DEPLOY_SKIP_ANCESTOR signal=$sha current=$before"
            $lastAttemptSha=''
          }else{
            Save-State $sha 'deploying' 'Exact-SHA two-pass update started.'
            Save-DiagnosticAck $sha 'signal-consumed' "Fast signal observed; source before update=$before"
            Log "DEPLOY signal=$sha current=$before"

            # Pass 1 synchronizes the exact GitHub source. If that synchronization
            # replaces the updater itself, the already-running PowerShell process
            # still has the old updater AST in memory. Pass 2 starts a fresh process
            # from the newly synchronized updater so new task/registration logic is
            # applied on the same signal instead of waiting for a later commit.
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
