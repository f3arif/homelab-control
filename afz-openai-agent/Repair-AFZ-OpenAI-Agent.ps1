#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [switch]$RunJellyfinDiagnosis
)
$ErrorActionPreference='Stop'
$repo='https://github.com/f3arif/homelab-control.git'
$git=(Get-Command git.exe -ErrorAction Stop).Source

Write-Host 'AFZ OpenAI Agent self-healing repair' -ForegroundColor Cyan

if(Test-Path (Join-Path $InstallRoot '.git')){
  Write-Host "Refreshing existing checkout: $InstallRoot"
  # Clean only the one file the original updater was known to patch locally.
  & $git -C $InstallRoot checkout -- 'afz-openai-agent/AFZ-OpenAI-Agent-v2.ps1' 2>$null
  & $git -C $InstallRoot fetch origin main
  if($LASTEXITCODE -ne 0){throw 'git fetch failed'}
  & $git -C $InstallRoot checkout main
  if($LASTEXITCODE -ne 0){throw 'git checkout main failed'}
  & $git -C $InstallRoot pull --ff-only origin main
  if($LASTEXITCODE -ne 0){throw 'git pull --ff-only failed; existing unrelated local changes were preserved'}
}else{
  if(Test-Path $InstallRoot){
    $items=@(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
    if($items.Count -gt 0){throw "$InstallRoot exists but is not a git checkout. Move/rename it first; repair will not delete it."}
  }else{
    New-Item -ItemType Directory -Force -Path (Split-Path $InstallRoot -Parent) | Out-Null
  }
  Write-Host "Cloning $repo -> $InstallRoot"
  & $git clone $repo $InstallRoot
  if($LASTEXITCODE -ne 0){throw 'git clone failed'}
}

$installer=Join-Path $InstallRoot 'afz-openai-agent\Install-AFZ-OpenAI-Agent.ps1'
if(-not(Test-Path $installer)){throw "Installer missing after refresh: $installer"}

# Remove stale task definitions from early prototypes only if their action target no longer exists.
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

$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$installer)
if($RunJellyfinDiagnosis){$args += '-RunJellyfinDiagnosis'}
& powershell.exe @args
if($LASTEXITCODE -ne 0){throw "Installer exited with code $LASTEXITCODE"}

# Force the current updater once so fleet access/firewall/control plane are applied immediately.
$updater=Join-Path $InstallRoot 'afz-openai-agent\Update-AFZ-OpenAI-Agent.ps1'
if(Test-Path $updater){
  Write-Host 'Applying current updater policy now...'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -InstallRoot $InstallRoot
  if($LASTEXITCODE -ne 0){Write-Warning "Updater exited with code $LASTEXITCODE"}
}

Start-Sleep 3
$checks=@(
  @{name='Agent';uri='http://127.0.0.1:8796/health'},
  @{name='Control';uri='http://127.0.0.1:8797/health'}
)
$allOk=$true
foreach($c in $checks){
  try{
    $r=Invoke-RestMethod -Uri $c.uri -TimeoutSec 8
    Write-Host ("{0}: ONLINE {1}" -f $c.name,$r.version) -ForegroundColor Green
  }catch{
    $allOk=$false
    Write-Warning ("{0}: health check failed: {1}" -f $c.name,$_.Exception.Message)
  }
}

Write-Host ''
Write-Host 'Scheduled tasks:' -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'AFZ OpenAI Agent*' -ErrorAction SilentlyContinue | Select-Object TaskName,State | Format-Table -AutoSize
Write-Host 'Agent UI:    http://127.0.0.1:8796/'
Write-Host 'Control UI:  http://127.0.0.1:8797/'
Write-Host 'H3 access:   http://100.70.25.8:8796/'
if(-not $allOk){exit 2}
