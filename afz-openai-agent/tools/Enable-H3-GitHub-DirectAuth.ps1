#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "Run this only on H3; host=$env:COMPUTERNAME"}
$repo='f3arif/homelab-control'
$task='AFZ H3 GitHub Direct Benchmark Watcher'
function Find-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
$gh=Find-Gh
if(-not $gh){
  $winget=Get-Command winget.exe -ErrorAction SilentlyContinue
  if(-not $winget){throw 'GitHub CLI is not installed and winget is unavailable.'}
  & $winget.Source install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
  if($LASTEXITCODE -ne 0){throw "GitHub CLI installation failed exit=$LASTEXITCODE"}
  $gh=Find-Gh
  if(-not $gh){throw 'GitHub CLI installation completed but gh.exe was not found.'}
}
& $gh auth status --hostname github.com *> $null
if($LASTEXITCODE -ne 0){
  Write-Host 'A browser/device authorization will open for GitHub. Authenticate the GitHub account that owns homelab-control.'
  & $gh auth login --hostname github.com --git-protocol https --web
  if($LASTEXITCODE -ne 0){throw "gh auth login failed exit=$LASTEXITCODE"}
}
& $gh auth setup-git
if($LASTEXITCODE -ne 0){throw "gh auth setup-git failed exit=$LASTEXITCODE"}
$perm=& $gh api "repos/$repo" --jq '.permissions.push'
if($LASTEXITCODE -ne 0 -or ([string]$perm).Trim().ToLowerInvariant() -ne 'true'){throw 'Authenticated GitHub identity does not have push permission to f3arif/homelab-control.'}
$t=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if(-not $t){throw "Scheduled task not found: $task"}
try{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}catch{}
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 3
$t=Get-ScheduledTask -TaskName $task
[pscustomobject]@{ok=$true;host=$env:COMPUTERNAME;github='authenticated';repoPush=$true;task=$task;taskState=[string]$t.State}|ConvertTo-Json -Compress
