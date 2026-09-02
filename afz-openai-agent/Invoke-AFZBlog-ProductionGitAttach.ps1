#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('audit','apply')][string]$Action='audit',
  [string]$RequestId='afz-blog-production-git-attach-r1',
  [string]$ExpectedBlogSha='a37e71aa0e0c9fad41ecdc9652a7024c485666f4'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$root='C:\docker\afz-blog-manager'
$repo='https://github.com/f3arif/AFZ-Blog.git'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-production-git-attach'
$statePath=Join-Path $stateRoot 'latest.json'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-BLOG-PRODUCTION-GIT-ATTACH-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot|Out-Null

function Save-State($o){
  $json=$o|ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($statePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($o|ConvertTo-Json -Depth 20 -Compress)
}

function Run-Git([string[]]$Args,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$lines=@(& git @Args 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw ('git failed exit='+$code)}
  [pscustomobject]@{exit=[int]$code;lines=$lines;text=($lines -join "`n")}
}

function Test-RemoteSha {
  $oldGcm=$env:GCM_INTERACTIVE;$oldPrompt=$env:GIT_TERMINAL_PROMPT
  try{
    $env:GCM_INTERACTIVE='Never';$env:GIT_TERMINAL_PROMPT='0'
    $r=Run-Git @('ls-remote','--heads',$repo,'main') -AllowFailure
  }finally{$env:GCM_INTERACTIVE=$oldGcm;$env:GIT_TERMINAL_PROMPT=$oldPrompt}
  if($r.exit -ne 0){return [ordered]@{accessible=$false;sha=$null;matchesExpected=$false}}
  $first=@($r.lines|Where-Object{$_ -match '^[0-9a-fA-F]{40}\s+'}|Select-Object -First 1)
  $sha=$(if($first){(([string]$first) -split '\s+')[0].ToLowerInvariant()}else{$null})
  [ordered]@{accessible=[bool]$sha;sha=$sha;matchesExpected=([string]$sha -eq $ExpectedBlogSha)}
}

function Get-LegacySnapshot {
  $gitDir=Join-Path $root '.git'
  $exists=Test-Path -LiteralPath $gitDir -PathType Container
  $head=$null;$branch=$null;$dirty=$null;$remotes=@()
  if($exists){
    $head=(Run-Git @('-C',$root,'rev-parse','HEAD') -AllowFailure).text.Trim().ToLowerInvariant()
    $branch=(Run-Git @('-C',$root,'branch','--show-current') -AllowFailure).text.Trim()
    $dirty=@((Run-Git @('-C',$root,'status','--porcelain=v1','-uall') -AllowFailure).lines|Where-Object{$_}).Count
    $remotes=@((Run-Git @('-C',$root,'remote','-v') -AllowFailure).lines|Where-Object{$_})
  }
  [ordered]@{gitExists=$exists;head=$(if($head){$head}else{$null});branch=$(if($branch){$branch}else{$null});dirtyCount=$dirty;remoteLineCount=$remotes.Count}
}

function Compare-CanonicalWorktree {
  $temp=Join-Path $env:TEMP ('afz-blog-attach-audit-'+[guid]::NewGuid().ToString('n'))
  $oldGcm=$env:GCM_INTERACTIVE;$oldPrompt=$env:GIT_TERMINAL_PROMPT
  try{
    New-Item -ItemType Directory -Force -Path $temp|Out-Null
    Run-Git @('init','--bare',$temp)|Out-Null
    Run-Git @('--git-dir',$temp,'remote','add','origin',$repo)|Out-Null
    $env:GCM_INTERACTIVE='Never';$env:GIT_TERMINAL_PROMPT='0'
    Run-Git @('--git-dir',$temp,'fetch','--depth','1','origin',$ExpectedBlogSha)|Out-Null
    Run-Git @('--git-dir',$temp,'read-tree',$ExpectedBlogSha)|Out-Null
    $s=Run-Git @('--git-dir',$temp,'--work-tree',$root,'status','--porcelain=v1','-uall') -AllowFailure
    if($s.exit -ne 0){throw 'Canonical worktree comparison failed.'}
    $changes=@($s.lines|Where-Object{$_})
    $sample=@($changes|Select-Object -First 25)
    return [ordered]@{matches=($changes.Count -eq 0);changeCount=$changes.Count;sample=$sample}
  }finally{
    $env:GCM_INTERACTIVE=$oldGcm;$env:GIT_TERMINAL_PROMPT=$oldPrompt
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

try{
  if($env:COMPUTERNAME -ne $expectedHost){throw "Wrong host: $($env:COMPUTERNAME)"}
  if($RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid RequestId'}
  if($ExpectedBlogSha -notmatch '^[0-9a-fA-F]{40}$'){throw 'ExpectedBlogSha must be 40 hex characters'}
  $ExpectedBlogSha=$ExpectedBlogSha.ToLowerInvariant()
  if(-not(Test-Path -LiteralPath $root -PathType Container)){throw "Production root missing: $root"}
  if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){throw 'git.exe is missing'}

  $legacy=Get-LegacySnapshot
  $remote=Test-RemoteSha
  $envState=[ordered]@{envPresent=(Test-Path -LiteralPath (Join-Path $root '.env') -PathType Leaf);envLocalPresent=(Test-Path -LiteralPath (Join-Path $root '.env.local') -PathType Leaf)}
  $comparison=$null
  if($remote.accessible -and $remote.matchesExpected){$comparison=Compare-CanonicalWorktree}
  $auditSafe=([bool]$remote.accessible -and [bool]$remote.matchesExpected -and $null -ne $comparison -and [bool]$comparison.matches)

  if($Action -eq 'audit'){
    Save-State ([ordered]@{schema=1;ok=$true;classification='AFZ_BLOG_PRODUCTION_GIT_ATTACH_AUDIT_COMPLETE';requestId=$RequestId;host=$env:COMPUTERNAME;action='audit';root=$root;repository=$repo;expectedSha=$ExpectedBlogSha;remote=$remote;legacy=$legacy;environment=$envState;comparison=$comparison;safeToAttach=$auditSafe;productionWorkingFilesModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    exit 0
  }

  if(-not $auditSafe){
    Save-State ([ordered]@{schema=1;ok=$false;classification='AFZ_BLOG_PRODUCTION_GIT_ATTACH_BLOCKED_BY_AUDIT';requestId=$RequestId;host=$env:COMPUTERNAME;action='apply';root=$root;repository=$repo;expectedSha=$ExpectedBlogSha;remote=$remote;legacy=$legacy;environment=$envState;comparison=$comparison;safeToAttach=$false;productionWorkingFilesModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    exit 40
  }
  if(-not [bool]$legacy.gitExists){throw 'Legacy .git directory is missing; refusing implicit repository replacement.'}

  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $legacyGit=Join-Path $root '.git'
  $backupGit=Join-Path $root ('.git.pre-github-'+$stamp)
  $newGitCreated=$false
  $legacyRenamed=$false
  try{
    Rename-Item -LiteralPath $legacyGit -NewName ([IO.Path]::GetFileName($backupGit)) -ErrorAction Stop
    $legacyRenamed=$true
    Run-Git @('-C',$root,'init','-b','main')|Out-Null
    $newGitCreated=$true
    Run-Git @('-C',$root,'remote','add','origin',$repo)|Out-Null
    $oldGcm=$env:GCM_INTERACTIVE;$oldPrompt=$env:GIT_TERMINAL_PROMPT
    try{$env:GCM_INTERACTIVE='Never';$env:GIT_TERMINAL_PROMPT='0';Run-Git @('-C',$root,'fetch','origin','main')|Out-Null}
    finally{$env:GCM_INTERACTIVE=$oldGcm;$env:GIT_TERMINAL_PROMPT=$oldPrompt}
    Run-Git @('-C',$root,'reset','--mixed','origin/main')|Out-Null
    $head=(Run-Git @('-C',$root,'rev-parse','HEAD')).text.Trim().ToLowerInvariant()
    $branch=(Run-Git @('-C',$root,'branch','--show-current')).text.Trim()
    $origin=(Run-Git @('-C',$root,'remote','get-url','origin')).text.Trim()
    $dirty=@((Run-Git @('-C',$root,'status','--porcelain=v1','-uall')).lines|Where-Object{$_}).Count
    if($head -ne $ExpectedBlogSha -or $branch -ne 'main' -or $origin.TrimEnd('/').ToLowerInvariant() -ne $repo.TrimEnd('/').ToLowerInvariant() -or $dirty -ne 0){throw "Post-attach verification failed head=$head branch=$branch dirty=$dirty"}
    Save-State ([ordered]@{schema=1;ok=$true;classification='AFZ_BLOG_PRODUCTION_GIT_ATTACHED';requestId=$RequestId;host=$env:COMPUTERNAME;action='apply';root=$root;repository=$repo;expectedSha=$ExpectedBlogSha;head=$head;branch=$branch;origin=$origin;dirtyCount=$dirty;legacyGitBackup=$backupGit;environment=$envState;productionWorkingFilesModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    exit 0
  }catch{
    $attachError=$_.Exception.Message
    if($newGitCreated -and (Test-Path -LiteralPath $legacyGit -PathType Container)){Remove-Item -LiteralPath $legacyGit -Recurse -Force -ErrorAction SilentlyContinue}
    if($legacyRenamed -and (Test-Path -LiteralPath $backupGit -PathType Container) -and -not(Test-Path -LiteralPath $legacyGit)){Rename-Item -LiteralPath $backupGit -NewName '.git' -ErrorAction SilentlyContinue}
    Save-State ([ordered]@{schema=1;ok=$false;classification='AFZ_BLOG_PRODUCTION_GIT_ATTACH_ROLLED_BACK';requestId=$RequestId;host=$env:COMPUTERNAME;action='apply';root=$root;repository=$repo;expectedSha=$ExpectedBlogSha;error=$attachError;productionWorkingFilesModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
    exit 41
  }
}catch{
  Save-State ([ordered]@{schema=1;ok=$false;classification='AFZ_BLOG_PRODUCTION_GIT_ATTACH_FAILED';requestId=$RequestId;host=$env:COMPUTERNAME;action=$Action;root=$root;repository=$repo;expectedSha=$ExpectedBlogSha;error=$_.Exception.Message;productionWorkingFilesModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;time=(Get-Date -Format o)})
  exit 42
}
