#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSiteSha,
  [Parameter(Mandatory=$true)][string]$JobId
)
$ErrorActionPreference='Stop'

# R3 was conclusively retired after its Windows-local archive step failed before
# any Pi promotion. A stale legacy Scheduled Task can still carry this exact
# one-time command. Fail it closed here, before resolving or invoking the deploy
# core, so an old trigger cannot repeatedly consume CPU/RAM or touch the Pi.
# This tombstone intentionally does not rewrite WebsiteGitDeploy\latest.json;
# the original R3 failure evidence remains available to the bounded recovery.
$retiredR3Job='afz-site-git-cutover-r3-20260827T2138'
$retiredR3Sha='c38576741ce2d379723fde038300363429845656'
if($JobId -eq $retiredR3Job -and $ExpectedSiteSha.Trim().ToLowerInvariant() -eq $retiredR3Sha){
  Write-Output 'AFZ_SITE_DEPLOY_RETIRED_R3: blocked before deploy core.'
  exit 42
}

# R6 reached the Pi but failed before promotion because the Windows-generated
# managed.sha256 carried CRLF into Bash path parsing. The failed request can
# remain on a Windows overlay install even after it is deleted from Git. Retire
# this exact one-time job here so loss/reset of watcher state cannot replay it.
# Like the R3 tombstone, this is intentionally non-mutating and runs before any
# deploy-core, SSH, SCP, archive, or Pi operation.
$retiredR6Job='afz-site-git-cutover-r6-20260828T1602'
$retiredR6Sha='c38576741ce2d379723fde038300363429845656'
if($JobId -eq $retiredR6Job -and $ExpectedSiteSha.Trim().ToLowerInvariant() -eq $retiredR6Sha){
  Write-Output 'AFZ_SITE_DEPLOY_RETIRED_R6: blocked before deploy core.'
  exit 42
}

# R7 reached the Pi promotion path, then Windows public verification failed when
# the deploy core assigned to the read-only automatic $HOME variable. The catch
# path rolled the remote promotion back and the watcher restored both carrier and
# legacy publisher. Permanently retire this exact failed job before any deploy
# core/SSH/SCP activity so a stale overlay request can never replay it.
$retiredR7Job='afz-site-git-cutover-r7-20260829T0030'
$retiredR7Sha='c38576741ce2d379723fde038300363429845656'
if($JobId -eq $retiredR7Job -and $ExpectedSiteSha.Trim().ToLowerInvariant() -eq $retiredR7Sha){
  Write-Output 'AFZ_SITE_DEPLOY_RETIRED_R7: blocked before deploy core.'
  exit 42
}

# Executor overlap guard. The scheduled-task carrier can end before an orphaned
# deploy core exits, so carrier/task state alone is not sufficient to prove that
# another deployment is absent. Serialize new wrappers with a global mutex and
# independently refuse to launch while any existing deploy-core process is alive.
$executorMutex=New-Object Threading.Mutex($false,'Global\AFZSiteDeployExecutor')
$executorLocked=$false
try{
  $executorLocked=$executorMutex.WaitOne(0)
  if(-not $executorLocked){
    Write-Error 'AFZ_SITE_DEPLOY_OVERLAP: another deploy wrapper owns the executor mutex.'
    exit 43
  }

  $isWindowsHost=([string]$env:OS -eq 'Windows_NT')
  $cim=Get-Command Get-CimInstance -ErrorAction SilentlyContinue
  if($isWindowsHost -and -not $cim){
    Write-Error 'AFZ_SITE_DEPLOY_PROCESS_GUARD_UNAVAILABLE: Get-CimInstance is unavailable on Windows.'
    exit 45
  }
  $existingCore=@()
  if($cim){
    $existingCore=@(
      Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
          [int]$_.ProcessId -ne $PID -and
          ([string]$_.CommandLine) -match '(?i)Deploy-AFZ-WebsiteToPi-Core\.ps1'
        }
    )
  }
  if($existingCore.Count -gt 0){
    $pids=($existingCore | ForEach-Object {[string]$_.ProcessId}) -join ','
    Write-Error "AFZ_SITE_DEPLOY_ORPHAN_CORE_PRESENT: refusing new deploy while core PID(s) $pids remain alive."
    exit 44
  }

  $core=Join-Path $PSScriptRoot 'Deploy-AFZ-WebsiteToPi-Core.ps1'
  if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "AFZ website deployment core missing: $core"}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core -ExpectedSiteSha $ExpectedSiteSha -JobId $JobId
  exit $LASTEXITCODE
} finally {
  if($executorLocked){try{$executorMutex.ReleaseMutex()}catch{}}
  $executorMutex.Dispose()
}
