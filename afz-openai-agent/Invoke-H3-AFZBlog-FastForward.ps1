#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExpectedBlogSha,
  [string]$RequestId='afz-blog-h3-fast-forward'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedRelay='DESKTOP-10SKF0M'
$systemKey='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$userKey='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-h3-fast-forward'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-H3-AFZ-BLOG-FAST-FORWARD-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $statePath=Join-Path $stateRoot ($RequestId+'.json')
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 20 -Compress)
}

try{
  if($env:COMPUTERNAME -ne $expectedRelay){throw "Wrong relay host: $($env:COMPUTERNAME)"}
  if($RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid RequestId'}
  if($ExpectedBlogSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedBlogSha must be 40 hex characters'}
  $ExpectedBlogSha=$ExpectedBlogSha.ToLowerInvariant()
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  if([string]$identity.User.Value -eq 'S-1-5-18'){$key=$systemKey;$relayIdentity='SYSTEM'}
  elseif([string]$identity.Name -ieq ($expectedRelay+'\Faiz')){$key=$userKey;$relayIdentity='Faiz'}
  else{throw "Relay identity is not allowlisted. Actual: $($identity.Name)"}
  foreach($p in @($key,$known,$ssh)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing relay prerequisite: $p"}}

  $remoteTemplate=@'
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$expectedHost='DESKTOP-H3R6CQN'
$workspace='C:\AFZ\Workspaces\AFZ-Blog\blog-manager'
$expectedSha='__EXPECTED_SHA__'

function Emit([bool]$ok,[string]$classification,$extra,[int]$code){
  $o=[ordered]@{schema=1;ok=$ok;classification=$classification;host=$env:COMPUTERNAME;workspace=$workspace;expectedSha=$expectedSha;credentialsEmitted=$false;productionModified=$false;productionDatabaseModified=$false;websitePublished=$false;time=(Get-Date -Format o)}
  foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
  [Console]::Out.WriteLine(($o|ConvertTo-Json -Depth 16 -Compress))
  exit $code
}
function Run-Git([string[]]$ArgumentVector,[switch]$AllowFailure){
  $cmd=Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1
  if(-not $cmd){throw 'git.exe missing'}
  $exe=$(if($cmd.Path){[string]$cmd.Path}else{[string]$cmd.Source})
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$lines=@(& $exe @ArgumentVector 2>&1|ForEach-Object{[string]$_});$exit=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $exit -ne 0){throw ('git failed exit='+$exit+' command='+($ArgumentVector -join ' ')+' output='+(($lines|Select-Object -Last 4)-join ' | '))}
  [pscustomobject]@{exit=[int]$exit;lines=$lines;text=($lines-join "`n")}
}
function Snapshot {
  if(-not(Test-Path -LiteralPath $workspace -PathType Container)){return [ordered]@{exists=$false}}
  $gitRepo=(Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Container)
  $head=$null;$branch=$null;$origin=$null;$dirty=$null
  if($gitRepo){
    $head=(Run-Git @('-C',$workspace,'rev-parse','HEAD') -AllowFailure).text.Trim().ToLowerInvariant()
    $branch=(Run-Git @('-C',$workspace,'branch','--show-current') -AllowFailure).text.Trim()
    $origin=(Run-Git @('-C',$workspace,'remote','get-url','origin') -AllowFailure).text.Trim()
    $dirty=@((Run-Git @('-C',$workspace,'status','--porcelain=v1','-uall') -AllowFailure).lines|Where-Object{$_}).Count
  }
  [ordered]@{exists=$true;gitRepo=$gitRepo;head=$head;branch=$branch;origin=$origin;dirtyCount=$dirty;envPresent=(Test-Path -LiteralPath (Join-Path $workspace '.env') -PathType Leaf);envLocalPresent=(Test-Path -LiteralPath (Join-Path $workspace '.env.local') -PathType Leaf)}
}

if($env:COMPUTERNAME -ne $expectedHost){Emit $false 'H3_AFZ_BLOG_FF_WRONG_HOST' @{} 30}
$before=Snapshot
if(-not $before.exists -or -not $before.gitRepo){Emit $false 'H3_AFZ_BLOG_FF_WORKSPACE_NOT_GIT' @{before=$before} 31}
if($before.envPresent -or $before.envLocalPresent){Emit $false 'H3_AFZ_BLOG_FF_SECRET_FILE_PRESENT' @{before=$before} 32}
if([string]$before.branch -ne 'main'){Emit $false 'H3_AFZ_BLOG_FF_WRONG_BRANCH' @{before=$before} 33}
if([int]$before.dirtyCount -ne 0){Emit $false 'H3_AFZ_BLOG_FF_DIRTY' @{before=$before} 34}
$originNorm=([string]$before.origin).TrimEnd('/').ToLowerInvariant()
$allowedOrigins=@(
  'https://github.com/f3arif/afz-blog.git',
  'git@github.com:f3arif/afz-blog.git',
  'git@afz-blog-github-h3:f3arif/afz-blog.git'
)
if($originNorm -notin $allowedOrigins){Emit $false 'H3_AFZ_BLOG_FF_ORIGIN_MISMATCH' @{before=$before} 35}
if([string]$before.head -eq $expectedSha){Emit $true 'H3_AFZ_BLOG_FF_ALREADY_CURRENT' @{before=$before;after=$before;fastForwardPerformed=$false} 0}

$fetch=Run-Git @('-C',$workspace,'fetch','--prune','origin','main') -AllowFailure
if($fetch.exit -ne 0){Emit $false 'H3_AFZ_BLOG_FF_FETCH_FAILED' @{before=$before;fetchExit=$fetch.exit;fetchTail=@($fetch.lines|Select-Object -Last 5)} 36}
$remoteSha=(Run-Git @('-C',$workspace,'rev-parse','origin/main')).text.Trim().ToLowerInvariant()
if($remoteSha -ne $expectedSha){Emit $false 'H3_AFZ_BLOG_FF_REMOTE_SHA_MISMATCH' @{before=$before;remoteSha=$remoteSha} 37}
$ancestor=Run-Git @('-C',$workspace,'merge-base','--is-ancestor',$before.head,'origin/main') -AllowFailure
if($ancestor.exit -ne 0){Emit $false 'H3_AFZ_BLOG_FF_DIVERGED' @{before=$before;remoteSha=$remoteSha} 38}
$merge=Run-Git @('-C',$workspace,'merge','--ff-only','origin/main') -AllowFailure
if($merge.exit -ne 0){Emit $false 'H3_AFZ_BLOG_FF_MERGE_FAILED' @{before=$before;remoteSha=$remoteSha;mergeExit=$merge.exit;mergeTail=@($merge.lines|Select-Object -Last 5)} 39}
$after=Snapshot
if(-not $after.gitRepo -or [string]$after.head -ne $expectedSha -or [string]$after.branch -ne 'main' -or [int]$after.dirtyCount -ne 0 -or $after.envPresent -or $after.envLocalPresent){Emit $false 'H3_AFZ_BLOG_FF_POSTVERIFY_FAILED' @{before=$before;remoteSha=$remoteSha;after=$after} 40}
Emit $true 'H3_AFZ_BLOG_FAST_FORWARD_READY' @{before=$before;remoteSha=$remoteSha;after=$after;fastForwardPerformed=$true} 0
'@
  $remote=$remoteTemplate.Replace('__EXPECTED_SHA__',$ExpectedBlogSha)
  $in=Join-Path $env:TEMP ('afz-h3-blog-ff-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $out=Join-Path $env:TEMP ('afz-h3-blog-ff-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('afz-h3-blog-ff-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    [IO.File]::WriteAllText($in,$remote,$utf8)
    $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(150000)){try{$p.Kill()}catch{};throw 'H3 AFZ Blog fast-forward relay timed out after 150 seconds.'}
    $stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''});$stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''})
    $jsonLine=@(($stdout -split "`r?`n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    if(-not $jsonLine){throw "No remote JSON. sshExit=$($p.ExitCode) stderr=$stderr"}
    $remoteResult=$jsonLine|ConvertFrom-Json
    $result=[ordered]@{schema=1;ok=[bool]$remoteResult.ok;classification=[string]$remoteResult.classification;requestId=$RequestId;relayHost=$env:COMPUTERNAME;relayIdentity=$relayIdentity;target='DESKTOP-H3R6CQN';expectedBlogSha=$ExpectedBlogSha;remote=$remoteResult;credentialsEmitted=$false;productionModified=$false;productionDatabaseModified=$false;websitePublished=$false;time=(Get-Date -Format o)}
    Save-State $result
    if(-not $result.ok){exit 20}
  }finally{Remove-Item -LiteralPath $in,$out,$err -Force -ErrorAction SilentlyContinue}
}catch{
  $result=[ordered]@{schema=1;ok=$false;classification='H3_AFZ_BLOG_FF_RELAY_EXCEPTION';requestId=$RequestId;relayHost=$env:COMPUTERNAME;expectedBlogSha=$ExpectedBlogSha;error=$_.Exception.Message;credentialsEmitted=$false;productionModified=$false;productionDatabaseModified=$false;websitePublished=$false;time=(Get-Date -Format o)}
  Save-State $result
  exit 21
}
