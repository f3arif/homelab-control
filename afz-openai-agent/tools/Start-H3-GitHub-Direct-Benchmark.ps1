#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Watcher='C:\AFZ\GitHubDirect\H3-GitHub-Direct-Benchmark-Watcher.ps1',
  [int]$IntervalSeconds=10
)
$ErrorActionPreference='Stop'
$repo='f3arif/homelab-control'
$alertIssue=7
$stateRoot='C:\ProgramData\AFZ\H3GitHubDirect'
$stateFile=Join-Path $stateRoot 'github-preflight.json'
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
function Save-State([string]$Status,[string]$Message){$o=[ordered]@{ok=($Status -eq 'ready');status=$Status;message=$Message;host=$env:COMPUTERNAME;repo=$repo;updated_at=(Get-Date -Format o)};[IO.File]::WriteAllText($stateFile,($o|ConvertTo-Json -Depth 6 -Compress),$utf8)}
function Get-Gh{
  $c=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}
  foreach($p in @('C:\Program Files\GitHub CLI\gh.exe','C:\Program Files (x86)\GitHub CLI\gh.exe')){if(Test-Path $p){return $p}}
  return $null
}
try{
  if($env:COMPUTERNAME -ne 'DESKTOP-H3R6CQN'){throw "H3-only launcher; host=$env:COMPUTERNAME"}
  if(-not(Test-Path $Watcher)){throw "Watcher missing: $Watcher"}
  $gh=Get-Gh
  if(-not $gh){Save-State 'blocked-github-auth' 'GitHub CLI is not installed on H3. Run Enable-H3-GitHub-DirectAuth.ps1 interactively.';exit 20}
  function Invoke-GhQuiet([string[]]$Arguments){
    $old=$ErrorActionPreference
    try{
      $ErrorActionPreference='Continue'
      $output=@(& $gh @Arguments 2>$null)
      $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$old}
    return [pscustomobject]@{ExitCode=$code;Output=$output}
  }
  $auth=Invoke-GhQuiet -Arguments @('auth','status','--hostname','github.com')
  if($auth.ExitCode -ne 0){Save-State 'blocked-github-auth' 'GitHub CLI is installed but not authenticated on H3. Run Enable-H3-GitHub-DirectAuth.ps1 interactively.';exit 21}
  $perm=Invoke-GhQuiet -Arguments @('api',"repos/$repo",'--jq','.permissions.push')
  $permText=([string]($perm.Output -join "`n")).Trim().ToLowerInvariant()
  if($perm.ExitCode -ne 0 -or $permText -ne 'true'){Save-State 'blocked-github-write' 'H3 GitHub identity does not have push permission to homelab-control.';exit 22}
  $preflight=Invoke-GhQuiet -Arguments @('issue','comment',[string]$alertIssue,'--repo',$repo,'--body','[H3-DIRECT PREFLIGHT] GitHub API/issue-comment return channel verified on H3. Direct benchmark watcher is starting; AFZ queue/claims are bypassed. Git result-branch push is best-effort only.')
  if($preflight.ExitCode -ne 0){Save-State 'blocked-github-write' 'GitHub authentication is valid but the primary issue-comment return channel failed.';exit 23}
  $setup=Invoke-GhQuiet -Arguments @('auth','setup-git')
  $gitSetup=($setup.ExitCode -eq 0)
  Save-State 'ready' "GitHub API/issue-comment return channel verified; starting direct H3 benchmark watcher. gitSetup=$gitSetup; result-branch push is best-effort."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Watcher -IntervalSeconds $IntervalSeconds
  exit $LASTEXITCODE
}catch{
  Save-State 'failed' $_.Exception.Message
  throw
}
