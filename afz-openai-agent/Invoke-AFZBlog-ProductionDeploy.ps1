#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$expectedRoot='C:\docker\afz-blog-manager'
$taskName='AFZ Blog Manager'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-BLOG-PRODUCTION-DEPLOY-LATEST.txt'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-production-deploy'
$runtimeRoot='C:\AFZ\Runtime\AFZ-Blog'
$utf8=New-Object Text.UTF8Encoding($false)

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-production-deploy.json'
}

New-Item -ItemType Directory -Force -Path $stateRoot,$runtimeRoot | Out-Null

function Save-Result($Object,[string]$StatePath){
  $json=$Object|ConvertTo-Json -Depth 24
  [IO.File]::WriteAllText($StatePath,$json,$utf8)
  try{
    if(Test-Path -LiteralPath $mirrorRoot -PathType Container){
      [IO.File]::WriteAllText($mirrorPath,$json,$utf8)
    }
  }catch{}
  Write-Output ($Object|ConvertTo-Json -Depth 24 -Compress)
}

function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}
}

function Run-Git([string[]]$ArgumentVector,[switch]$AllowFailure){
  $git=Get-Command git.exe -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($git.Path){[string]$git.Path}else{[string]$git.Source})
  $old=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $lines=@(& $exe @ArgumentVector 2>&1|ForEach-Object{[string]$_})
    $code=$LASTEXITCODE
  }finally{
    $ErrorActionPreference=$old
  }
  if(-not $AllowFailure -and $code -ne 0){
    throw ('git failed exit='+$code+' args='+($ArgumentVector -join ' ')+' tail='+(($lines|Select-Object -Last 6)-join ' | '))
  }
  [pscustomobject]@{exit=[int]$code;lines=$lines;text=($lines -join [Environment]::NewLine)}
}

function Run-Npm([string[]]$ArgumentVector,[string]$LogPath){
  $npm=Get-Command npm.cmd -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($npm.Path){[string]$npm.Path}else{[string]$npm.Source})
  $out=Join-Path $env:TEMP ('afz-blog-npm-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('afz-blog-npm-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    $p=Start-Process -FilePath $exe -ArgumentList $ArgumentVector -WorkingDirectory $expectedRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(600000)){
      try{$p.Kill()}catch{}
      throw ('npm timed out: '+($ArgumentVector -join ' '))
    }
    $stdout=$(if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $err){[IO.File]::ReadAllText($err)}else{''})
    $combined=$stdout
    if(-not [string]::IsNullOrWhiteSpace($stderr)){
      $combined=$combined+[Environment]::NewLine+'--- STDERR ---'+[Environment]::NewLine+$stderr
    }
    [IO.File]::WriteAllText($LogPath,$combined,$utf8)
    if([int]$p.ExitCode -ne 0){
      throw ('npm exit='+$p.ExitCode+' args='+($ArgumentVector -join ' ')+' log='+$LogPath)
    }
    return [int]$p.ExitCode
  }finally{
    Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
  }
}

function Hash-IfPresent([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ListenerPids {
  try{
    return @(
      Get-NetTCPConnection -LocalPort 3015 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object{[int]$_}
    )
  }catch{
    return @()
  }
}

function Stop-BlogRuntime {
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($task -and [string]$task.State -eq 'Running'){
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  }
  foreach($pidValue in @(Get-ListenerPids)){
    Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
  }
  for($i=0;$i -lt 20;$i++){
    if(@(Get-ListenerPids).Count -eq 0){return}
    Start-Sleep -Milliseconds 500
  }
  throw 'Port 3015 remained in LISTEN state after bounded stop.'
}

function Start-BlogRuntime {
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $httpStatus=$null
  $httpError=$null
  $listenerPid=$null
  for($i=0;$i -lt 60;$i++){
    $pids=@(Get-ListenerPids)
    if($pids.Count -gt 0){
      $listenerPid=[int]$pids[0]
      try{
        $w=Invoke-WebRequest -Uri 'http://127.0.0.1:3015/' -UseBasicParsing -TimeoutSec 5
        $httpStatus=[int]$w.StatusCode
        if($httpStatus -ge 200 -and $httpStatus -lt 500){
          return [ordered]@{ok=$true;listenerPid=$listenerPid;httpStatus=$httpStatus;httpError=$null}
        }
      }catch{
        $httpError=$_.Exception.Message
      }
    }
    Start-Sleep -Seconds 1
  }
  return [ordered]@{ok=$false;listenerPid=$listenerPid;httpStatus=$httpStatus;httpError=$httpError}
}

function Git-Snapshot {
  $head=(Run-Git @('-C',$expectedRoot,'rev-parse','HEAD')).text.Trim().ToLowerInvariant()
  $branch=(Run-Git @('-C',$expectedRoot,'branch','--show-current')).text.Trim()
  $origin=(Run-Git @('-C',$expectedRoot,'remote','get-url','origin')).text.Trim()
  $dirty=@((Run-Git @('-C',$expectedRoot,'status','--porcelain=v1','-uall')).lines|Where-Object{$_}).Count
  return [ordered]@{head=$head;branch=$branch;origin=$origin;dirtyCount=$dirty}
}

$result=[ordered]@{
  schema=1
  purpose='AFZ_BLOG_PRODUCTION_DEPLOY'
  ok=$false
  classification='STARTING'
  host=$env:COMPUTERNAME
  productionRoot=$expectedRoot
  productionModified=$false
  productionDatabaseModified=$false
  serviceRestarted=$false
  websitePublished=$false
  credentialsEmitted=$false
  rollbackAttempted=$false
  rollbackHealthy=$null
  time=(Get-Date -Format o)
}

$request=$null
$statePath=$null
$lockPath=$null
$lockStream=$null
$beforeHead=$null
$mutationStarted=$false
$serviceWasStopped=$false
$dependencyRefreshNeeded=$false
$dbBefore=$null
$envBefore=$null
$envLocalBefore=$null
$dbBackupDir=$null
$databaseUntrackMigration=$false

try{
  if($env:COMPUTERNAME -ne $expectedHost){throw ('Wrong host: '+$env:COMPUTERNAME)}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $result.identity=[string]$identity.Name
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw ('Deployment helper requires SYSTEM. Actual: '+$identity.Name)}
  if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw ('Request missing: '+$RequestPath)}

  $request=Read-Json $RequestPath
  if(-not $request){throw 'Request JSON unreadable.'}
  $id=([string]$request.id).Trim()
  if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id.'}
  $statePath=Join-Path $stateRoot ($id+'.json')
  $lockPath=Join-Path $stateRoot ($id+'.lock')

  $prior=Read-Json $statePath
  if($prior -and [string]$prior.classification -in @(
    'AFZ_BLOG_PRODUCTION_DEPLOY_COMPLETED',
    'AFZ_BLOG_PRODUCTION_DEPLOY_ALREADY_CURRENT',
    'AFZ_BLOG_PRODUCTION_DEPLOY_ROLLED_BACK',
    'AFZ_BLOG_PRODUCTION_DEPLOY_BLOCKED'
  )){
    Write-Output ($prior|ConvertTo-Json -Depth 24 -Compress)
    exit $(if([bool]$prior.ok){0}else{20})
  }

  if([int]$request.schema -ne 1 -or [string]$request.status -ne 'ACTIVE' -or [string]$request.action -ne 'deploy-validated-main'){
    throw 'Request is not an active deploy-validated-main request.'
  }
  if([string]$request.target -ne 'windows-main' -or [string]$request.host -ne $expectedHost){throw 'Request target mismatch.'}
  if([string]$request.production_root -ne $expectedRoot){throw 'Request production root mismatch.'}
  if(-not [bool]$request.require_clean -or -not [bool]$request.require_fast_forward -or -not [bool]$request.allow_build -or -not [bool]$request.allow_service_restart -or [bool]$request.allow_database_mutation -or [bool]$request.allow_schema_or_migration_change -or [bool]$request.allow_website_publish -or -not [bool]$request.rollback_on_failure -or -not [bool]$request.allow_database_untrack_migration){
    throw 'Request safety policy mismatch.'
  }

  $expectedCurrent=([string]$request.expected_current_sha).Trim().ToLowerInvariant()
  $expectedSha=([string]$request.expected_blog_sha).Trim().ToLowerInvariant()
  if($expectedCurrent -notmatch '^[0-9a-f]{40}$' -or $expectedSha -notmatch '^[0-9a-f]{40}$'){throw 'Request SHA is invalid.'}
  $result.requestId=$id
  $result.expectedCurrentSha=$expectedCurrent
  $result.expectedBlogSha=$expectedSha

  try{
    $lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  }catch{
    throw 'Deployment request is already in flight.'
  }

  if(-not(Test-Path -LiteralPath $expectedRoot -PathType Container)){throw 'Production root missing.'}
  if(-not(Test-Path -LiteralPath (Join-Path $expectedRoot '.git') -PathType Container)){throw 'Production root is not a Git checkout.'}
  if(-not(Get-Command git.exe -ErrorAction SilentlyContinue)){throw 'git.exe missing.'}
  if(-not(Get-Command npm.cmd -ErrorAction SilentlyContinue)){throw 'npm.cmd missing.'}

  $before=Git-Snapshot
  $beforeHead=[string]$before.head
  $result.before=[ordered]@{git=$before;listenerPids=@(Get-ListenerPids)}
  if([string]$before.branch -ne 'main'){throw ('Production branch is not main: '+$before.branch)}
  if(([string]$before.origin).TrimEnd('/').ToLowerInvariant() -ne 'https://github.com/f3arif/afz-blog.git'){throw ('Production origin mismatch: '+$before.origin)}
  if([int]$before.dirtyCount -ne 0){throw ('Production checkout is dirty: '+$before.dirtyCount)}

  if($beforeHead -eq $expectedSha){
    $health=Start-BlogRuntime
    if(-not [bool]$health.ok){throw 'Production is already current but health could not be verified.'}
    $result.ok=$true
    $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_ALREADY_CURRENT'
    $result.health=$health
    $result.time=(Get-Date -Format o)
    Save-Result $result $statePath
    exit 0
  }

  if($beforeHead -ne $expectedCurrent){throw ('Unexpected current production SHA: '+$beforeHead+' expected='+$expectedCurrent)}

  $oldGcm=$env:GCM_INTERACTIVE
  $oldPrompt=$env:GIT_TERMINAL_PROMPT
  try{
    $env:GCM_INTERACTIVE='Never'
    $env:GIT_TERMINAL_PROMPT='0'
    $fetch=Run-Git @('-C',$expectedRoot,'fetch','--prune','origin','main') -AllowFailure
  }finally{
    $env:GCM_INTERACTIVE=$oldGcm
    $env:GIT_TERMINAL_PROMPT=$oldPrompt
  }
  if([int]$fetch.exit -ne 0){throw ('Production Git fetch failed: '+(($fetch.lines|Select-Object -Last 6)-join ' | '))}
  $remoteSha=(Run-Git @('-C',$expectedRoot,'rev-parse','origin/main')).text.Trim().ToLowerInvariant()
  $result.remoteSha=$remoteSha
  if($remoteSha -ne $expectedSha){throw ('Remote SHA mismatch: '+$remoteSha+' expected='+$expectedSha)}

  $ancestor=Run-Git @('-C',$expectedRoot,'merge-base','--is-ancestor',$beforeHead,$expectedSha) -AllowFailure
  if([int]$ancestor.exit -ne 0){throw 'Production source is not an ancestor of the requested main SHA; fast-forward refused.'}

  $changed=@((Run-Git @('-C',$expectedRoot,'diff','--name-only',$beforeHead,$expectedSha)).lines|Where-Object{$_})
  $result.changedFiles=$changed
  $blocked=@($changed|Where-Object{
    $_ -eq 'prisma/schema.prisma' -or
    $_ -like 'prisma/migrations/*' -or
    $_ -match '(^|/)\.env($|\.)'
  })
  if($blocked.Count -gt 0){
    $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_BLOCKED'
    $result.blockedFiles=$blocked
    $result.time=(Get-Date -Format o)
    Save-Result $result $statePath
    exit 40
  }

  $dbStatus=@((Run-Git @('-C',$expectedRoot,'diff','--name-status',$beforeHead,$expectedSha,'--','data/afz-blog.db')).lines|Where-Object{$_})
  $dbRemovalProven=(@($dbStatus|Where-Object{$_ -match '^D\s+data/afz-blog[.]db$'}).Count -eq 1)
  if(-not $dbRemovalProven){
    $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_BLOCKED'
    $result.blockedReason='Expected target must remove the tracked data/afz-blog.db exactly once.'
    $result.databaseDiff=$dbStatus
    $result.time=(Get-Date -Format o)
    Save-Result $result $statePath
    exit 40
  }

  $targetGitIgnore=(Run-Git @('-C',$expectedRoot,'show',($expectedSha+':.gitignore'))).text
  if($targetGitIgnore -notmatch '(?m)^\*\.db\s*$'){
    $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_BLOCKED'
    $result.blockedReason='Target .gitignore does not ignore *.db; runtime DB preservation refused.'
    $result.time=(Get-Date -Format o)
    Save-Result $result $statePath
    exit 40
  }
  $databaseUntrackMigration=$true
  $result.databaseUntrackMigration=$true

  $dependencyRefreshNeeded=(@($changed|Where-Object{$_ -in @('package.json','package-lock.json')}).Count -gt 0)
  $result.dependencyRefreshNeeded=$dependencyRefreshNeeded

  $dbPath=Join-Path $expectedRoot 'data\afz-blog.db'
  $envPath=Join-Path $expectedRoot '.env'
  $envLocalPath=Join-Path $expectedRoot '.env.local'
  $dbBefore=Hash-IfPresent $dbPath
  if([string]::IsNullOrWhiteSpace([string]$dbBefore)){throw 'Production runtime database is missing before deployment.'}
  $envBefore=Hash-IfPresent $envPath
  $envLocalBefore=Hash-IfPresent $envLocalPath
  $result.integrityBefore=[ordered]@{
    databaseSha256=$dbBefore
    envSha256=$envBefore
    envLocalSha256=$envLocalBefore
    envPresent=(Test-Path -LiteralPath $envPath -PathType Leaf)
    envLocalPresent=(Test-Path -LiteralPath $envLocalPath -PathType Leaf)
  }

  Stop-BlogRuntime
  $serviceWasStopped=$true

  $dbQuiesced=Hash-IfPresent $dbPath
  if([string]::IsNullOrWhiteSpace([string]$dbQuiesced)){throw 'Production runtime database disappeared while quiescing the service.'}
  if([string]$dbQuiesced -ne [string]$dbBefore){
    $result.databaseChangedDuringQuiesce=$true
    $dbBefore=$dbQuiesced
    $result.integrityBefore.databaseSha256=$dbBefore
  }else{
    $result.databaseChangedDuringQuiesce=$false
  }

  $backupRoot='C:\ProgramData\AFZ\AFZ-Blog\deploy-backups'
  $dbBackupDir=Join-Path $backupRoot ('a223-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $dbBackupDir | Out-Null
  $dbBackupPath=Join-Path $dbBackupDir 'afz-blog.db'
  Copy-Item -LiteralPath $dbPath -Destination $dbBackupPath -Force
  foreach($suffix in @('-wal','-shm','-journal')){
    $src=$dbPath+$suffix
    if(Test-Path -LiteralPath $src -PathType Leaf){
      Copy-Item -LiteralPath $src -Destination (Join-Path $dbBackupDir ('afz-blog.db'+$suffix)) -Force
    }
  }
  $dbBackupHash=Hash-IfPresent $dbBackupPath
  if([string]$dbBackupHash -ne [string]$dbBefore){throw 'External runtime database backup hash mismatch.'}
  $result.databaseBackup=[ordered]@{directory=$dbBackupDir;databaseSha256=$dbBackupHash;outsideGitRoot=$true}

  $merge=Run-Git @('-C',$expectedRoot,'merge','--ff-only','origin/main') -AllowFailure
  if([int]$merge.exit -ne 0){throw ('Fast-forward merge failed: '+(($merge.lines|Select-Object -Last 6)-join ' | '))}
  $mutationStarted=$true
  $result.productionModified=$true

  $afterMerge=Git-Snapshot
  if([string]$afterMerge.head -ne $expectedSha -or [string]$afterMerge.branch -ne 'main' -or [int]$afterMerge.dirtyCount -ne 0){
    throw 'Post-fast-forward Git verification failed.'
  }

  New-Item -ItemType Directory -Force -Path (Split-Path $dbPath -Parent) | Out-Null
  Copy-Item -LiteralPath (Join-Path $dbBackupDir 'afz-blog.db') -Destination $dbPath -Force
  foreach($suffix in @('-wal','-shm','-journal')){
    $dst=$dbPath+$suffix
    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    $src=Join-Path $dbBackupDir ('afz-blog.db'+$suffix)
    if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination $dst -Force}
  }
  $restoredDbHash=Hash-IfPresent $dbPath
  if([string]$restoredDbHash -ne [string]$dbBefore){throw 'Restored runtime database hash mismatch after Git fast-forward.'}
  $ignored=Run-Git @('-C',$expectedRoot,'check-ignore','--quiet','data/afz-blog.db') -AllowFailure
  if([int]$ignored.exit -ne 0){throw 'Restored runtime database is not ignored by target Git policy.'}
  $afterRestore=Git-Snapshot
  if([int]$afterRestore.dirtyCount -ne 0){throw 'Production checkout became dirty after restoring ignored runtime database.'}
  $result.databaseRestoredAsIgnoredRuntimeData=$true

  if($dependencyRefreshNeeded){
    $installLog=Join-Path $runtimeRoot ('npm-ci-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    [void](Run-Npm @('ci') $installLog)
    $result.installLog=$installLog
  }

  $buildLog=Join-Path $runtimeRoot ('build-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
  [void](Run-Npm @('run','build') $buildLog)
  $result.buildLog=$buildLog

  $health=Start-BlogRuntime
  $result.serviceRestarted=$true
  if(-not [bool]$health.ok){throw ('Production health failed after deploy: '+[string]$health.httpError)}

  $dbAfter=Hash-IfPresent $dbPath
  $envAfter=Hash-IfPresent $envPath
  $envLocalAfter=Hash-IfPresent $envLocalPath
  $integrityOk=([string]$dbBefore -eq [string]$dbAfter -and [string]$envBefore -eq [string]$envAfter -and [string]$envLocalBefore -eq [string]$envLocalAfter)
  $result.integrityAfter=[ordered]@{
    databaseSha256=$dbAfter
    envSha256=$envAfter
    envLocalSha256=$envLocalAfter
    preserved=$integrityOk
  }
  if(-not $integrityOk){throw 'Production database or environment-file hash changed during deployment.'}

  $final=Git-Snapshot
  if([string]$final.head -ne $expectedSha -or [int]$final.dirtyCount -ne 0){throw 'Final production Git verification failed.'}

  $result.ok=$true
  $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_COMPLETED'
  $result.after=[ordered]@{git=$final;health=$health}
  $result.productionDatabaseModified=$false
  $result.databasePreserved=([string]$dbAfter -eq [string]$dbBefore)
  $result.environmentModified=$false
  $result.schemaMigrationExecuted=$false
  $result.websitePublished=$false
  $result.time=(Get-Date -Format o)
  Save-Result $result $statePath
  exit 0
}catch{
  $failure=$_.Exception.Message
  $result.error=$failure

  if($mutationStarted -and $request -and [bool]$request.rollback_on_failure -and $beforeHead -match '^[0-9a-f]{40}$'){
    $result.rollbackAttempted=$true
    try{
      Stop-BlogRuntime
      [void](Run-Git @('-C',$expectedRoot,'reset','--hard',$beforeHead))
      if($dbBackupDir -and (Test-Path -LiteralPath (Join-Path $dbBackupDir 'afz-blog.db') -PathType Leaf)){
        Copy-Item -LiteralPath (Join-Path $dbBackupDir 'afz-blog.db') -Destination (Join-Path $expectedRoot 'data\afz-blog.db') -Force
        foreach($suffix in @('-wal','-shm','-journal')){
          $dst=(Join-Path $expectedRoot 'data\afz-blog.db')+$suffix
          Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
          $src=Join-Path $dbBackupDir ('afz-blog.db'+$suffix)
          if(Test-Path -LiteralPath $src -PathType Leaf){Copy-Item -LiteralPath $src -Destination $dst -Force}
        }
      }
      if($dependencyRefreshNeeded){
        $rollbackInstallLog=Join-Path $runtimeRoot ('rollback-npm-ci-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
        [void](Run-Npm @('ci') $rollbackInstallLog)
        $result.rollbackInstallLog=$rollbackInstallLog
      }
      $rollbackBuildLog=Join-Path $runtimeRoot ('rollback-build-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
      [void](Run-Npm @('run','build') $rollbackBuildLog)
      $result.rollbackBuildLog=$rollbackBuildLog
      $rollbackHealth=Start-BlogRuntime
      $result.rollbackHealthy=[bool]$rollbackHealth.ok
      $result.rollbackHealth=$rollbackHealth
      $dbRollback=Hash-IfPresent (Join-Path $expectedRoot 'data\afz-blog.db')
      $envRollback=Hash-IfPresent (Join-Path $expectedRoot '.env')
      $envLocalRollback=Hash-IfPresent (Join-Path $expectedRoot '.env.local')
      $result.rollbackIntegrityPreserved=([string]$dbBefore -eq [string]$dbRollback -and [string]$envBefore -eq [string]$envRollback -and [string]$envLocalBefore -eq [string]$envLocalRollback)
      $rolled=Git-Snapshot
      if([string]$rolled.head -eq $beforeHead -and [int]$rolled.dirtyCount -eq 0 -and [bool]$rollbackHealth.ok -and [bool]$result.rollbackIntegrityPreserved){
        $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_ROLLED_BACK'
      }else{
        $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_ROLLBACK_FAILED'
      }
    }catch{
      $result.rollbackHealthy=$false
      $result.rollbackError=$_.Exception.Message
      $result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_ROLLBACK_FAILED'
    }
  }else{
    if($result.classification -eq 'STARTING'){$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_FAILED_PREMUTATION'}
    if($serviceWasStopped -and -not $mutationStarted){
      try{
        $restoreHealth=Start-BlogRuntime
        $result.premutationServiceRestore=$restoreHealth
      }catch{}
    }
  }

  $result.productionDatabaseModified=$false
  $result.environmentModified=$false
  $result.schemaMigrationExecuted=$false
  $result.websitePublished=$false
  $result.time=(Get-Date -Format o)
  if($statePath){
    Save-Result $result $statePath
  }else{
    Write-Output ($result|ConvertTo-Json -Depth 24 -Compress)
  }
  exit 20
}finally{
  if($lockStream){
    try{$lockStream.Dispose()}catch{}
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
}
