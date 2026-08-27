#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$RunJellyfinDiagnosis
)
$ErrorActionPreference='Stop'
$repo='https://github.com/f3arif/homelab-control.git'
$logDir='C:\AFZ\Logs'
$logFile=Join-Path $logDir 'AFZ-OpenAI-Agent-Repair-LATEST.log'
$resultFile=Join-Path $logDir 'AFZ-OpenAI-Agent-Repair-LATEST.json'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
Start-Transcript -LiteralPath $logFile -Force | Out-Null
$stage='startup'
$result=[ordered]@{ok=$false;stage=$stage;startedAt=(Get-Date -Format o);installRoot=$InstallRoot;error=$null}

function Save-Result {
  param([bool]$Ok,[string]$Stage,[string]$ErrorMessage=$null)
  $result.ok=$Ok
  $result.stage=$Stage
  $result.error=$ErrorMessage
  $result.finishedAt=(Get-Date -Format o)
  try{$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding UTF8}catch{}
}

try {
  Write-Host 'AFZ OpenAI Agent self-healing repair' -ForegroundColor Cyan
  Write-Host "Persistent log: $logFile"
  Write-Host "Result file:    $resultFile"

  $stage='locate-git'
  $git=(Get-Command git.exe -ErrorAction Stop).Source
  Write-Host "Git: $git"

  $stage='refresh-repository'
  if(Test-Path (Join-Path $InstallRoot '.git')){
    Write-Host "Refreshing existing checkout: $InstallRoot"
    & $git -C $InstallRoot checkout -- 'afz-openai-agent/AFZ-OpenAI-Agent-v2.ps1' 2>$null
    & $git -C $InstallRoot fetch origin main
    if($LASTEXITCODE -ne 0){throw 'git fetch failed'}
    & $git -C $InstallRoot checkout main
    if($LASTEXITCODE -ne 0){throw 'git checkout main failed'}
    & $git -C $InstallRoot pull --ff-only origin main
    if($LASTEXITCODE -ne 0){throw 'git pull --ff-only failed; unrelated local changes were preserved'}
  }else{
    if(Test-Path $InstallRoot){
      $items=@(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
      if($items.Count -gt 0){throw "$InstallRoot exists but is not a git checkout. Repair will not delete or overwrite it."}
    }else{
      New-Item -ItemType Directory -Force -Path (Split-Path $InstallRoot -Parent) | Out-Null
    }
    Write-Host "Cloning $repo -> $InstallRoot"
    & $git clone $repo $InstallRoot
    if($LASTEXITCODE -ne 0){throw 'git clone failed'}
  }

  $stage='validate-installer'
  $installer=Join-Path $InstallRoot 'afz-openai-agent\Install-AFZ-OpenAI-Agent.ps1'
  if(-not(Test-Path $installer)){throw "Installer missing after refresh: $installer"}

  $stage='remove-stale-tasks'
  foreach($name in @('AFZ OpenAI Agent','AFZ OpenAI Agent Updater','AFZ OpenAI Agent Control')){
    $t=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if($t){
      $missing=$false
      foreach($a in @($t.Actions)){
        if($a.Execute -and $a.Execute -notmatch '(?i)^powershell(?:\.exe)?$' -and -not(Test-Path $a.Execute)){$missing=$true}
        if($a.Arguments -match '(?i)-File\s+"?([^"\s]+(?:\.ps1))'){
          $target=$matches[1]
          if(-not(Test-Path $target)){$missing=$true}
        }
      }
      if($missing){
        Write-Host "Removing stale scheduled task: $name" -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
      }
    }
  }

  $stage='run-installer'
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$installer)
  if($RunJellyfinDiagnosis){$args += '-RunJellyfinDiagnosis'}
  & powershell.exe @args
  if($LASTEXITCODE -ne 0){throw "Installer exited with code $LASTEXITCODE"}

  $stage='apply-updater-policy'
  $updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
  if(-not(Test-Path $updater)){throw "Updater missing after install: $updater"}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -InstallRoot $InstallRoot
  if($LASTEXITCODE -ne 0){throw "Updater exited with code $LASTEXITCODE"}

  $stage='health-check'
  Start-Sleep 3
  $checks=@(
    @{name='Agent';uri='http://127.0.0.1:8796/health'},
    @{name='Control';uri='http://127.0.0.1:8797/health'}
  )
  $allOk=$true
  $health=@()
  foreach($c in $checks){
    try{
      $r=Invoke-RestMethod -Uri $c.uri -TimeoutSec 8
      Write-Host ("{0}: ONLINE {1}" -f $c.name,$r.version) -ForegroundColor Green
      $health += [ordered]@{name=$c.name;ok=$true;version=$r.version;uri=$c.uri}
    }catch{
      $allOk=$false
      Write-Warning ("{0}: health check failed: {1}" -f $c.name,$_.Exception.Message)
      $health += [ordered]@{name=$c.name;ok=$false;error=$_.Exception.Message;uri=$c.uri}
    }
  }
  $result.health=$health

  Write-Host ''
  Write-Host 'Scheduled tasks:' -ForegroundColor Cyan
  $tasks=@(Get-ScheduledTask -TaskName 'AFZ OpenAI Agent*' -ErrorAction SilentlyContinue | Select-Object TaskName,State)
  $tasks | Format-Table -AutoSize
  $result.tasks=$tasks
  Write-Host 'Agent UI:    http://127.0.0.1:8796/'
  Write-Host 'Control UI:  http://127.0.0.1:8797/'
  Write-Host 'H3 access:   http://100.70.25.8:8796/'

  if(-not $allOk){throw 'One or more health checks failed'}
  Save-Result $true 'complete'
  Write-Host ''
  Write-Host 'REPAIR COMPLETE' -ForegroundColor Green
  Write-Host "Result: $resultFile"
}
catch {
  $msg=$_.Exception.Message
  Save-Result $false $stage $msg
  Write-Host ''
  Write-Host 'REPAIR FAILED' -ForegroundColor Red
  Write-Host "Stage: $stage" -ForegroundColor Yellow
  Write-Host "Error: $msg" -ForegroundColor Red
  Write-Host "Log:   $logFile"
  Write-Host "Result:$resultFile"
  exit 1
}
finally {
  try{Stop-Transcript | Out-Null}catch{}
}
