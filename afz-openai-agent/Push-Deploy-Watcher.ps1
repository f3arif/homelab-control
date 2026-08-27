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
function Save-State([string]$signal,[string]$status,[string]$message){
  [ordered]@{ok=($status -eq 'idle' -or $status -eq 'deployed');signalSha=$signal;currentSha=(Current-Sha);status=$status;message=$message;intervalSeconds=$IntervalSeconds;time=(Get-Date -Format o)} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $watchState -Encoding UTF8
}
$lastAttemptSha=''
$lastAttempt=[DateTime]::MinValue
$lastError=''
Log "START interval=${IntervalSeconds}s transport=github-fast-signal"
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
        Save-State $sha 'deploying' 'Exact-SHA update started.'
        Log "DEPLOY signal=$sha current=$before"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -InstallRoot $InstallRoot -ExpectedSha $sha *> $null
        $code=$LASTEXITCODE
        $after=Current-Sha
        if($code -eq 0){
          Save-State $sha 'deployed' "Exact-SHA update completed. source=$after"
          Log "DEPLOY_OK signal=$sha source=$after"
          $lastAttemptSha=''
        }else{
          Save-State $sha 'failed' "Updater exit=$code current=$after"
          Log "DEPLOY_FAIL signal=$sha exit=$code current=$after"
        }
      }
    }else{
      Save-State $sha 'idle' 'Deploy signal already handled.'
      $lastAttemptSha=''
    }
    $lastError=''
  }catch{
    $msg=$_.Exception.Message
    if($msg -ne $lastError){Log "WATCH_ERROR $msg";$lastError=$msg}
    Save-State '' 'error' $msg
  }
  Start-Sleep -Seconds $IntervalSeconds
}
