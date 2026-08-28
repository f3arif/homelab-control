#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ProfileRoot='C:\AFZ\MarketplaceBrowserProfile',
  [int]$DebugPort=9222
)
$ErrorActionPreference='Stop'

$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if($identity -match '\\SYSTEM$'){
  throw 'Marketplace browser must be launched in the user account context, not SYSTEM.'
}
if($DebugPort -lt 1024 -or $DebugPort -gt 65535){throw 'DebugPort out of range'}

$candidates=@(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object {$_ -and (Test-Path -LiteralPath $_)}
if(-not $candidates){throw 'Chrome or Edge was not found.'}
$browser=$candidates|Select-Object -First 1
New-Item -ItemType Directory -Force -Path $ProfileRoot|Out-Null

# Dedicated profile only. CDP is explicitly loopback-bound so it is not exposed to LAN/Tailscale.
$arguments=@(
  '--remote-debugging-address=127.0.0.1',
  "--remote-debugging-port=$DebugPort",
  "--user-data-dir=$ProfileRoot",
  '--no-first-run',
  '--no-default-browser-check',
  'https://www.facebook.com/marketplace/you/selling'
)
Start-Process -FilePath $browser -ArgumentList $arguments | Out-Null

[ordered]@{
  ok=$true
  mode='dedicated-marketplace-browser'
  browser=$browser
  profileRoot=$ProfileRoot
  cdp="http://127.0.0.1:$DebugPort"
  cdpExposure='loopback-only'
  next='For SSH credential entry run Invoke-Marketplace-SSH-Login.ps1. For desktop use, manual sign-in remains allowed.'
}|ConvertTo-Json -Compress
