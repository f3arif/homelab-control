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
function Invoke-GhQuiet([string[]]$Arguments){
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $output=@(& $gh @Arguments 2>$null)
    $code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  return [pscustomobject]@{ExitCode=$code;Output=$output}
}
if(-not $gh){
  $winget=Get-Command winget.exe -ErrorAction SilentlyContinue
  if(-not $winget){throw 'GitHub CLI is not installed and winget is unavailable.'}
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    & $winget.Source install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
    $installExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($installExit -ne 0){throw "GitHub CLI installation failed exit=$installExit"}
  $gh=Find-Gh
  if(-not $gh){throw 'GitHub CLI installation completed but gh.exe was not found.'}
}
$auth=Invoke-GhQuiet -Arguments @('auth','status','--hostname','github.com')
if($auth.ExitCode -ne 0){
  Write-Host 'GitHub CLI is installed but not authenticated. A browser/device authorization will now start.'
  Write-Host 'Authenticate the GitHub account that owns f3arif/homelab-control. Do not paste a token into chat.'
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    & $gh auth login --hostname github.com --git-protocol https --web
    $loginExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old}
  if($loginExit -ne 0){throw "gh auth login failed exit=$loginExit"}
  $auth=Invoke-GhQuiet -Arguments @('auth','status','--hostname','github.com')
  if($auth.ExitCode -ne 0){throw 'GitHub CLI login returned success but auth status still failed.'}
}
$perm=Invoke-GhQuiet -Arguments @('api',"repos/$repo",'--jq','.permissions.push')
$permText=([string]($perm.Output -join "`n")).Trim().ToLowerInvariant()
if($perm.ExitCode -ne 0 -or $permText -ne 'true'){throw 'Authenticated GitHub identity does not have push permission to f3arif/homelab-control.'}
$setup=Invoke-GhQuiet -Arguments @('auth','setup-git')
$gitSetup=($setup.ExitCode -eq 0)
if(-not $gitSetup){Write-Warning 'gh auth setup-git failed. Continuing because authenticated GitHub API/issue-comment reporting is the primary direct-H3 return channel; result-branch push remains best-effort.'}
$t=Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if(-not $t){throw "Scheduled task not found: $task"}
try{Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue}catch{}
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 3
$t=Get-ScheduledTask -TaskName $task
[pscustomobject]@{ok=$true;host=$env:COMPUTERNAME;github='authenticated';repoPush=$true;gitSetup=$gitSetup;primaryReturn='gh-issue-comment';ghPath=$gh;task=$task;taskState=[string]$t.State}|ConvertTo-Json -Compress
