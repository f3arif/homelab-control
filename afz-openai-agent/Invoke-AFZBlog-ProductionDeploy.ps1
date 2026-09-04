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
$externalDb='C:\AFZ\Runtime\AFZ-Blog\data\afz-blog.db'
$externalizeState='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-db-externalize\latest.json'
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
  $Object.time=(Get-Date -Format o)
  $json=$Object|ConvertTo-Json -Depth 30
  if($StatePath){[IO.File]::WriteAllText($StatePath,$json,$utf8)}
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($Object|ConvertTo-Json -Depth 30 -Compress)
}
function Read-Json([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  try{return [IO.File]::ReadAllText($Path)|ConvertFrom-Json}catch{return $null}
}
function Run-Git([string[]]$ArgumentVector,[switch]$AllowFailure){
  $git=Get-Command git.exe -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($git.Path){[string]$git.Path}else{[string]$git.Source})
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$lines=@(& $exe @ArgumentVector 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw ('git failed exit='+$code+' args='+($ArgumentVector -join ' ')+' tail='+(($lines|Select-Object -Last 6)-join ' | '))}
  [pscustomobject]@{exit=[int]$code;lines=$lines;text=($lines-join [Environment]::NewLine)}
}
function Run-Npm([string[]]$ArgumentVector,[string]$LogPath){
  $npm=Get-Command npm.cmd -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($npm.Path){[string]$npm.Path}else{[string]$npm.Source})
  $out=Join-Path $env:TEMP ('afz-blog-npm-'+[guid]::NewGuid().ToString('n')+'.out')
  $err=Join-Path $env:TEMP ('afz-blog-npm-'+[guid]::NewGuid().ToString('n')+'.err')
  try{
    $p=Start-Process -FilePath $exe -ArgumentList $ArgumentVector -WorkingDirectory $expectedRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    if(-not $p.WaitForExit(240000)){try{$p.Kill()}catch{};throw ('npm timed out: '+($ArgumentVector -join ' '))}
    $stdout=$(if(Test-Path -LiteralPath $out){[IO.File]::ReadAllText($out)}else{''})
    $stderr=$(if(Test-Path -LiteralPath $err){[IO.File]::ReadAllText($err)}else{''})
    $combined=$stdout
    if(-not [string]::IsNullOrWhiteSpace($stderr)){$combined=$combined+[Environment]::NewLine+'--- STDERR ---'+[Environment]::NewLine+$stderr}
    [IO.File]::WriteAllText($LogPath,$combined,$utf8)
    if([int]$p.ExitCode -ne 0){throw ('npm exit='+$p.ExitCode+' args='+($ArgumentVector -join ' ')+' log='+$LogPath)}
    [int]$p.ExitCode
  }finally{Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue}
}
function Hash-IfPresent([string]$Path){
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Git-Snapshot{
  [ordered]@{
    head=(Run-Git @('-C',$expectedRoot,'rev-parse','HEAD')).text.Trim().ToLowerInvariant()
    branch=(Run-Git @('-C',$expectedRoot,'branch','--show-current')).text.Trim()
    origin=(Run-Git @('-C',$expectedRoot,'remote','get-url','origin')).text.Trim()
    dirtyCount=@((Run-Git @('-C',$expectedRoot,'status','--porcelain=v1','-uall')).lines|Where-Object{$_}).Count
  }
}
function Get-ListenerPids{
  try{return @(Get-NetTCPConnection -LocalPort 3015 -State Listen -ErrorAction SilentlyContinue|Select-Object -ExpandProperty OwningProcess -Unique|ForEach-Object{[int]$_})}catch{return @()}
}
function Stop-BlogRuntime{
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if($task -and [string]$task.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue}
  foreach($pidValue in @(Get-ListenerPids)){Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue}
  for($i=0;$i -lt 20;$i++){if(@(Get-ListenerPids).Count -eq 0){return};Start-Sleep -Milliseconds 500}
  throw 'Port 3015 remained in LISTEN state after bounded stop.'
}
function Start-BlogRuntime{
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $httpStatus=$null;$httpError=$null;$listenerPid=$null
  for($i=0;$i -lt 60;$i++){
    $pids=@(Get-ListenerPids)
    if($pids.Count -gt 0){
      $listenerPid=[int]$pids[0]
      try{$w=Invoke-WebRequest -Uri 'http://127.0.0.1:3015/' -UseBasicParsing -TimeoutSec 5;$httpStatus=[int]$w.StatusCode;if($httpStatus -ge 200 -and $httpStatus -lt 500){return [ordered]@{ok=$true;listenerPid=$listenerPid;httpStatus=$httpStatus;httpError=$null}}}catch{$httpError=$_.Exception.Message}
    }
    Start-Sleep -Seconds 1
  }
  [ordered]@{ok=$false;listenerPid=$listenerPid;httpStatus=$httpStatus;httpError=$httpError}
}
function Invoke-NodeJson([string]$Script,[string[]]$Arguments){
  $node=Get-Command node.exe -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($node.Path){[string]$node.Path}else{[string]$node.Source})
  $tmp=Join-Path $env:TEMP ('afz-blog-external-db-'+[guid]::NewGuid().ToString('n')+'.cjs')
  try{
    [IO.File]::WriteAllText($tmp,$Script,$utf8)
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$lines=@(& $exe $tmp @Arguments 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$old}
    $jsonLine=@($lines|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    if(-not $jsonLine){throw ('Node helper returned no JSON. exit='+$code+' tail='+(($lines|Select-Object -Last 4)-join ' | '))}
    $parsed=$jsonLine|ConvertFrom-Json
    if($code -ne 0){throw ('Node helper failed exit='+$code+' classification='+[string]$parsed.classification)}
    $parsed
  }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Get-DatabaseClassification{
  $script=@'
const path=require('path');
const root=process.argv[2];
const envmod=require(path.join(root,'node_modules','@next','env'));
envmod.loadEnvConfig(root,false,{info(){},error(){}},true);
const configured=!!String(process.env.DATABASE_URL||'').trim();
const value=configured?String(process.env.DATABASE_URL).trim():'file:./data/afz-blog.db';
let backend='other',resolvedPath=null,insideGitRoot=null;
if(value.toLowerCase().startsWith('file:')){
 backend='sqlite-file';let p=value.slice(5).trim().replace(/^['"]|['"]$/g,'');
 if(/^\/[A-Za-z]:[\\/]/.test(p))p=p.slice(1);p=p.replace(/\//g,'\\');
 resolvedPath=path.win32.isAbsolute(p)?path.win32.normalize(p):path.win32.resolve(root,p);
 const nr=path.win32.resolve(root).toLowerCase(),np=path.win32.resolve(resolvedPath).toLowerCase();
 insideGitRoot=(np===nr||np.startsWith(nr+'\\'));
}
console.log(JSON.stringify({ok:true,configured,backend,resolvedPath,insideGitRoot}));
'@
  Invoke-NodeJson $script @($expectedRoot)
}
function Get-SqliteFingerprint([string]$Path){
  $script=@'
const path=require('path'),crypto=require('crypto');
const root=process.argv[2],file=process.argv[3];
const Database=require(path.join(root,'node_modules','better-sqlite3'));
const repl=(k,v)=>typeof v==='bigint'?'__bigint:'+v.toString():Buffer.isBuffer(v)?'__buffer:'+v.toString('base64'):v;
const db=new Database(file,{readonly:true,fileMustExist:true});
try{
 const integrity=String(db.pragma('integrity_check',{simple:true}));
 const tables=db.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
 const h=crypto.createHash('sha256');const counts={};
 for(const t of tables){
  h.update(String(t.name)+'\n'+String(t.sql||'')+'\n');const q='"'+String(t.name).replace(/"/g,'""')+'"';let rows;
  try{rows=db.prepare('SELECT * FROM '+q+' ORDER BY rowid').all()}catch{rows=db.prepare('SELECT * FROM '+q).all()}
  counts[t.name]=rows.length;for(const row of rows)h.update(JSON.stringify(row,repl)+'\n');
 }
 console.log(JSON.stringify({ok:integrity==='ok',integrity,fingerprint:h.digest('hex'),tableCounts:counts}));
}finally{db.close()}
'@
  Invoke-NodeJson $script @($expectedRoot,$Path)
}
function Backup-ExternalDatabase([string]$Source,[string]$Destination){
  $script=@'
const path=require('path'),fs=require('fs');
const root=process.argv[2],src=process.argv[3],dst=process.argv[4];
const Database=require(path.join(root,'node_modules','better-sqlite3'));
(async()=>{fs.mkdirSync(path.dirname(dst),{recursive:true});const db=new Database(src,{readonly:true,fileMustExist:true});try{await db.backup(dst)}finally{db.close()}console.log(JSON.stringify({ok:true,classification:'EXTERNAL_SQLITE_BACKUP_CREATED'}));})().catch(e=>{console.log(JSON.stringify({ok:false,classification:'EXTERNAL_SQLITE_BACKUP_FAILED',error:String(e&&e.message||e)}));process.exit(42)});
'@
  Invoke-NodeJson $script @($expectedRoot,$Source,$Destination)
}
function Assert-ExternalDatabase([string]$Stage){
  $c=Get-DatabaseClassification
  if(-not [bool]$c.configured -or [string]$c.backend -ne 'sqlite-file' -or [bool]$c.insideGitRoot -or [string]$c.resolvedPath -ine $externalDb){
    throw ($Stage+': live DATABASE_URL is not the canonical external SQLite path.')
  }
  if(-not(Test-Path -LiteralPath $externalDb -PathType Leaf)){throw ($Stage+': canonical external SQLite file is missing.')}
  $p=Get-SqliteFingerprint $externalDb
  if(-not [bool]$p.ok -or [string]$p.integrity -ne 'ok'){throw ($Stage+': external SQLite integrity check failed.')}
  [ordered]@{classification=$c;proof=$p}
}

$result=[ordered]@{
  schema=2;purpose='AFZ_BLOG_PRODUCTION_DEPLOY_EXTERNAL_DB';ok=$false;classification='STARTING';host=$env:COMPUTERNAME;
  productionRoot=$expectedRoot;externalDatabase=$externalDb;productionModified=$false;productionDatabaseModified=$false;
  environmentModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;
  schemaMigrationExecuted=$false;rollbackAttempted=$false;rollbackHealthy=$null;time=(Get-Date -Format o)
}
$request=$null;$statePath=$null;$lockPath=$null;$lockStream=$null;$beforeHead=$null;$mutationStarted=$false;$serviceWasStopped=$false;$dependencyRefreshNeeded=$false;$backupPath=$null;$externalBefore=$null;$envBefore=$null;$envLocalBefore=$null
try{
  if($env:COMPUTERNAME -ne $expectedHost){throw ('Wrong host: '+$env:COMPUTERNAME)}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$result.identity=[string]$identity.Name
  if([string]$identity.User.Value -ne 'S-1-5-18'){throw ('Deployment helper requires SYSTEM. Actual: '+$identity.Name)}
  if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw ('Request missing: '+$RequestPath)}
  $request=Read-Json $RequestPath;if(-not $request){throw 'Request JSON unreadable.'}
  $id=([string]$request.id).Trim();if($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,120}$'){throw 'Invalid request id.'}
  $statePath=Join-Path $stateRoot ($id+'.json');$lockPath=Join-Path $stateRoot ($id+'.lock');$result.requestId=$id

  if([string]$request.status -eq 'HOLD'){$result.ok=$true;$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_HELD';Save-Result $result $statePath;exit 0}
  if([int]$request.schema -ne 2 -or [string]$request.status -ne 'ACTIVE' -or [string]$request.action -ne 'deploy-validated-main-external-db'){throw 'Request is not an active external-db deploy request.'}
  if([string]$request.target -ne 'windows-main' -or [string]$request.host -ne $expectedHost -or [string]$request.production_root -ne $expectedRoot){throw 'Request target mismatch.'}
  if(-not [bool]$request.require_clean -or -not [bool]$request.require_fast_forward -or -not [bool]$request.allow_build -or -not [bool]$request.allow_service_restart -or [bool]$request.allow_database_mutation -or [bool]$request.allow_schema_or_migration_change -or [bool]$request.allow_website_publish -or -not [bool]$request.rollback_on_failure -or -not [bool]$request.require_external_database_verified -or -not [bool]$request.require_checkout_runtime_database_absent){throw 'Request safety policy mismatch.'}
  $expectedCurrent=([string]$request.expected_current_sha).Trim().ToLowerInvariant();$expectedSha=([string]$request.expected_blog_sha).Trim().ToLowerInvariant()
  if($expectedCurrent -notmatch '^[0-9a-f]{40}$' -or $expectedSha -notmatch '^[0-9a-f]{40}$'){throw 'Request SHA is invalid.'}
  $result.expectedCurrentSha=$expectedCurrent;$result.expectedBlogSha=$expectedSha

  $prior=Read-Json $statePath
  if($prior -and [string]$prior.classification -in @('AFZ_BLOG_PRODUCTION_DEPLOY_COMPLETED','AFZ_BLOG_PRODUCTION_DEPLOY_ALREADY_CURRENT')){Write-Output ($prior|ConvertTo-Json -Depth 30 -Compress);exit 0}
  try{$lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch{throw 'Deployment request is already in flight.'}

  if(-not(Test-Path -LiteralPath $expectedRoot -PathType Container) -or -not(Test-Path -LiteralPath (Join-Path $expectedRoot '.git') -PathType Container)){throw 'Production Git checkout missing.'}
  $before=Git-Snapshot;$beforeHead=[string]$before.head;$result.before=[ordered]@{git=$before;listenerPids=@(Get-ListenerPids)}
  if([string]$before.branch -ne 'main' -or ([string]$before.origin).TrimEnd('/').ToLowerInvariant() -ne 'https://github.com/f3arif/afz-blog.git' -or [int]$before.dirtyCount -ne 0){throw 'Production Git state is not canonical and clean.'}

  $extState=Read-Json $externalizeState
  if(-not $extState -or -not [bool]$extState.ok -or [string]$extState.classification -ne 'AFZ_BLOG_DATABASE_EXTERNALIZED_VERIFIED'){throw 'Verified database externalization state is missing.'}
  $result.externalizationState=[ordered]@{ok=[bool]$extState.ok;classification=[string]$extState.classification;time=$(if($extState.PSObject.Properties.Name -contains 'time'){[string]$extState.time}else{$null})}
  $externalLive=Assert-ExternalDatabase 'preflight';$result.externalBefore=$externalLive

  if($beforeHead -eq $expectedSha){
    if(Test-Path -LiteralPath (Join-Path $expectedRoot 'data\afz-blog.db') -PathType Leaf){throw 'Production source is current but a checkout runtime DB still exists.'}
    $health=Start-BlogRuntime;if(-not [bool]$health.ok){throw 'Production is current but health failed.'}
    $result.ok=$true;$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_ALREADY_CURRENT';$result.health=$health;Save-Result $result $statePath;exit 0
  }
  if($beforeHead -ne $expectedCurrent){throw ('Unexpected current production SHA: '+$beforeHead+' expected='+$expectedCurrent)}

  $oldGcm=$env:GCM_INTERACTIVE;$oldPrompt=$env:GIT_TERMINAL_PROMPT
  try{$env:GCM_INTERACTIVE='Never';$env:GIT_TERMINAL_PROMPT='0';$fetch=Run-Git @('-C',$expectedRoot,'fetch','--prune','origin','main') -AllowFailure}
  finally{$env:GCM_INTERACTIVE=$oldGcm;$env:GIT_TERMINAL_PROMPT=$oldPrompt}
  if([int]$fetch.exit -ne 0){throw ('Production Git fetch failed: '+(($fetch.lines|Select-Object -Last 6)-join ' | '))}
  $remoteSha=(Run-Git @('-C',$expectedRoot,'rev-parse','origin/main')).text.Trim().ToLowerInvariant();$result.remoteSha=$remoteSha
  if($remoteSha -ne $expectedSha){throw ('Remote SHA mismatch: '+$remoteSha+' expected='+$expectedSha)}
  $ancestor=Run-Git @('-C',$expectedRoot,'merge-base','--is-ancestor',$beforeHead,$expectedSha) -AllowFailure;if([int]$ancestor.exit -ne 0){throw 'Production source is not an ancestor of requested main.'}

  $nameStatus=@((Run-Git @('-C',$expectedRoot,'diff','--name-status',$beforeHead,$expectedSha)).lines|Where-Object{$_});$result.changedNameStatus=$nameStatus
  $blocked=@()
  foreach($line in $nameStatus){
    $parts=$line -split "`t";$status=[string]$parts[0];$path=[string]$parts[$parts.Count-1]
    if($path -eq 'prisma/schema.prisma' -or $path -like 'prisma/migrations/*' -or $path -match '(^|/)\.env($|\.)'){$blocked+=$line;continue}
    if($path -match '(?i)[.]db(?:[-.].*)?$' -and $status -notmatch '^D'){$blocked+=$line;continue}
  }
  if($blocked.Count -gt 0){$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_BLOCKED';$result.blockedFiles=$blocked;Save-Result $result $statePath;exit 40}
  $primaryDelete=@($nameStatus|Where-Object{$_ -match '^D\s+data/afz-blog[.]db$'})
  if($primaryDelete.Count -ne 1){$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_BLOCKED';$result.blockedReason='Target must delete tracked data/afz-blog.db exactly once.';Save-Result $result $statePath;exit 40}
  $targetGitIgnore=(Run-Git @('-C',$expectedRoot,'show',($expectedSha+':.gitignore'))).text
  if($targetGitIgnore -notmatch '(?m)^\*\.db\s*$'){throw 'Target does not ignore *.db.'}
  $dependencyRefreshNeeded=(@($nameStatus|Where-Object{$_ -match "\t(package.json|package-lock.json)$"}).Count -gt 0);$result.dependencyRefreshNeeded=$dependencyRefreshNeeded

  $envPath=Join-Path $expectedRoot '.env';$envLocalPath=Join-Path $expectedRoot '.env.local';$envBefore=Hash-IfPresent $envPath;$envLocalBefore=Hash-IfPresent $envLocalPath
  Stop-BlogRuntime;$serviceWasStopped=$true
  $externalBefore=Assert-ExternalDatabase 'quiesced';$result.externalQuiesced=$externalBefore
  $backupDir=Join-Path $runtimeRoot ('deploy-backups-external\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$expectedSha.Substring(0,8));New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
  $backupPath=Join-Path $backupDir 'afz-blog.db';$backupResult=Backup-ExternalDatabase $externalDb $backupPath;$result.databaseBackup=[ordered]@{ok=[bool]$backupResult.ok;path=$backupPath;outsideGitRoot=$true}
  $backupProof=Get-SqliteFingerprint $backupPath
  if(-not [bool]$backupProof.ok -or [string]$backupProof.fingerprint -ne [string]$externalBefore.proof.fingerprint){throw 'External DB backup fingerprint mismatch.'}

  $merge=Run-Git @('-C',$expectedRoot,'merge','--ff-only','origin/main') -AllowFailure;if([int]$merge.exit -ne 0){throw ('Fast-forward merge failed: '+(($merge.lines|Select-Object -Last 6)-join ' | '))}
  $mutationStarted=$true;$result.productionModified=$true
  $afterMerge=Git-Snapshot
  if([string]$afterMerge.head -ne $expectedSha -or [string]$afterMerge.branch -ne 'main' -or [int]$afterMerge.dirtyCount -ne 0){throw 'Post-fast-forward Git verification failed.'}

  foreach($leaf in @('afz-blog.db','afz-blog.db-wal','afz-blog.db-shm','afz-blog.db-journal')){Remove-Item -LiteralPath (Join-Path $expectedRoot ('data\'+$leaf)) -Force -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath (Join-Path $expectedRoot 'data\afz-blog.db') -PathType Leaf){throw 'Checkout runtime database remained after target transition.'}
  $result.checkoutRuntimeDatabaseAbsent=$true

  if($dependencyRefreshNeeded){$installLog=Join-Path $runtimeRoot ('npm-ci-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log');[void](Run-Npm @('ci') $installLog);$result.installLog=$installLog}
  $buildLog=Join-Path $runtimeRoot ('build-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log');[void](Run-Npm @('run','build') $buildLog);$result.buildLog=$buildLog
  $health=Start-BlogRuntime;$serviceWasStopped=$false;$result.serviceRestarted=$true;$result.health=$health
  if(-not [bool]$health.ok){throw ('Production health failed after deploy: '+[string]$health.httpError)}
  $externalAfter=Assert-ExternalDatabase 'post-deploy';$result.externalAfter=$externalAfter
  $envAfter=Hash-IfPresent $envPath;$envLocalAfter=Hash-IfPresent $envLocalPath
  if([string]$envBefore -ne [string]$envAfter -or [string]$envLocalBefore -ne [string]$envLocalAfter){throw 'Environment file hash changed during deployment.'}
  if([string]$externalBefore.proof.fingerprint -ne [string]$externalAfter.proof.fingerprint){throw 'External database logical fingerprint changed during deployment.'}
  $final=Git-Snapshot
  if([string]$final.head -ne $expectedSha -or [int]$final.dirtyCount -ne 0 -or (Test-Path -LiteralPath (Join-Path $expectedRoot 'data\afz-blog.db') -PathType Leaf)){throw 'Final production source/runtime separation verification failed.'}

  $result.ok=$true;$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_COMPLETED';$result.after=[ordered]@{git=$final;health=$health};$result.productionDatabaseModified=$false;$result.databasePreserved=$true;$result.environmentModified=$false;$result.schemaMigrationExecuted=$false;$result.websitePublished=$false
  Save-Result $result $statePath;exit 0
}catch{
  $result.error=$_.Exception.Message
  if($mutationStarted -and $request -and [bool]$request.rollback_on_failure -and $beforeHead -match '^[0-9a-f]{40}$'){
    $result.rollbackAttempted=$true
    try{
      Stop-BlogRuntime
      [void](Run-Git @('-C',$expectedRoot,'reset','--hard',$beforeHead))
      if($dependencyRefreshNeeded){$rollbackInstallLog=Join-Path $runtimeRoot ('rollback-npm-ci-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log');[void](Run-Npm @('ci') $rollbackInstallLog);$result.rollbackInstallLog=$rollbackInstallLog}
      $rollbackBuildLog=Join-Path $runtimeRoot ('rollback-build-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log');[void](Run-Npm @('run','build') $rollbackBuildLog);$result.rollbackBuildLog=$rollbackBuildLog
      $rollbackHealth=Start-BlogRuntime;$serviceWasStopped=$false;$result.rollbackHealth=$rollbackHealth
      $rbExternal=Assert-ExternalDatabase 'rollback';$result.rollbackExternal=$rbExternal
      $rbEnv=Hash-IfPresent (Join-Path $expectedRoot '.env');$rbEnvLocal=Hash-IfPresent (Join-Path $expectedRoot '.env.local')
      $rbGit=Git-Snapshot
      $integrityPreserved=([string]$externalBefore.proof.fingerprint -eq [string]$rbExternal.proof.fingerprint -and [string]$envBefore -eq [string]$rbEnv -and [string]$envLocalBefore -eq [string]$rbEnvLocal)
      $result.rollbackIntegrityPreserved=$integrityPreserved;$result.rollbackHealthy=([bool]$rollbackHealth.ok -and [string]$rbGit.head -eq $beforeHead -and [int]$rbGit.dirtyCount -eq 0 -and $integrityPreserved)
      $result.classification=$(if($result.rollbackHealthy){'AFZ_BLOG_PRODUCTION_DEPLOY_ROLLED_BACK'}else{'AFZ_BLOG_PRODUCTION_DEPLOY_ROLLBACK_FAILED'})
    }catch{$result.rollbackHealthy=$false;$result.rollbackError=$_.Exception.Message;$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_ROLLBACK_FAILED'}
  }else{
    if($result.classification -eq 'STARTING'){$result.classification='AFZ_BLOG_PRODUCTION_DEPLOY_FAILED_PREMUTATION'}
    if($serviceWasStopped){try{$result.premutationServiceRestore=Start-BlogRuntime;$serviceWasStopped=$false}catch{}}
  }
  $result.productionDatabaseModified=$false;$result.environmentModified=$false;$result.schemaMigrationExecuted=$false;$result.websitePublished=$false
  Save-Result $result $statePath;exit 20
}finally{
  if($lockStream){try{$lockStream.Dispose()}catch{};Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue}
}
