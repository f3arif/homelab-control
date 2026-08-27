#Requires -Version 5.1
param([string]$InstallRoot='C:\AFZ\homelab-control')
$ErrorActionPreference='Stop'
$git=(Get-Command git.exe -ErrorAction Stop).Source
if(-not(Test-Path (Join-Path $InstallRoot '.git'))){throw 'AFZ homelab-control checkout missing'}
$before=(& $git -C $InstallRoot rev-parse HEAD).Trim()
& $git -C $InstallRoot fetch origin main | Out-Null
& $git -C $InstallRoot checkout main | Out-Null
& $git -C $InstallRoot pull --ff-only origin main | Out-Null
$after=(& $git -C $InstallRoot rev-parse HEAD).Trim()
if($before -ne $after){
  try{Stop-ScheduledTask -TaskName 'AFZ OpenAI Agent' -ErrorAction SilentlyContinue}catch{}
  Start-Sleep 1
  Start-ScheduledTask -TaskName 'AFZ OpenAI Agent'
}
