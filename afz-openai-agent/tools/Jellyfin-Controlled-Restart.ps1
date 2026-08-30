#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$ExpectedServerId='5ae656ad8fc948f38e1ac1d5a6769aa5'
$TaskName='Jellyfin Server'
$Exe='C:\Program Files\Jellyfin\Server\jellyfin.exe'
$DataDir='C:\Users\Faiz\AppData\Local\Jellyfin'
$Db=Join-Path $DataDir 'data\jellyfin.db'
$BackupRoot='C:\AFZ\MediaCatalog\Backups'
function Emit([string]$s){Write-Output $s}
function Safe([object]$v){if($null -eq $v){return ''};return ([string]$v).Replace("`r",' ').Replace("`n",' ')}
function PublicInfo([int]$Timeout=8){try{return Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec $Timeout}catch{return $null}}
function JellyfinProcs{return @(Get-Process jellyfin -ErrorAction SilentlyContinue)}
Emit 'AFZ_JELLYFIN_CONTROLLED_RESTART_V1'
Emit ('TIME='+(Get-Date -Format o))
Emit 'CANONICAL_SOURCE=github'
Emit 'DB_WRITE=false'
Emit 'MEDIA_WRITE=false'
Emit 'SECRET_EXPOSED=false'
$pub=PublicInfo
if(-not $pub){Emit 'STATUS=SAFE_STOP|reason=SERVER_NOT_RESPONDING';exit 0}
if(([string]$pub.Id).ToLowerInvariant() -ne $ExpectedServerId){Emit ('STATUS=SAFE_STOP|reason=SERVER_ID_MISMATCH|actual='+(Safe $pub.Id));exit 0}
$procs=JellyfinProcs
if($procs.Count -ne 1){Emit ('STATUS=SAFE_STOP|reason=JELLYFIN_PROCESS_COUNT|count='+$procs.Count);exit 0}
$ff=@(Get-Process ffmpeg -ErrorAction SilentlyContinue)
if($ff.Count -ne 0){Emit ('STATUS=SAFE_STOP|reason=ACTIVE_FFMPEG|count='+$ff.Count);exit 0}
if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){Emit 'STATUS=SAFE_STOP|reason=EXE_MISSING';exit 0}
if(-not(Test-Path -LiteralPath $Db -PathType Leaf)){Emit 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 0}
$task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if(-not $task){Emit 'STATUS=SAFE_STOP|reason=TASK_MISSING';exit 0}
$actions=@($task.Actions)
if($actions.Count -ne 1){Emit ('STATUS=SAFE_STOP|reason=TASK_ACTION_COUNT|count='+$actions.Count);exit 0}
$a=$actions[0]
$actExe=([string]$a.Execute).Trim('"')
$actArgs=[string]$a.Arguments
if(-not $actExe.Equals($Exe,[StringComparison]::OrdinalIgnoreCase)){Emit ('STATUS=SAFE_STOP|reason=TASK_EXE_MISMATCH|actual='+(Safe $actExe));exit 0}
if($actArgs -notmatch '(?i)--datadir\s+"?C:\\Users\\Faiz\\AppData\\Local\\Jellyfin"?'){Emit ('STATUS=SAFE_STOP|reason=TASK_ARGS_MISMATCH|actual='+(Safe $actArgs));exit 0}
$old=$procs[0]
Emit ('PRECHECK|server='+$pub.ServerName+'|version='+$pub.Version+'|pid='+$old.Id+'|ffmpeg=0|taskState='+$task.State)
# Create a transaction-consistent SQLite backup before stopping Jellyfin.
$python=$null
foreach($n in @('python.exe','python','py.exe','py')){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){$python=if($c.Source){$c.Source}else{$c.Path};break}}
if(-not $python){Emit 'STATUS=SAFE_STOP|reason=NO_PYTHON_FOR_BACKUP';exit 0}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir=Join-Path $BackupRoot ('JellyfinControlledRestart-'+$stamp)
New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
$backupDb=Join-Path $backupDir 'jellyfin.db'
$tmpPy=Join-Path $env:TEMP ('jf-backup-'+[guid]::NewGuid().ToString('n')+'.py')
$py=@'
import sqlite3,sys
src,dst=sys.argv[1],sys.argv[2]
s=sqlite3.connect('file:'+src.replace('\\','/')+'?mode=ro',uri=True,timeout=10)
d=sqlite3.connect(dst)
try:
    s.backup(d)
    d.execute('pragma quick_check')
finally:
    d.close();s.close()
'@
[IO.File]::WriteAllText($tmpPy,$py,(New-Object Text.UTF8Encoding($false)))
try{
  if([IO.Path]::GetFileName($python) -match '^py(\.exe)?$'){& $python -3 $tmpPy $Db $backupDb}else{& $python $tmpPy $Db $backupDb}
  if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $backupDb -PathType Leaf)){Emit 'STATUS=SAFE_STOP|reason=BACKUP_FAILED';exit 0}
}finally{Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue}
Emit ('BACKUP|path='+$backupDb+'|bytes='+((Get-Item $backupDb).Length))
$oldPid=$old.Id
Stop-Process -Id $oldPid -ErrorAction Stop
$gone=$false
for($i=0;$i -lt 30;$i++){if(-not(Get-Process -Id $oldPid -ErrorAction SilentlyContinue)){$gone=$true;break};Start-Sleep -Milliseconds 500}
if(-not $gone){Emit 'STATUS=FAILED|reason=OLD_PROCESS_DID_NOT_EXIT';exit 1}
Emit ('STOPPED|pid='+$oldPid)
Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Emit 'START_REQUESTED|method=scheduled-task'
$newProc=$null;$newPub=$null
for($i=0;$i -lt 60;$i++){
  Start-Sleep -Seconds 1
  $ps=JellyfinProcs
  if($ps.Count -gt 0){$newProc=@($ps|Sort-Object StartTime -Descending)[0]}
  $newPub=PublicInfo 3
  if($newProc -and $newProc.Id -ne $oldPid -and $newPub -and ([string]$newPub.Id).ToLowerInvariant() -eq $ExpectedServerId){break}
}
if(-not $newProc -or $newProc.Id -eq $oldPid -or -not $newPub -or ([string]$newPub.Id).ToLowerInvariant() -ne $ExpectedServerId){
  Emit 'PRIMARY_START_VERIFY_FAILED=true'
  if(-not(JellyfinProcs)){
    $p=Start-Process -FilePath $Exe -ArgumentList @('--datadir',$DataDir) -WindowStyle Hidden -PassThru
    Emit ('FALLBACK_START_REQUESTED|pid='+$p.Id+'|method=direct-exact-datadir')
    for($i=0;$i -lt 45;$i++){Start-Sleep -Seconds 1;$newProc=@(JellyfinProcs|Sort-Object StartTime -Descending|Select-Object -First 1);$newPub=PublicInfo 3;if($newProc -and $newPub -and ([string]$newPub.Id).ToLowerInvariant() -eq $ExpectedServerId){break}}
  }
}
if(-not $newProc -or -not $newPub -or ([string]$newPub.Id).ToLowerInvariant() -ne $ExpectedServerId){Emit 'STATUS=FAILED|reason=SERVER_DID_NOT_RETURN';exit 1}
$ffAfter=@(Get-Process ffmpeg -ErrorAction SilentlyContinue)
Emit ('RETURNED|pid='+$newProc.Id+'|start='+$newProc.StartTime.ToString('o')+'|server='+$newPub.ServerName+'|version='+$newPub.Version+'|id='+$newPub.Id+'|ffmpeg='+$ffAfter.Count)
try{$lan=Invoke-RestMethod -Uri 'http://192.168.50.94:8096/System/Info/Public' -TimeoutSec 8;if(([string]$lan.Id).ToLowerInvariant() -eq $ExpectedServerId){Emit 'LAN_8096=PASS'}else{Emit 'LAN_8096=ID_MISMATCH'}}catch{Emit ('LAN_8096=FAIL|error='+(Safe $_.Exception.Message))}
Emit 'STATUS=PASS'
