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

$core=Join-Path $PSScriptRoot 'Deploy-AFZ-WebsiteToPi-Core.ps1'
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "AFZ website deployment core missing: $core"}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core -ExpectedSiteSha $ExpectedSiteSha -JobId $JobId
exit $LASTEXITCODE
