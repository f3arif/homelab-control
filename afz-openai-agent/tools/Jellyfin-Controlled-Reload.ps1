#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$ConfirmPreference='None'
$expectedData='C:\Users\Faiz\AppData\Local\Jellyfin'
$db=Join-Path $expectedData 'data\jellyfin.db'
$taskName='Jellyfin Server'
$backupBase='C:\AFZ\MediaCatalog\Backups'
$baseUri='http://127.0.0.1:8096'
Write-Output 'AFZ_JELLYFIN_CONTROLLED_RELOAD_V5'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'USER_LIBRARY_WRITE=false'
Write-Output 'PREFERENCE_WRITE=false'
Write-Output 'MEDIA_WRITE=false'
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
try {
    $before=Invoke-RestMethod -Uri ($baseUri+'/System/Info/Public') -TimeoutSec 7
    Write-Output ('BEFORE_SERVER='+[string]$before.ServerName+'|version='+[string]$before.Version+'|pid='+$oldPid)
} catch {
    Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=PUBLIC_INFO_UNHEALTHY_BEFORE'
    exit 0
}
$stopped=$false
$restartAttempted=$false
try {
    $dp=Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if(-not $dp){Write-Output 'RELOAD_STATUS=SAFE_STOP|reason=OLD_PID_GONE_BEFORE_STOP';exit 0}
    $closed=$false
    try{$closed=$dp.CloseMainWindow()}catch{}
    if($closed){Start-Sleep -Seconds 3}
    if(Get-Process -Id $oldPid -ErrorAction SilentlyContinue){Stop-Process -Id $oldPid -Force -Confirm:$false -ErrorAction Stop}
    $deadline=(Get-Date).AddSeconds(20)
    do{Start-Sleep -Milliseconds 500;$still=Get-Process -Id $oldPid -ErrorAction SilentlyContinue}while($still -and (Get-Date)-lt $deadline)
    if($still){throw 'OLD_PID_DID_NOT_STOP'}
    $stopped=$true
    Write-Output ('OLD_PID_STOPPED='+$oldPid)

    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir=Join-Path $backupBase ('JellyfinControlledReload-'+$stamp)
    New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
    $backupDb=Join-Path $backupDir 'jellyfin.db'
    Copy-Item -LiteralPath $db -Destination $backupDb -Force
    if(-not(Test-Path -LiteralPath $backupDb -PathType Leaf)){throw 'STOPPED_DB_BACKUP_FAILED'}
    Write-Output ('BACKUP_DB='+$backupDb)
    foreach($root in @((Join-Path $expectedData 'root\default'),'C:\ProgramData\Jellyfin\Server\root\default')){
        if(Test-Path -LiteralPath $root -PathType Container){
            if($root -like 'C:\ProgramData*'){$leaf='ProgramData-root-default'}else{$leaf='LocalAppData-root-default'}
            Copy-Item -LiteralPath $root -Destination (Join-Path $backupDir $leaf) -Recurse -Force
        }
    }

    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $restartAttempted=$true
    $newPid=$null;$healthy=$false;$newInfo=$null
    $deadline=(Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 1
        $np=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue|Where-Object {[int]$_.ProcessId -ne $oldPid})
        if($np.Count -gt 1){throw 'MULTIPLE_JELLYFIN_DURING_START'}
        if($np.Count -eq 1){
            $newPid=[int]$np[0].ProcessId
            try{$newInfo=Invoke-RestMethod -Uri ($baseUri+'/System/Info/Public') -TimeoutSec 3;if($newInfo){$healthy=$true}}catch{}
        }
    } while((-not $healthy) -and (Get-Date)-lt $deadline)
    if(-not $healthy){throw 'SERVER_NOT_HEALTHY_AFTER_START'}
    if($newPid -eq $oldPid){throw 'PID_NOT_CHANGED'}
    Write-Output ('NEW_PID='+$newPid)
    Write-Output ('AFTER_SERVER='+[string]$newInfo.ServerName+'|version='+[string]$newInfo.Version)
    Write-Output 'PID_CHANGED=true'
    Write-Output 'RELOAD_STATUS=PASS'
    exit 0
} catch {
    Write-Output ('RELOAD_ERROR='+$_.Exception.Message)
    throw
} finally {
    if($stopped){
        $running=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
        if($running.Count -eq 0){
            try {
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                $restartAttempted=$true
                Write-Output 'FINALLY_RECOVERY_START=REQUESTED'
            } catch {
                Write-Output ('FINALLY_RECOVERY_START=FAILED|'+$_.Exception.Message)
            }
        }
    }
    Write-Output ('RESTART_ATTEMPTED='+$restartAttempted)
}
