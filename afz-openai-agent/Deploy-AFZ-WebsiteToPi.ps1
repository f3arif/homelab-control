#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedSiteSha,
  [Parameter(Mandatory=$true)][string]$JobId
)
$ErrorActionPreference='Stop'
$core=Join-Path $PSScriptRoot 'Deploy-AFZ-WebsiteToPi-Core.ps1'
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw "AFZ website deployment core missing: $core"}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core -ExpectedSiteSha $ExpectedSiteSha -JobId $JobId
exit $LASTEXITCODE
