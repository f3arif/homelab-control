#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
$impl=Join-Path $InstallRoot 'afz-openai-agent\Invoke-HPEnvy-Hermes-OpenAICodexPrimary.V2.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "Codex V2 implementation missing: $impl"}
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $impl -InstallRoot $InstallRoot -RequestPath $RequestPath
exit $LASTEXITCODE
