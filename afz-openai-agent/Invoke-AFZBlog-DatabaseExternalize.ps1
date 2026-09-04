#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallRoot='C:\AFZ\homelab-control',
  [string]$RequestPath=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

$expectedHost='DESKTOP-10SKF0M'
$productionRoot='C:\docker\afz-blog-manager'
$sourceDb=Join-Path $productionRoot 'data\afz-blog.db'
$runtimeRoot='C:\AFZ\Runtime\AFZ-Blog'
$externalDb=Join-Path $runtimeRoot 'data\afz-blog.db'
$envLocal=Join-Path $productionRoot '.env.local'
$taskName='AFZ Blog Manager'
$startScript=Join-Path $productionRoot 'scripts\start-blog-manager-3015.ps1'
$appPrisma=Join-Path $productionRoot 'src\lib\prisma.ts'
$stateRoot='C:\ProgramData\AFZ\OpenAIAgent\jobs\afz-blog-db-externalize'
$mirrorRoot='C:\Users\Faiz\OneDrive - AFZ Engineering Inc\AFZ Shared\AFZ Workers\Results'
$mirrorPath=Join-Path $mirrorRoot 'AFZ-BLOG-DATABASE-EXTERNALIZE-LATEST.txt'
$utf8=New-Object Text.UTF8Encoding($false)

if([string]::IsNullOrWhiteSpace($RequestPath)){
  $RequestPath=Join-Path $InstallRoot 'afz-openai-agent\requests\afz-blog-database-externalize.json'
}
New-Item -ItemType Directory -Force -Path $stateRoot,$runtimeRoot | Out-Null

function Save-Result($Object,[string]$StatePath){
  $Object.time=(Get-Date -Format o)
  $json=$Object|ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($StatePath,$json,$utf8)
  try{if(Test-Path -LiteralPath $mirrorRoot -PathType Container){[IO.File]::WriteAllText($mirrorPath,$json,$utf8)}}catch{}
  Write-Output ($Object|ConvertTo-Json -Depth 30 -Compress)
}
function Run-Git([string[]]$ArgumentVector,[switch]$AllowFailure){
  $git=Get-Command git.exe -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($git.Path){[string]$git.Path}else{[string]$git.Source})
  $old=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$lines=@(& $exe @ArgumentVector 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$old}
  if(-not $AllowFailure -and $code -ne 0){throw ('git failed exit='+$code+' args='+($ArgumentVector -join ' ')+' tail='+(($lines|Select-Object -Last 5)-join ' | '))}
  [pscustomobject]@{exit=[int]$code;lines=$lines;text=($lines-join [Environment]::NewLine)}
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
function Get-TaskProof{
  $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if(-not $task){return [ordered]@{valid=$false;exists=$false}}
  $actions=@($task.Actions)
  $execute=$(if($actions.Count -eq 1){[string]$actions[0].Execute}else{$null})
  $arguments=$(if($actions.Count -eq 1){[string]$actions[0].Arguments}else{$null})
  $workingDirectory=$(if($actions.Count -eq 1){[string]$actions[0].WorkingDirectory}else{$null})
  $actionOk=($actions.Count -eq 1 -and ([IO.Path]::GetFileName($execute)) -ieq 'powershell.exe' -and $arguments -like ('*'+$startScript+'*') -and $workingDirectory -eq $productionRoot)
  $principalOk=([string]$task.Principal.UserId -in @('SYSTEM','NT AUTHORITY\SYSTEM') -and [string]$task.Principal.LogonType -eq 'ServiceAccount')
  [ordered]@{valid=($actionOk -and $principalOk);exists=$true;actionOk=$actionOk;principalOk=$principalOk;state=[string]$task.State}
}
function Invoke-NodeJson([string]$Script,[string[]]$Arguments){
  $node=Get-Command node.exe -ErrorAction Stop|Select-Object -First 1
  $exe=$(if($node.Path){[string]$node.Path}else{[string]$node.Source})
  $tmp=Join-Path $env:TEMP ('afz-blog-db-'+[guid]::NewGuid().ToString('n')+'.cjs')
  try{
    [IO.File]::WriteAllText($tmp,$Script,$utf8)
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$lines=@(& $exe $tmp @Arguments 2>&1|ForEach-Object{[string]$_});$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$old}
    $jsonLine=@($lines|Where-Object{$_ -match '^\{.*\}$'}|Select-Object -Last 1)
    if(-not $jsonLine){throw ('Node helper returned no JSON. exit='+$code+' tail='+(($lines|Select-Object -Last 4)-join ' | '))}
    $parsed=$jsonLine|ConvertFrom-Json
    if($code -ne 0){throw ('Node helper failed exit='+$code+' classification='+[string]$parsed.classification)}
    return $parsed
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
  backend='sqlite-file';
  let p=value.slice(5).trim().replace(/^['"]|['"]$/g,'');
  if(/^\/[A-Za-z]:[\\/]/.test(p))p=p.slice(1);
  p=p.replace(/\//g,'\\');
  resolvedPath=path.win32.isAbsolute(p)?path.win32.normalize(p):path.win32.resolve(root,p);
  const nr=path.win32.resolve(root).toLowerCase();
  const np=path.win32.resolve(resolvedPath).toLowerCase();
  insideGitRoot=(np===nr||np.startsWith(nr+'\\'));
}
console.log(JSON.stringify({ok:true,configured,backend,resolvedPath,insideGitRoot}));
'@
  Invoke-NodeJson $script @($productionRoot)
}
function Backup-And-Fingerprint([string]$Source,[string]$Destination){
  $script=@'
const fs=require('fs');const path=require('path');const crypto=require('crypto');
const root=process.argv[2],src=process.argv[3],dst=process.argv[4];
const Database=require(path.join(root,'node_modules','better-sqlite3'));
const repl=(k,v)=>typeof v==='bigint'?'__bigint:'+v.toString():Buffer.isBuffer(v)?'__buffer:'+v.toString('base64'):v;
function inspect(file){
 const db=new Database(file,{readonly:true,fileMustExist:true});
 try{
  const integrity=String(db.pragma('integrity_check',{simple:true}));
  const tables=db.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
  const h=crypto.createHash('sha256');const counts={};
  for(const t of tables){h.update(String(t.name)+'\n'+String(t.sql||'')+'\n');const q='"'+String(t.name).replace(/"/g,'""')+'"';let rows;try{rows=db.prepare('SELECT * FROM '+q+' ORDER BY rowid').all()}catch{rows=db.prepare('SELECT * FROM '+q).all()}counts[t.name]=rows.length;for(const row of rows)h.update(JSON.stringify(row,repl)+'\n')}
  return {integrity,fingerprint:h.digest('hex'),tableCounts:counts};
 }finally{db.close()}
}
(async()=>{
 const source=inspect(src);let created=false;
 if(fs.existsSync(dst)){const existing=inspect(dst);if(existing.integrity!=='ok'||existing.fingerprint!==source.fingerprint){console.log(JSON.stringify({ok:false,classification:'DESTINATION_EXISTS_DIFFERENT',source,destination:existing}));process.exit(43)}}
 else{fs.mkdirSync(path.dirname(dst),{recursive:true});const db=new Database(src,{readonly:true,fileMustExist:true});try{await db.backup(dst)}finally{db.close()}created=true}
 const destination=inspect(dst);const ok=source.integrity==='ok'&&destination.integrity==='ok'&&source.fingerprint===destination.fingerprint;
 console.log(JSON.stringify({ok,classification:ok?'SQLITE_BACKUP_VERIFIED':'SQLITE_BACKUP_VERIFY_FAILED',created,source,destination}));process.exit(ok?0:44);
})().catch(e=>{console.log(JSON.stringify({ok:false,classification:'SQLITE_BACKUP_EXCEPTION',error:String(e&&e.message||e)}));process.exit(45)});
'@
  Invoke-NodeJson $script @($productionRoot,$Source,$Destination)
}
function Set-ExternalDatabaseEnv{
  $line='DATABASE_URL="file:C:/AFZ/Runtime/AFZ-Blog/data/afz-blog.db"'
  $raw=$(if(Test-Path -LiteralPath $envLocal -PathType Leaf){[IO.File]::ReadAllText($envLocal)}else{''})
  $pattern='^[ \t]*DATABASE_URL[ \t]*=.*$'
  $rx=New-Object Text.RegularExpressions.Regex($pattern,([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Multiline))
  $matches=$rx.Matches($raw)
  if($matches.Count -gt 1){throw 'More than one DATABASE_URL assignment exists in .env.local; refusing ambiguous edit.'}
  if($matches.Count -eq 1){$next=$rx.Replace($raw,$line,1)}
  else{$sep=$(if([string]::IsNullOrEmpty($raw)){''}elseif($raw.EndsWith("`n")){''}else{"`r`n"});$next=$raw+$sep+$line+"`r`n"}
  [IO.File]::WriteAllText($envLocal,$next,$utf8)
}

$result=[ordered]@{schema=1;purpose='AFZ_BLOG_DATABASE_EXTERNALIZE';ok=$false;classification='STARTING';host=$env:COMPUTERNAME;productionRoot=$productionRoot;sourceDatabase=$sourceDb;externalDatabase=$externalDb;productionConfigurationModified=$false;databaseContentModified=$false;gitModified=$false;serviceRestarted=$false;websitePublished=$false;credentialsEmitted=$false;rollbackAttempted=$false;rollbackHealthy=$null;time=(Get-Date -Format o)}
$statePath=Join-Path $stateRoot 'latest.json'
$envBackup=$null;$envExisted=$false;$runtimeStopped=$false;$stageDb=$null
try{
  if($env:COMPUTERNAME -ne $expectedHost){throw ('Wrong host: '+$env:COMPUTERNAME)}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$result.identity=[string]$identity.Name
  if([string]$identity.User.Value -ne 'S-1-5-18'){$result.ok=$true;$result.classification='AFZ_BLOG_DB_EXTERNALIZE_SKIPPED_NON_SYSTEM';Save-Result $result $statePath;exit 0}
  if(-not(Test-Path -LiteralPath $RequestPath -PathType Leaf)){throw ('Request missing: '+$RequestPath)}
  $request=[IO.File]::ReadAllText($RequestPath)|ConvertFrom-Json
  if([int]$request.schema -ne 1){throw 'Request schema mismatch.'}
  if([string]$request.id -ne 'afz-blog-db-externalize-v1'){throw 'Request id mismatch.'}
  if([string]$request.status -ne 'ACTIVE' -or [string]$request.action -ne 'externalize-sqlite-runtime'){throw 'Request inactive or action mismatch.'}
  if([string]$request.target -ne 'windows-main' -or [string]$request.host -ne $expectedHost){throw 'Request target mismatch.'}
  if([string]$request.production_root -ne $productionRoot -or [string]$request.source_database_path -ne $sourceDb -or [string]$request.external_database_path -ne $externalDb){throw 'Request path invariant mismatch.'}
  if([bool]$request.allow_git_mutation -or [bool]$request.allow_database_content_mutation -or -not [bool]$request.allow_environment_repoint -or -not [bool]$request.allow_service_restart -or [bool]$request.allow_website_publish -or -not [bool]$request.rollback_on_failure){throw 'Unsafe request flags.'}
  if(-not(Test-Path -LiteralPath $productionRoot -PathType Container)){throw 'Production root missing.'}
  if(-not(Test-Path -LiteralPath $appPrisma -PathType Leaf)){throw 'Prisma runtime source missing.'}
  $prismaText=[IO.File]::ReadAllText($appPrisma)
  foreach($needle in @('process.env.DATABASE_URL','file:./data/afz-blog.db','PrismaBetterSqlite3')){if(-not $prismaText.Contains($needle)){throw ('Runtime DB contract marker missing: '+$needle)}}
  $git=[ordered]@{head=(Run-Git @('-C',$productionRoot,'rev-parse','HEAD')).text.Trim().ToLowerInvariant();branch=(Run-Git @('-C',$productionRoot,'branch','--show-current')).text.Trim();origin=(Run-Git @('-C',$productionRoot,'remote','get-url','origin')).text.Trim();dirtyCount=@((Run-Git @('-C',$productionRoot,'status','--porcelain=v1','-uall')).lines|Where-Object{$_}).Count}
  $result.git=$git
  if($git.branch -ne 'main' -or $git.origin.TrimEnd('/').ToLowerInvariant() -ne 'https://github.com/f3arif/afz-blog.git' -or [int]$git.dirtyCount -ne 0){$result.classification='AFZ_BLOG_DB_EXTERNALIZE_BLOCKED_GIT_STATE';Save-Result $result $statePath;exit 40}
  $taskProof=Get-TaskProof;$result.taskProof=$taskProof
  if(-not [bool]$taskProof.valid){$result.classification='AFZ_BLOG_DB_EXTERNALIZE_BLOCKED_TASK_STATE';Save-Result $result $statePath;exit 41}
  $before=Get-DatabaseClassification;$result.before=$before
  if([string]$before.backend -ne 'sqlite-file'){throw 'Production database backend is not file SQLite.'}
  if([string]$before.resolvedPath -ieq $externalDb -and -not [bool]$before.insideGitRoot){
    if(-not(Test-Path -LiteralPath $externalDb -PathType Leaf)){throw 'Configured external database file is missing.'}
    $proof=Backup-And-Fingerprint $externalDb $externalDb
    $result.databaseProof=$proof;$result.ok=$true;$result.classification='AFZ_BLOG_DATABASE_ALREADY_EXTERNAL';Save-Result $result $statePath;exit 0
  }
  if([string]$before.resolvedPath -ine $sourceDb -or -not [bool]$before.insideGitRoot){$result.classification='AFZ_BLOG_DB_EXTERNALIZE_BLOCKED_UNEXPECTED_ACTIVE_PATH';Save-Result $result $statePath;exit 42}
  if(-not(Test-Path -LiteralPath $sourceDb -PathType Leaf)){throw 'Active source SQLite database file missing.'}

  $envExisted=Test-Path -LiteralPath $envLocal -PathType Leaf
  Stop-BlogRuntime;$runtimeStopped=$true
  if(Test-Path -LiteralPath $externalDb -PathType Leaf){$backupProof=Backup-And-Fingerprint $sourceDb $externalDb}
  else{
    $externalDir=Split-Path $externalDb -Parent;New-Item -ItemType Directory -Force -Path $externalDir|Out-Null
    $stageDb=$externalDb+'.stage.'+[guid]::NewGuid().ToString('n')
    $backupProof=Backup-And-Fingerprint $sourceDb $stageDb
    Move-Item -LiteralPath $stageDb -Destination $externalDb -Force;$stageDb=$null
  }
  $result.databaseProof=$backupProof
  if(-not [bool]$backupProof.ok){throw 'External SQLite backup verification failed.'}
  $backupRoot=Join-Path $runtimeRoot 'backups';New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
  if($envExisted){$envBackup=Join-Path $backupRoot ('env.local.'+(Get-Date -Format 'yyyyMMddTHHmmss')+'.'+[guid]::NewGuid().ToString('n')+'.bak');Copy-Item -LiteralPath $envLocal -Destination $envBackup -Force}
  $result.productionConfigurationModified=$true
  Set-ExternalDatabaseEnv
  $start=Start-BlogRuntime;$runtimeStopped=$false;$result.serviceRestarted=$true;$result.start=$start
  if(-not [bool]$start.ok){throw 'Blog runtime failed health check after database externalization.'}
  $after=Get-DatabaseClassification;$result.after=$after
  if([string]$after.backend -ne 'sqlite-file' -or [string]$after.resolvedPath -ine $externalDb -or [bool]$after.insideGitRoot){throw 'Post-start DATABASE_URL did not resolve to canonical external runtime database.'}
  $postProof=Backup-And-Fingerprint $externalDb $externalDb;$result.postDatabaseProof=$postProof
  if(-not [bool]$postProof.ok){throw 'External database failed post-start integrity/fingerprint verification.'}
  if(-not(Test-Path -LiteralPath $sourceDb -PathType Leaf)){throw 'Original in-checkout database unexpectedly disappeared during externalization.'}
  $result.ok=$true;$result.classification='AFZ_BLOG_DATABASE_EXTERNALIZED_VERIFIED'
}catch{
  $result.error=$_.Exception.Message
  if($stageDb){Remove-Item -LiteralPath $stageDb -Force -ErrorAction SilentlyContinue}
  if($result.productionConfigurationModified -or $runtimeStopped){
    $result.rollbackAttempted=$true
    try{
      Stop-BlogRuntime
      if($result.productionConfigurationModified){
        if($envExisted){if(-not $envBackup -or -not(Test-Path -LiteralPath $envBackup -PathType Leaf)){throw 'Environment backup unavailable for rollback.'};Copy-Item -LiteralPath $envBackup -Destination $envLocal -Force}
        else{Remove-Item -LiteralPath $envLocal -Force -ErrorAction SilentlyContinue}
      }
      $rb=Start-BlogRuntime;$runtimeStopped=$false;$result.rollback=$rb;$result.rollbackHealthy=[bool]$rb.ok
    }catch{$result.rollbackHealthy=$false;$result.rollbackError=$_.Exception.Message}
  }
  if($result.classification -eq 'STARTING'){$result.classification='AFZ_BLOG_DATABASE_EXTERNALIZE_EXCEPTION'}
}
Save-Result $result $statePath
if(-not $result.ok){exit 20}
