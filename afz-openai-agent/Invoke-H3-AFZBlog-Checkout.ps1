#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','apply')][string]$Action='audit',
  [string]$RequestId='h3-afz-blog-checkout-r1',
  [string]$ExpectedBlogSha='a37e71aa0e0c9fad41ecdc9652a7024c485666f4'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedWindowsHost='DESKTOP-10SKF0M'
$key='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$expectedH3='DESKTOP-H3R6CQN'
$repo='https://github.com/f3arif/AFZ-Blog.git'
$workspace='C:\AFZ\Workspaces\AFZ-Blog\blog-manager'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\h3-afz-blog-checkout'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-H3-AFZ-BLOG-CHECKOUT-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 20 -Compress)
}
function Invoke-H3([string]$RemoteScript){
  $bootstrap='$script=[Console]::In.ReadToEnd();if([string]::IsNullOrWhiteSpace($script)){throw ''H3 AFZ Blog checkout stdin empty.''};Invoke-Expression $script'
  $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
  $inFile=Join-Path $env:TEMP ('afz-h3-blog-checkout-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $outFile=Join-Path $env:TEMP ('afz-h3-blog-checkout-'+[guid]::NewGuid().ToString('n')+'.out')
  $errFile=Join-Path $env:TEMP ('afz-h3-blog-checkout-'+[guid]::NewGuid().ToString('n')+'.err')
  $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
  try{
    [IO.File]::WriteAllText($inFile,$RemoteScript,$utf8)
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(180000)){try{$p.Kill()}catch{};throw 'H3 AFZ Blog checkout timed out after 180 seconds.'}
    $stdout=$(if(Test-Path -LiteralPath $outFile){[IO.File]::ReadAllText($outFile)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $errFile){[IO.File]::ReadAllText($errFile)}else{''})
    return [ordered]@{exit=[int]$p.ExitCode;stdout=$stdout;stderr=$stderr}
  }finally{Remove-Item -LiteralPath $inFile,$outFile,$errFile -Force -ErrorAction SilentlyContinue}
}

try{
  if($env:COMPUTERNAME -ne $expectedWindowsHost){throw "Wrong relay host: $($env:COMPUTERNAME)"}
  if($RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid RequestId'}
  if($ExpectedBlogSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedBlogSha must be 40 hex characters'}
  $ExpectedBlogSha=$ExpectedBlogSha.ToLowerInvariant()
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required relay path missing: $p"}}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw "SYSTEM execution required. Actual: $($identity.Name)"}

  $remoteTemplate=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$action='__ACTION__'
$expectedSha='__EXPECTED_SHA__'
$repo='https://github.com/f3arif/AFZ-Blog.git'
$workspace='C:\AFZ\Workspaces\AFZ-Blog\blog-manager'
$expectedHost='DESKTOP-H3R6CQN'
$mutationStarted=$false
function Native([string[]]$Args,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$out=@(& git @Args 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw ('git failed exit='+$code)}
  [pscustomobject]@{exit=$code;lines=$out;text=($out -join "`n")}
}
function GitCredentialAvailable {
  $old=$ErrorActionPreference
  $oldInteractive=$env:GCM_INTERACTIVE
  try{
    $ErrorActionPreference='Continue';$env:GCM_INTERACTIVE='Never'
    $input="protocol=https`nhost=github.com`n`n"
    $lines=@($input|& git credential fill 2>$null|ForEach-Object{[string]$_});$code=$LASTEXITCODE
  }finally{$ErrorActionPreference=$old;$env:GCM_INTERACTIVE=$oldInteractive}
  if($code -ne 0){return $false}
  $hasUser=[bool](@($lines|Where-Object{$_ -match '^username=.+$'}).Count)
  $hasPassword=[bool](@($lines|Where-Object{$_ -match '^password=.+$'}).Count)
  return ($hasUser -and $hasPassword)
}
function Snapshot {
  $exists=Test-Path -LiteralPath $workspace -PathType Container
  $gitRepo=$false;$head=$null;$branch=$null;$origin=$null;$dirty=$null
  if($exists){
    $probe=Native @('-C',$workspace,'rev-parse','--is-inside-work-tree') -AllowFailure
    $gitRepo=($probe.exit -eq 0 -and $probe.text.Trim() -eq 'true')
    if($gitRepo){
      $head=(Native @('-C',$workspace,'rev-parse','HEAD') -AllowFailure).text.Trim().ToLowerInvariant()
      $branch=(Native @('-C',$workspace,'branch','--show-current') -AllowFailure).text.Trim()
      $origin=(Native @('-C',$workspace,'remote','get-url','origin') -AllowFailure).text.Trim()
      $dirty=@((Native @('-C',$workspace,'status','--porcelain=v1','-uall') -AllowFailure).lines|Where-Object{$_}).Count
    }
  }
  [ordered]@{workspaceExists=$exists;gitRepo=$gitRepo;head=$(if($head){$head}else{$null});branch=$(if($branch){$branch}else{$null});origin=$(if($origin){$origin}else{$null});dirtyCount=$dirty}
}
function Emit([bool]$ok,[string]$classification,$extra,[int]$code){
  $o=[ordered]@{schema=1;ok=$ok;classification=$classification;host=$env:COMPUTERNAME;action=$action;repository=$repo;workspace=$workspace;expectedSha=$expectedSha;remoteMutationStarted=$mutationStarted;credentialsEmitted=$false;time=(Get-Date -Format o)}
  foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
  $o|ConvertTo-Json -Depth 12 -Compress
  exit $code
}
if($env:COMPUTERNAME -ne $expectedHost){Emit $false 'H3_AFZ_BLOG_WRONG_HOST' @{} 30}
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1
if(-not $gitCmd){Emit $false 'H3_AFZ_BLOG_GIT_MISSING' @{} 31}
$cred=GitCredentialAvailable
$before=Snapshot
if($action -eq 'audit'){Emit $true 'H3_AFZ_BLOG_AUDIT_COMPLETE' @{gitCredentialAvailable=$cred;before=$before} 0}

if($before.workspaceExists){
  if(-not $before.gitRepo){Emit $false 'H3_AFZ_BLOG_EXISTING_PATH_NOT_GIT' @{gitCredentialAvailable=$cred;before=$before} 32}
  $originNorm=([string]$before.origin).TrimEnd('/').ToLowerInvariant()
  if($originNorm -notin @('https://github.com/f3arif/afz-blog.git','git@github.com:f3arif/afz-blog.git')){Emit $false 'H3_AFZ_BLOG_REMOTE_MISMATCH' @{gitCredentialAvailable=$cred;before=$before} 33}
  if([int]$before.dirtyCount -ne 0){Emit $false 'H3_AFZ_BLOG_EXISTING_DIRTY' @{gitCredentialAvailable=$cred;before=$before} 34}
  if(-not $cred -and $originNorm.StartsWith('https://')){Emit $false 'H3_AFZ_BLOG_GITHUB_AUTH_MISSING' @{gitCredentialAvailable=$cred;before=$before} 35}
  $mutationStarted=$true
  $oldInteractive=$env:GCM_INTERACTIVE;try{$env:GCM_INTERACTIVE='Never';Native @('-C',$workspace,'fetch','--prune','origin','main')|Out-Null}finally{$env:GCM_INTERACTIVE=$oldInteractive}
  $remoteSha=(Native @('-C',$workspace,'rev-parse','origin/main')).text.Trim().ToLowerInvariant()
  if($remoteSha -ne $expectedSha){Emit $false 'H3_AFZ_BLOG_REMOTE_SHA_UNEXPECTED' @{gitCredentialAvailable=$cred;before=$before;originMain=$remoteSha} 36}
  Native @('-C',$workspace,'checkout','main')|Out-Null
  Native @('-C',$workspace,'merge','--ff-only','origin/main')|Out-Null
}else{
  if(-not $cred){Emit $false 'H3_AFZ_BLOG_GITHUB_AUTH_MISSING' @{gitCredentialAvailable=$cred;before=$before} 35}
  $parent=Split-Path -Parent $workspace
  New-Item -ItemType Directory -Force -Path $parent|Out-Null
  $mutationStarted=$true
  $oldInteractive=$env:GCM_INTERACTIVE;try{$env:GCM_INTERACTIVE='Never';Native @('clone','--branch','main','--single-branch',$repo,$workspace)|Out-Null}finally{$env:GCM_INTERACTIVE=$oldInteractive}
}
$after=Snapshot
if(-not $after.gitRepo -or [string]$after.head -ne $expectedSha -or [string]$after.branch -ne 'main' -or [int]$after.dirtyCount -ne 0){Emit $false 'H3_AFZ_BLOG_VERIFY_FAILED' @{gitCredentialAvailable=$cred;before=$before;after=$after} 37}
if(Test-Path -LiteralPath (Join-Path $workspace '.env') -PathType Leaf -or Test-Path -LiteralPath (Join-Path $workspace '.env.local') -PathType Leaf){Emit $false 'H3_AFZ_BLOG_SECRET_FILE_PRESENT' @{gitCredentialAvailable=$cred;before=$before;after=$after} 38}
Emit $true 'H3_AFZ_BLOG_CHECKOUT_READY' @{gitCredentialAvailable=$cred;before=$before;after=$after} 0
'@
  $remote=$remoteTemplate.Replace('__ACTION__',$Action).Replace('__EXPECTED_SHA__',$ExpectedBlogSha)
  $r=Invoke-H3 $remote
  $jsonLine=@(([string]$r.stdout -split "`r?`n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
  if(-not $jsonLine){throw "H3 checkout returned no JSON. exit=$($r.exit) stderr=$($r.stderr)"}
  $payload=$jsonLine|ConvertFrom-Json -ErrorAction Stop
  if([string]$payload.host -ne $expectedH3){throw "Unexpected remote host: $($payload.host)"}
  $safe=[ordered]@{schema=1;ok=[bool]$payload.ok;classification=[string]$payload.classification;requestId=$RequestId;relayHost=$env:COMPUTERNAME;target='h3';host=[string]$payload.host;action=$Action;repository=[string]$payload.repository;workspace=[string]$payload.workspace;expectedSha=$ExpectedBlogSha;gitCredentialAvailable=[bool]$payload.gitCredentialAvailable;remoteMutationStarted=[bool]$payload.remoteMutationStarted;credentialsEmitted=$false;before=$payload.before;after=$payload.after;sshExit=[int]$r.exit;time=(Get-Date -Format o)}
  Save-State $safe
  if(-not $safe.ok){exit 42}
  exit 0
}catch{
  Save-State ([ordered]@{schema=1;ok=$false;classification='H3_AFZ_BLOG_RELAY_FAILED';requestId=$RequestId;relayHost=$env:COMPUTERNAME;target='h3';action=$Action;expectedSha=$ExpectedBlogSha;credentialsEmitted=$false;error=$_.Exception.Message;time=(Get-Date -Format o)})
  exit 43
}
