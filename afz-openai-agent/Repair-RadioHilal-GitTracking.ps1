#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\AFZ\homelab-control')

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$expectedComputer='DESKTOP-10SKF0M'
$repo='C:\AFZ\RadioHilalGit'
$ops='C:\AFZ\RadioHilalGit-ops'
$expectedOrigin='https://github.com/f3arif/RadioHilal.git'
$mainBranch='main'
$opsBranch='github-ops'
$requiredMain='e55eac7f3130a5d513890d61ea442a091b21363d'
$bridgeTask='RadioHilal-GitHub-Bridge'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\radiohilal-git-tracking-repair'
$stateFile=Join-Path $stateRoot 'latest.json'
$diagRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$diagFile=Join-Path $diagRoot 'AFZ-RadioHilal-GitTrackingRepair-Latest.json'
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

function Write-Json([string]$Path,$Object){
  [IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 20 -Compress),$utf8)
}
function Publish($Object){
  Write-Json $stateFile $Object
  try{if(Test-Path -LiteralPath $diagRoot -PathType Container){Write-Json $diagFile $Object}}catch{}
  $Object|ConvertTo-Json -Depth 20 -Compress|Write-Output
}
function Normalize-Remote([string]$Value){
  return (($Value.Trim() -replace '\.git$','').TrimEnd('/')).ToLowerInvariant()
}
function Invoke-Git([string]$WorkingDirectory,[string[]]$Arguments,[switch]$AllowFailure){
  $old=$ErrorActionPreference
  $tag=[guid]::NewGuid().ToString('n')
  $outFile=Join-Path $env:TEMP ($tag+'.git.out.txt')
  $errFile=Join-Path $env:TEMP ($tag+'.git.err.txt')
  try{
    $ErrorActionPreference='Continue'
    $env:GIT_TERMINAL_PROMPT='0'
    $env:GCM_INTERACTIVE='Never'
    $gitArgs=@('-C',$WorkingDirectory)+@($Arguments)
    $p=Start-Process -FilePath 'git.exe' -ArgumentList $gitArgs -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru
    if(-not $p.WaitForExit(45000)){
      try{& taskkill.exe /PID $p.Id /T /F *> $null}catch{}
      $code=124
      $lines=@('git operation timed out after 45 seconds')
    }else{
      $code=[int]$p.ExitCode
      $lines=@()
      if(Test-Path -LiteralPath $outFile){$lines+=@(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue|ForEach-Object{[string]$_})}
      if(Test-Path -LiteralPath $errFile){$lines+=@(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue|ForEach-Object{[string]$_})}
    }
  }finally{
    $ErrorActionPreference=$old
    Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
  }
  $text=($lines -join [Environment]::NewLine).Trim()
  if($code -ne 0 -and -not $AllowFailure){throw "git $($Arguments -join ' ') failed exit=$code detail=$text"}
  return [pscustomobject]@{Code=[int]$code;Lines=$lines;Text=$text}
}
function Git-Text([string]$WorkingDirectory,[string[]]$Arguments){
  return (Invoke-Git $WorkingDirectory $Arguments).Text.Trim()
}
function Test-Ancestor([string]$WorkingDirectory,[string]$Ancestor,[string]$Descendant){
  $r=Invoke-Git $WorkingDirectory @('merge-base','--is-ancestor',$Ancestor,$Descendant) -AllowFailure
  return ($r.Code -eq 0)
}

$started=Get-Date
if($env:COMPUTERNAME -ne $expectedComputer){throw "WRONG_HOST expected=$expectedComputer actual=$($env:COMPUTERNAME)"}
if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){
  Publish ([ordered]@{schema=1;project='radiohilal';status='safe-stop';classification='RADIOHILAL_GIT_EXECUTABLE_MISSING';retryable=$true;host=$expectedComputer;time=(Get-Date -Format o)})
  exit 0
}
if(-not(Test-Path -LiteralPath (Join-Path $repo '.git'))){
  Publish ([ordered]@{schema=1;project='radiohilal';status='safe-stop';classification='RADIOHILAL_GIT_CHECKOUT_MISSING';retryable=$true;host=$expectedComputer;time=(Get-Date -Format o)})
  exit 0
}
$task=Get-ScheduledTask -TaskName $bridgeTask -ErrorAction SilentlyContinue
if($task -and [string]$task.State -eq 'Running'){
  Publish ([ordered]@{schema=1;project='radiohilal';status='safe-stop';classification='RADIOHILAL_BRIDGE_BUSY_RETRY';retryable=$true;host=$expectedComputer;bridgeTaskState='Running';time=(Get-Date -Format o)})
  exit 0
}

$mutex=New-Object Threading.Mutex($false,'Global\RadioHilalGitTrackingRepair')
$locked=$false
try{
  $locked=$mutex.WaitOne(0)
  if(-not $locked){
    Publish ([ordered]@{schema=1;project='radiohilal';status='safe-stop';classification='RADIOHILAL_GIT_REPAIR_ALREADY_RUNNING';retryable=$true;host=$expectedComputer;time=(Get-Date -Format o)})
    exit 0
  }

  $origin=Git-Text $repo @('remote','get-url','origin')
  if((Normalize-Remote $origin) -ne (Normalize-Remote $expectedOrigin)){throw "ORIGIN_MISMATCH actual=$origin"}
  $branch=Git-Text $repo @('symbolic-ref','--quiet','--short','HEAD')
  if($branch -ne $mainBranch){throw "MAIN_BRANCH_MISMATCH actual=$branch"}
  $dirty=Git-Text $repo @('status','--porcelain=v1')
  if($dirty){throw 'MAIN_CHECKOUT_DIRTY'}

  $before=Git-Text $repo @('rev-parse','HEAD')
  $ls=Invoke-Git $repo @('ls-remote','--exit-code','origin',"refs/heads/$mainBranch","refs/heads/$opsBranch") -AllowFailure
  if($ls.Code -ne 0){
    Publish ([ordered]@{
      schema=1;project='radiohilal';status='safe-stop';classification='RADIOHILAL_PRIVATE_GIT_AUTH_OR_NETWORK_UNAVAILABLE';retryable=$true
      host=$expectedComputer;mainBefore=$before;bridgeTaskState=$(if($task){[string]$task.State}else{'Missing'})
      gitExit=$ls.Code;detail=$ls.Text;requiredMain=$requiredMain;startedAt=$started.ToString('o');time=(Get-Date -Format o)
    })
    exit 0
  }

  $remoteMain='';$remoteOps=''
  foreach($line in $ls.Lines){
    if($line -match '^([0-9a-fA-F]{40})\s+refs/heads/main$'){$remoteMain=$Matches[1].ToLowerInvariant()}
    elseif($line -match '^([0-9a-fA-F]{40})\s+refs/heads/github-ops$'){$remoteOps=$Matches[1].ToLowerInvariant()}
  }
  if($remoteMain -notmatch '^[0-9a-f]{40}$' -or $remoteOps -notmatch '^[0-9a-f]{40}$'){throw "REMOTE_REFS_UNRESOLVED main=$remoteMain ops=$remoteOps"}

  $mainRefspec='+refs/heads/' + $mainBranch + ':refs/remotes/origin/' + $mainBranch
  $opsRefspec='+refs/heads/' + $opsBranch + ':refs/remotes/origin/' + $opsBranch
  Invoke-Git $repo @('fetch','--prune','origin',$mainRefspec,$opsRefspec) | Out-Null
  $trackedMain=Git-Text $repo @('rev-parse',"origin/$mainBranch")
  $trackedOps=Git-Text $repo @('rev-parse',"origin/$opsBranch")
  if($trackedMain.ToLowerInvariant() -ne $remoteMain){throw "MAIN_TRACKING_REF_MISMATCH expected=$remoteMain actual=$trackedMain"}
  if($trackedOps.ToLowerInvariant() -ne $remoteOps){throw "OPS_TRACKING_REF_MISMATCH expected=$remoteOps actual=$trackedOps"}
  if(-not(Test-Ancestor $repo $requiredMain $remoteMain)){throw "REQUIRED_MAIN_NOT_CONTAINED required=$requiredMain remote=$remoteMain"}

  if($before.ToLowerInvariant() -ne $remoteMain){
    if(-not(Test-Ancestor $repo $before $remoteMain)){throw "MAIN_NOT_FAST_FORWARD before=$before remote=$remoteMain"}
    $backupRef='refs/radiohilal-backups/system-repair-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    Invoke-Git $repo @('update-ref',$backupRef,$before) | Out-Null
    Invoke-Git $repo @('merge','--ff-only',"origin/$mainBranch") | Out-Null
  }
  $after=Git-Text $repo @('rev-parse','HEAD')
  if($after.ToLowerInvariant() -ne $remoteMain){throw "MAIN_POST_REPAIR_MISMATCH expected=$remoteMain actual=$after"}

  $opsStatus='not-present'
  if(Test-Path -LiteralPath $ops){
    $opsDirty=Git-Text $ops @('status','--porcelain=v1')
    if($opsDirty){throw 'OPS_WORKTREE_DIRTY'}
    $opsCurrentBranch=Git-Text $ops @('symbolic-ref','--quiet','--short','HEAD')
    if($opsCurrentBranch -ne $opsBranch){throw "OPS_BRANCH_MISMATCH actual=$opsCurrentBranch"}
    $opsBefore=Git-Text $ops @('rev-parse','HEAD')
    if($opsBefore.ToLowerInvariant() -ne $remoteOps){
      if(-not(Test-Ancestor $ops $opsBefore $remoteOps)){throw "OPS_NOT_FAST_FORWARD before=$opsBefore remote=$remoteOps"}
      Invoke-Git $ops @('merge','--ff-only',"origin/$opsBranch") | Out-Null
    }
    $opsAfter=Git-Text $ops @('rev-parse','HEAD')
    if($opsAfter.ToLowerInvariant() -ne $remoteOps){throw "OPS_POST_REPAIR_MISMATCH expected=$remoteOps actual=$opsAfter"}
    $opsStatus='current'
  }

  $task=Get-ScheduledTask -TaskName $bridgeTask -ErrorAction SilentlyContinue
  if(-not $task){throw "BRIDGE_TASK_MISSING $bridgeTask"}
  if([string]$task.State -ne 'Running'){Start-ScheduledTask -TaskName $bridgeTask -ErrorAction Stop}
  $taskAfter=Get-ScheduledTask -TaskName $bridgeTask -ErrorAction SilentlyContinue

  Publish ([ordered]@{
    schema=1;project='radiohilal';status='completed';classification='RADIOHILAL_GIT_TRACKING_REPAIRED';retryable=$false
    host=$expectedComputer;mainBefore=$before;remoteMain=$remoteMain;mainAfter=$after
    remoteOps=$remoteOps;opsStatus=$opsStatus;requiredMain=$requiredMain
    bridgeTaskState=$(if($taskAfter){[string]$taskAfter.State}else{'Missing'})
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  })
  exit 0
}catch{
  Publish ([ordered]@{
    schema=1;project='radiohilal';status='failed';classification='RADIOHILAL_GIT_TRACKING_REPAIR_FAILED';retryable=$false
    host=$expectedComputer;error=$_.Exception.Message;requiredMain=$requiredMain
    startedAt=$started.ToString('o');finishedAt=(Get-Date -Format o)
  })
  exit 1
}finally{
  if($locked){try{$mutex.ReleaseMutex()}catch{}}
  $mutex.Dispose()
}
