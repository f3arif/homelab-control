#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'

# Transitional typed bridge. The original Jellyfin runner is preserved byte-for-byte
# as Invoke-Jellyfin-Visibility-Request-Core.ps1. This wrapper adds only the fixed,
# idempotent MovieRecommender Stremio recovery request; it exposes no command input.
$core=Join-Path $InstallRoot 'afz-openai-agent\Invoke-Jellyfin-Visibility-Request-Core.ps1'
$movie=Join-Path $InstallRoot 'afz-openai-agent\Invoke-MovieRecommender-Stremio-Rebind.ps1'
$coreCode=0
$movieCode=0

if(Test-Path -LiteralPath $core -PathType Leaf){
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $core -InstallRoot $InstallRoot *> $null
  $coreCode=$LASTEXITCODE
}else{
  $coreCode=2
}
if(Test-Path -LiteralPath $movie -PathType Leaf){
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $movie -InstallRoot $InstallRoot *> $null
  $movieCode=$LASTEXITCODE
}
if($coreCode -ne 0){exit $coreCode}
if($movieCode -ne 0){exit $movieCode}
exit 0
