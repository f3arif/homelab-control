#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$expectedData='C:\Users\Faiz\AppData\Local\Jellyfin'
$db=Join-Path $expectedData 'data\jellyfin.db'
$taskName='Jellyfin Server'
$backupBase='C:\AFZ\MediaCatalog\Backups'
Write-Output 'AFZ_JELLYFIN_CONTROLLED_RELOAD_V3'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'USER_LIBRARY_WRITE=false'
Write-Output 'PREFERENCE_WRITE=false'
Write-Output 'SECRET_EXPOSED=false'
$procs=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
$ff=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '^ffmpeg(\.exe)?$'})
Write-Output ('JELLYFIN_PROCESS_COUNT='+$procs.Count)
Write-Output ('FFMPEG_PROCESS_COUNT='+$ff.Count)
if($procs.Count -ne 1){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=JELLYFIN_PROCESS_COUNT_NOT_ONE';exit 0}
if($ff.Count -ne 0){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=ACTIVE_FFMPEG';exit 0}
$oldPid=[int]$procs[0].ProcessId
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $task){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=TASK_NOT_FOUND';exit 0}
$acts=@($task.Actions|ForEach-Object{(([string]$_.Execute)+' '+([string]$_.Arguments)).Trim()})
$joined=($acts -join ' | ')
Write-Output ('TASK_ACTIONS='+$joined)
$expectedArg='--datadir "'+$expectedData+'"'
$expectedArg=$expectedArg.Replace('\"','"')
if($joined -notmatch [regex]::Escape($expectedArg)){Write-Output ('EXPECTED_TASK_ARG='+$expectedArg);Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=TASK_DATADIR_MISMATCH';exit 0}
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=DB_NOT_FOUND';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=NO_PYTHON_FOR_BACKUP';exit 0}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir=Join-Path $backupBase ('JellyfinControlledReload-'+$stamp)
New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
$backupDb=Join-Path $backupDir 'jellyfin.db'
$tmpPy=Join-Path $env:TEMP ('jf-backup-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys
src=sqlite3.connect(sys.argv[1],timeout=10)
dst=sqlite3.connect(sys.argv[2])
try: src.backup(dst)
finally:
 dst.close();src.close()
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmpPy $db $backupDb}else{& $exe $tmpPy $db $backupDb}
 if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $backupDb -PathType Leaf)){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=ONLINE_BACKUP_FAILED';exit 0}
}finally{Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue}
Write-Output ('BACKUP_DB='+$backupDb)
foreach($root in @((Join-Path $expectedData 'root\default'),'C:\ProgramData\Jellyfin\Server\root\default')){
 if(Test-Path -LiteralPath $root -PathType Container){
   if($root -like 'C:\ProgramData*'){$leaf='ProgramData-root-default'}else{$leaf='LocalAppData-root-default'}
   $dest=Join-Path $backupDir $leaf
   Copy-Item -LiteralPath $root -Destination $dest -Recurse -Force
 }
}
try{$before=Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 7;Write-Output ('BEFORE_SERVER='+[string]$before.ServerName+'|version='+[string]$before.Version+'|pid='+$oldPid)}catch{Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=PUBLIC_INFO_UNHEALTHY_BEFORE';exit 0}
$dp=Get-Process -Id $oldPid -ErrorAction SilentlyContinue
if(-not $dp){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=OLD_PID_GONE_BEFORE_STOP';exit 0}
$closed=$false
try{$closed=$dp.CloseMainWindow()}catch{}
if($closed){Start-Sleep -Seconds 3}
if(Get-Process -Id $oldPid -ErrorAction SilentlyContinue){Stop-Process -Id $oldPid -ErrorAction Stop}
$deadline=(Get-Date).AddSeconds(20)
do{Start-Sleep -Milliseconds 500;$still=Get-Process -Id $oldPid -ErrorAction SilentlyContinue}while($still -and (Get-Date)-lt $deadline)
if($still){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=OLD_PID_DID_NOT_STOP';exit 0}
Write-Output ('OLD_PID_STOPPED='+$oldPid)
Start-Sleep -Seconds 2
$auto=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
if($auto.Count -gt 1){Write-Output 'RELOAD_STATUS=FAILED|reason=MULTIPLE_JELLYFIN_AFTER_STOP';exit 1}
if($auto.Count -eq 1){
 $startMode='auto-recovered'
 $newPid=[int]$auto[0].ProcessId
}else{
 $startMode='scheduled-task'
 Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
 $newPid=$null
}
Write-Output ('START_MODE='+$startMode)
$healthy=$false;$newInfo=$null
$deadline=(Get-Date).AddSeconds(45)
do{
 Start-Sleep -Seconds 1
 $np=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue|Where-Object {[int]$_.ProcessId -ne $oldPid})
 if($np.Count -gt 1){Write-Output 'RELOAD_STATUS=FAILED|reason=MULTIPLE_JELLYFIN_DURING_START';exit 1}
 if($np.Count -eq 1){$newPid=[int]$np[0].ProcessId;try{$newInfo=Invoke-RestMethod -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 3;if($newInfo){$healthy=$true}}catch{}}
}while((-not $healthy) -and (Get-Date)-lt $deadline)
if(-not $healthy){if($newPid){$pidText=[string]$newPid}else{$pidText='none'};Write-Output ('NEW_PID='+$pidText);Write-Output 'RELOAD_STATUS=FAILED|reason=SERVER_NOT_HEALTHY_AFTER_START';exit 1}
Write-Output ('NEW_PID='+$newPid)
Write-Output ('AFTER_SERVER='+[string]$newInfo.ServerName+'|version='+[string]$newInfo.Version)
Write-Output ('PID_CHANGED='+($newPid -ne $oldPid))
if($newPid -eq $oldPid){Write-Output 'RELOAD_STATUS=FAILED|reason=PID_NOT_CHANGED';exit 1}
Write-Output 'RELOAD_STATUS=PASS'
