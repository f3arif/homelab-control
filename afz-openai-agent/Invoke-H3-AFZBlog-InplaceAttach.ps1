#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$RequestId='afz-blog-h3-inplace-attach',
  [string]$ExpectedBlogSha='a37e71aa0e0c9fad41ecdc9652a7024c485666f4'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedRelay='DESKTOP-10SKF0M'
$systemKey='C:\ProgramData\AFZ\OpenAIAgent\keys\afz_h3_worker_system'
$userKey='C:\Users\Faiz\.ssh\afz_h3_worker'
$known='C:\ProgramData\AFZ\OpenAIAgent\h3-known-hosts'
$ssh=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$target='Faiz@100.106.186.118'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-h3-inplace-attach'
$statePath=Join-Path $stateRoot ($RequestId+'.json')
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-H3-AFZ-BLOG-INPLACE-ATTACH-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
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
$repo='https://github.com/f3arif/AFZ-Blog.git'
$workspace='C:\AFZ\Workspaces\AFZ-Blog\blog-manager'
$expectedSha='__EXPECTED_SHA__'
$authConfigChanged=$false
$gitMetadataAttached=$false

function Run-Bounded([string]$Exe,[string[]]$Args,[int]$TimeoutMs,[hashtable]$EnvVars=$null){
  $out=Join-Path $env:TEMP ('afz-h3-blog-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('afz-h3-blog-'+[guid]::NewGuid().ToString('n')+'.err')
  $old=@{}
  try{
    if($EnvVars){foreach($k in $EnvVars.Keys){$old[$k]=[Environment]::GetEnvironmentVariable($k,'Process');[Environment]::SetEnvironmentVariable($k,[string]$EnvVars[$k],'Process')}}
    $p=Start-Process -FilePath $Exe -ArgumentList $Args -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit($TimeoutMs)){try{$p.Kill()}catch{};try{$p.WaitForExit()}catch{};return [pscustomobject]@{exit=$null;timedOut=$true;stdout='';stderr=''}}
    [pscustomobject]@{exit=[int]$p.ExitCode;timedOut=$false;stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''});stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''})}
  }finally{
    if($EnvVars){foreach($k in $EnvVars.Keys){[Environment]::SetEnvironmentVariable($k,$old[$k],'Process')}}
    Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
  }
}
function Native([string[]]$Args,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$lines=@(& git @Args 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw ('git failed exit='+$code)}
  [pscustomobject]@{exit=[int]$code;lines=$lines;text=($lines -join "`n")}
}
function Snapshot {
  $exists=Test-Path -LiteralPath $workspace -PathType Container
  $entries=@();$gitRepo=$false;$head=$null;$branch=$null;$origin=$null;$dirty=$null
  if($exists){
    $entries=@(Get-ChildItem -LiteralPath $workspace -Force -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Name|Sort-Object)
    if(Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Container){
      $gitRepo=$true
      $head=(Native @('-C',$workspace,'rev-parse','HEAD') -AllowFailure).text.Trim().ToLowerInvariant()
      $branch=(Native @('-C',$workspace,'branch','--show-current') -AllowFailure).text.Trim()
      $origin=(Native @('-C',$workspace,'remote','get-url','origin') -AllowFailure).text.Trim()
      $dirty=@((Native @('-C',$workspace,'status','--porcelain=v1','-uall') -AllowFailure).lines|Where-Object{$_}).Count
    }
  }
  [ordered]@{exists=$exists;entryCount=$entries.Count;topLevelNames=@($entries|Select-Object -First 40);gitRepo=$gitRepo;head=$(if($head){$head}else{$null});branch=$(if($branch){$branch}else{$null});origin=$(if($origin){$origin}else{$null});dirtyCount=$dirty;envPresent=(Test-Path -LiteralPath (Join-Path $workspace '.env') -PathType Leaf);envLocalPresent=(Test-Path -LiteralPath (Join-Path $workspace '.env.local') -PathType Leaf)}
}
function Emit([bool]$ok,[string]$classification,$extra,[int]$code){
  $o=[ordered]@{schema=1;ok=$ok;classification=$classification;host=$env:COMPUTERNAME;user=$env:USERNAME;repository=$repo;workspace=$workspace;expectedSha=$expectedSha;authConfigChanged=$authConfigChanged;gitMetadataAttached=$gitMetadataAttached;credentialsEmitted=$false;productionModified=$false;time=(Get-Date -Format o)}
  foreach($k in $extra.Keys){$o[$k]=$extra[$k]}
  $o|ConvertTo-Json -Depth 14 -Compress
  exit $code
}
if($env:COMPUTERNAME -ne $expectedHost){Emit $false 'H3_AFZ_BLOG_WRONG_HOST' @{} 30}
if(-not(Test-Path -LiteralPath $workspace -PathType Container)){Emit $false 'H3_AFZ_BLOG_WORKSPACE_MISSING' @{} 31}
$gitCmd=Get-Command git.exe -ErrorAction SilentlyContinue|Select-Object -First 1
$ghCmd=Get-Command gh.exe -ErrorAction SilentlyContinue|Select-Object -First 1
if(-not $gitCmd){Emit $false 'H3_AFZ_BLOG_GIT_MISSING' @{} 32}
if(-not $ghCmd){Emit $false 'H3_AFZ_BLOG_GH_MISSING' @{} 33}
$gitExe=$(if($gitCmd.Path){[string]$gitCmd.Path}else{[string]$gitCmd.Source})
$ghExe=$(if($ghCmd.Path){[string]$ghCmd.Path}else{[string]$ghCmd.Source})
$before=Snapshot
if($before.envPresent -or $before.envLocalPresent){Emit $false 'H3_AFZ_BLOG_SECRET_FILE_PRESENT' @{before=$before} 34}
if($before.gitRepo){
  $norm=([string]$before.origin).TrimEnd('/').ToLowerInvariant()
  if($norm -in @('https://github.com/f3arif/afz-blog.git','git@github.com:f3arif/afz-blog.git') -and [string]$before.head -eq $expectedSha -and [string]$before.branch -eq 'main' -and [int]$before.dirtyCount -eq 0){Emit $true 'H3_AFZ_BLOG_ALREADY_READY' @{before=$before;after=$before} 0}
  Emit $false 'H3_AFZ_BLOG_EXISTING_GIT_MISMATCH' @{before=$before} 35
}
$auth=Run-Bounded $ghExe @('auth','status','--hostname','github.com') 15000
if($auth.timedOut){Emit $false 'H3_AFZ_BLOG_GH_AUTH_STATUS_TIMEOUT' @{before=$before} 36}
if([int]$auth.exit -ne 0){Emit $false 'H3_AFZ_BLOG_GH_AUTH_MISSING' @{before=$before;ghAuthExit=$auth.exit} 37}
$setup=Run-Bounded $ghExe @('auth','setup-git','--hostname','github.com') 15000
if($setup.timedOut){Emit $false 'H3_AFZ_BLOG_GH_SETUP_GIT_TIMEOUT' @{before=$before} 38}
if([int]$setup.exit -ne 0){Emit $false 'H3_AFZ_BLOG_GH_SETUP_GIT_FAILED' @{before=$before;ghSetupExit=$setup.exit} 39}
$authConfigChanged=$true
$access=Run-Bounded $gitExe @('ls-remote','--heads',$repo,'main') 20000 @{'GIT_TERMINAL_PROMPT'='0';'GCM_INTERACTIVE'='Never'}
if($access.timedOut){Emit $false 'H3_AFZ_BLOG_GIT_ACCESS_TIMEOUT' @{before=$before} 40}
if([int]$access.exit -ne 0){Emit $false 'H3_AFZ_BLOG_GIT_ACCESS_FAILED' @{before=$before;gitAccessExit=$access.exit} 41}
$line=@(($access.stdout -split "`r?`n")|Where-Object{$_ -match '^[0-9a-fA-F]{40}\s+refs/heads/main$'}|Select-Object -First 1)
if(-not $line){Emit $false 'H3_AFZ_BLOG_REMOTE_MAIN_UNRESOLVED' @{before=$before} 42}
$remoteSha=((([string]$line) -split '\s+')[0]).ToLowerInvariant()
if($remoteSha -ne $expectedSha){Emit $false 'H3_AFZ_BLOG_REMOTE_SHA_MISMATCH' @{before=$before;remoteSha=$remoteSha} 43}
$temp=Join-Path $env:TEMP ('afz-blog-compare-'+[guid]::NewGuid().ToString('n'))
try{
  Native @('init','--bare',$temp)|Out-Null
  Native @('--git-dir',$temp,'remote','add','origin',$repo)|Out-Null
  $fetch=Run-Bounded $gitExe @('--git-dir',$temp,'fetch','--depth','1','origin',$expectedSha) 60000 @{'GIT_TERMINAL_PROMPT'='0';'GCM_INTERACTIVE'='Never'}
  if($fetch.timedOut){Emit $false 'H3_AFZ_BLOG_COMPARE_FETCH_TIMEOUT' @{before=$before;remoteSha=$remoteSha} 44}
  if([int]$fetch.exit -ne 0){Emit $false 'H3_AFZ_BLOG_COMPARE_FETCH_FAILED' @{before=$before;remoteSha=$remoteSha;fetchExit=$fetch.exit} 45}
  Native @('--git-dir',$temp,'read-tree',$expectedSha)|Out-Null
  $status=Native @('--git-dir',$temp,'--work-tree',$workspace,'status','--porcelain=v1','-uall') -AllowFailure
  if($status.exit -ne 0){Emit $false 'H3_AFZ_BLOG_COMPARE_STATUS_FAILED' @{before=$before;remoteSha=$remoteSha} 46}
  $changes=@($status.lines|Where-Object{$_})
  $comparison=[ordered]@{matches=($changes.Count -eq 0);changeCount=$changes.Count;sample=@($changes|Select-Object -First 30)}
  if(-not $comparison.matches){Emit $false 'H3_AFZ_BLOG_SOURCE_DIFFERS_FROM_CANONICAL' @{before=$before;remoteSha=$remoteSha;comparison=$comparison} 47}
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
Native @('-C',$workspace,'init','-b','main')|Out-Null
$gitMetadataAttached=$true
Native @('-C',$workspace,'remote','add','origin',$repo)|Out-Null
$fetch2=Run-Bounded $gitExe @('-C',$workspace,'fetch','origin','main') 60000 @{'GIT_TERMINAL_PROMPT'='0';'GCM_INTERACTIVE'='Never'}
if($fetch2.timedOut){Emit $false 'H3_AFZ_BLOG_ATTACH_FETCH_TIMEOUT' @{before=$before;remoteSha=$remoteSha;comparison=$comparison} 48}
if([int]$fetch2.exit -ne 0){Emit $false 'H3_AFZ_BLOG_ATTACH_FETCH_FAILED' @{before=$before;remoteSha=$remoteSha;comparison=$comparison;fetchExit=$fetch2.exit} 49}
Native @('-C',$workspace,'reset','--mixed','origin/main')|Out-Null
$after=Snapshot
if(-not $after.gitRepo -or [string]$after.head -ne $expectedSha -or [string]$after.branch -ne 'main' -or [int]$after.dirtyCount -ne 0){Emit $false 'H3_AFZ_BLOG_POSTATTACH_VERIFY_FAILED' @{before=$before;remoteSha=$remoteSha;comparison=$comparison;after=$after} 50}
Emit $true 'H3_AFZ_BLOG_CHECKOUT_READY' @{before=$before;remoteSha=$remoteSha;comparison=$comparison;after=$after} 0
'@
  $remote=$remoteTemplate.Replace('__EXPECTED_SHA__',$ExpectedBlogSha)
  $in=Join-Path $env:TEMP ('afz-h3-blog-'+[guid]::NewGuid().ToString('n')+'.ps1')
  $out=Join-Path $env:TEMP ('afz-h3-blog-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('afz-h3-blog-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    [IO.File]::WriteAllText($in,$remote,$utf8)
    $args=@('-i',$key,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$known),$target,'powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command','-')
    $p=Start-Process -FilePath $ssh -ArgumentList $args -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(190000)){try{$p.Kill()}catch{};throw 'H3 AFZ Blog in-place attach relay timed out after 190 seconds.'}
    $stdout=$(if(Test-Path $out){[IO.File]::ReadAllText($out)}else{''});$stderr=$(if(Test-Path $err){[IO.File]::ReadAllText($err)}else{''})
    $jsonLine=@(($stdout -split "`r?`n")|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    if(-not $jsonLine){throw "No remote JSON. sshExit=$($p.ExitCode) stderr=$stderr"}
    $r=$jsonLine|ConvertFrom-Json
    if([string]$r.host -ne 'DESKTOP-H3R6CQN'){throw "Unexpected H3 host: $($r.host)"}
    $safe=[ordered]@{schema=1;ok=[bool]$r.ok;classification=[string]$r.classification;requestId=$RequestId;relayHost=$env:COMPUTERNAME;relayIdentity=$relayIdentity;remote=$r;productionModified=$false;credentialsEmitted=$false;time=(Get-Date -Format o)}
    Save-State $safe
    if(-not $safe.ok){exit 40}
    exit 0
  }finally{Remove-Item -LiteralPath $in,$out,$err -Force -ErrorAction SilentlyContinue}
}catch{
  Save-State ([ordered]@{schema=1;ok=$false;classification='H3_AFZ_BLOG_INPLACE_ATTACH_RELAY_FAILED';requestId=$RequestId;relayHost=$env:COMPUTERNAME;relayIdentity=$relayIdentity;error=$_.Exception.Message;productionModified=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
  exit 41
}
