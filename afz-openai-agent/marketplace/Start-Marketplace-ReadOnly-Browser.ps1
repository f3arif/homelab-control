#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$ProfileRoot='C:\AFZ\MarketplaceBrowserProfile',
  [int]$DebugPort=9222
)
$ErrorActionPreference='Stop'

$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
if($identity -match '\\SYSTEM$'){
  throw 'Marketplace browser must be launched in the signed-in interactive user session, not SYSTEM.'
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

# Do not attach the user's normal browser profile. This dedicated profile is intentionally
# separate so the automation has only the Marketplace session the user signs into here.
$arguments=@(
  "--remote-debugging-port=$DebugPort",
  "--user-data-dir=$ProfileRoot",
  '--no-first-run',
  '--no-default-browser-check',
  'https://www.facebook.com/marketplace/you/selling'
)
Start-Process -FilePath $browser -ArgumentList $arguments | Out-Null

[ordered]@{
  ok=$true
  mode='interactive-user-read-only-preparation'
  browser=$browser
  profileRoot=$ProfileRoot
  cdp="http://127.0.0.1:$DebugPort"
  next='Sign in manually if Facebook asks. Do not provide credentials to scripts. Then run the read-only collector.'
}|ConvertTo-Json -Compress
