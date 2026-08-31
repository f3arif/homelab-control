#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$watchdog='C:\Scripts\JellyfinWatchdog.ps1'
$exe='C:\Program Files\Jellyfin\Server\jellyfin.exe'
$data='C:\Users\Faiz\AppData\Local\Jellyfin'
$userDb=Join-Path $data 'data\jellyfin.db'
$systemData='C:\Windows\System32\config\systemprofile\AppData\Local\Jellyfin'
$systemDb=Join-Path $systemData 'data\jellyfin.db'
$expectedOldHash='B337625BE8B8955EE500C04E9E24DD96498C3C8CF65E5B6AFE3E13AFEFBC7138'
$marker='AFZ_JELLYFIN_WATCHDOG_DATADIR_V1'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinWatchdogDatadirCutover-'+$stamp)
Write-Output 'AFZ_JELLYFIN_WATCHDOG_DATADIR_CUTOVER_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'MUTATION_SCOPE=watchdog-startup-contract-and-controlled-jellyfin-cutover'

if(-not(Test-Path -LiteralPath $watchdog -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_MISSING';exit 2}
if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=JELLYFIN_EXE_MISSING';exit 2}
if(-not(Test-Path -LiteralPath $userDb -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=USER_DB_MISSING';exit 2}
$serverTask=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -eq 'Jellyfin Server'})|Select-Object -First 1
if(-not $serverTask){Write-Output 'STATUS=SAFE_STOP|reason=SERVER_TASK_MISSING';exit 2}
$serverAction=@($serverTask.Actions|ForEach-Object{([string]$_.Execute)+' '+([string]$_.Arguments)}) -join ' || '
if($serverAction -notmatch [regex]::Escape('--datadir "C:\Users\Faiz\AppData\Local\Jellyfin"')){Write-Output ('STATUS=SAFE_STOP|reason=SERVER_TASK_DATADIR_MISMATCH|action='+$serverAction);exit 2}
$watchTask=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -eq 'Jellyfin Watchdog'})|Select-Object -First 1
if(-not $watchTask){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_TASK_MISSING';exit 2}
$wasDisabled=([string]$watchTask.State -eq 'Disabled')
$ff=@(Get-Process ffmpeg -ErrorAction SilentlyContinue)
Write-Output ('FFMPEG_COUNT='+$ff.Count)
if($ff.Count -gt 0){Write-Output 'STATUS=SAFE_STOP|reason=FFMPEG_ACTIVE';exit 3}
$procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -ieq 'jellyfin.exe'})
Write-Output ('JELLYFIN_PROCESS_COUNT_BEFORE='+$procs.Count)
if($procs.Count -ne 1){Write-Output 'STATUS=SAFE_STOP|reason=JELLYFIN_PROCESS_COUNT_NOT_ONE';exit 3}
$old=$procs[0]
$oldCmd=[string]$old.CommandLine
Write-Output ('OLD_PROCESS|pid='+$old.ProcessId+'|cmd='+$oldCmd)
if($oldCmd -match '(?i)--datadir'){Write-Output 'STATUS=SAFE_STOP|reason=ALREADY_EXPLICIT_DATADIR';exit 0}

$raw=[IO.File]::ReadAllText($watchdog)
$oldHash=(Get-FileHash -LiteralPath $watchdog -Algorithm SHA256).Hash
Write-Output ('WATCHDOG_SHA256_BEFORE='+$oldHash)
if($raw -notmatch [regex]::Escape($marker)){
  if($oldHash -ne $expectedOldHash){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_HASH_CHANGED';exit 4}
  $needle='Start-Process "C:\Program Files\Jellyfin\Server\jellyfin.exe"'
  if(([regex]::Matches($raw,[regex]::Escape($needle))).Count -ne 1){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_START_ANCHOR_NOT_UNIQUE';exit 4}
}
New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
Copy-Item -LiteralPath $watchdog -Destination (Join-Path $backupDir 'JellyfinWatchdog.ps1.before') -Force
Write-Output ('BACKUP_DIR='+$backupDir)

$watchdogDisabledByUs=$false
$patched=$false
try{
  if(-not $wasDisabled){Disable-ScheduledTask -InputObject $watchTask -ErrorAction Stop|Out-Null;$watchdogDisabledByUs=$true;Write-Output 'WATCHDOG_TASK_TEMP_DISABLED=true'}
  if($raw -notmatch [regex]::Escape($marker)){
    $replacement="# $marker`r`n    Start-Process \"C:\Program Files\Jellyfin\Server\jellyfin.exe\" -ArgumentList @('--datadir','C:\Users\Faiz\AppData\Local\Jellyfin')"
    $newRaw=$raw.Replace($needle,$replacement)
    [IO.File]::WriteAllText($watchdog,$newRaw,(New-Object Text.UTF8Encoding($false)))
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($watchdog,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -ne 0){Copy-Item -LiteralPath (Join-Path $backupDir 'JellyfinWatchdog.ps1.before') -Destination $watchdog -Force;throw 'Patched watchdog parser check failed; rolled back.'}
    $verify=[IO.File]::ReadAllText($watchdog)
    if($verify -notmatch [regex]::Escape($marker) -or $verify -notmatch [regex]::Escape("--datadir','C:\Users\Faiz\AppData\Local\Jellyfin")){Copy-Item -LiteralPath (Join-Path $backupDir 'JellyfinWatchdog.ps1.before') -Destination $watchdog -Force;throw 'Patched watchdog marker/datadir verification failed; rolled back.'}
    $patched=$true
  }
  Write-Output ('WATCHDOG_PATCHED='+$patched)
  Write-Output ('WATCHDOG_SHA256_AFTER='+(Get-FileHash -LiteralPath $watchdog -Algorithm SHA256).Hash)

  Stop-Process -Id ([int]$old.ProcessId) -Force -Confirm:$false -ErrorAction Stop
  $deadline=(Get-Date).AddSeconds(30)
  do{Start-Sleep -Milliseconds 500;$left=@(Get-Process jellyfin -ErrorAction SilentlyContinue)}while($left.Count -gt 0 -and (Get-Date) -lt $deadline)
  if(@(Get-Process jellyfin -ErrorAction SilentlyContinue).Count -gt 0){throw 'Old Jellyfin process did not stop cleanly.'}
  Write-Output 'OLD_PROCESS_STOPPED=true'

  foreach($p in @($userDb,$userDb+'-wal',$userDb+'-shm')){if(Test-Path -LiteralPath $p -PathType Leaf){Copy-Item -LiteralPath $p -Destination (Join-Path $backupDir ('user-'+[IO.Path]::GetFileName($p))) -Force}}
  foreach($p in @($systemDb,$systemDb+'-wal',$systemDb+'-shm')){if(Test-Path -LiteralPath $p -PathType Leaf){Copy-Item -LiteralPath $p -Destination (Join-Path $backupDir ('systemprofile-'+[IO.Path]::GetFileName($p))) -Force}}
  $legacyHome='C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos'
  if(Test-Path -LiteralPath $legacyHome -PathType Container){Copy-Item -LiteralPath $legacyHome -Destination (Join-Path $backupDir 'Home Videos and Photos') -Recurse -Force}
  Write-Output 'STOPPED_STATE_BACKUP=PASS'

  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $watchdog
  if($LASTEXITCODE -ne 0){throw ('Patched watchdog launch failed with exit '+$LASTEXITCODE)}
  $deadline=(Get-Date).AddSeconds(90)
  $new=$null;$http=0
  do{
    Start-Sleep -Seconds 1
    $ps=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -ieq 'jellyfin.exe'})
    if($ps.Count -eq 1){$new=$ps[0]}
    try{$r=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8096/System/Info/Public' -TimeoutSec 4;$http=[int]$r.StatusCode}catch{$http=0}
  }while((($null -eq $new) -or $http -ne 200) -and (Get-Date) -lt $deadline)
  $ps=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -ieq 'jellyfin.exe'})
  if($ps.Count -ne 1){throw ('Post-cutover Jellyfin process count is '+$ps.Count)}
  $new=$ps[0];$newCmd=[string]$new.CommandLine
  Write-Output ('NEW_PROCESS|pid='+$new.ProcessId+'|cmd='+$newCmd)
  Write-Output ('HTTP_STATUS='+$http)
  if([int]$new.ProcessId -eq [int]$old.ProcessId){throw 'Jellyfin PID did not change.'}
  if($newCmd -notmatch '(?i)--datadir' -or $newCmd -notmatch [regex]::Escape('C:\Users\Faiz\AppData\Local\Jellyfin')){throw 'New Jellyfin process is not using the required datadir.'}
  if($http -ne 200){throw 'New Jellyfin did not reach HTTP 200.'}
  $log=Get-ChildItem -LiteralPath (Join-Path $data 'log') -Filter 'log_*.log' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
  if(-not $log){throw 'No user-datadir Jellyfin log found after cutover.'}
  $recent=Get-Content -LiteralPath $log.FullName -Tail 300 -ErrorAction SilentlyContinue|Where-Object {$_ -match '(?i)Program data path|Arguments:'}|Select-Object -Last 8
  foreach($l in $recent){Write-Output ('LOG_VERIFY|'+$l)}
  Write-Output 'CUTOVER_VERIFY=PASS'
  Write-Output 'STATUS=PASS'
  exit 0
}catch{
  Write-Output ('CUTOVER_ERROR='+$_.Exception.Message)
  try{
    if(@(Get-Process jellyfin -ErrorAction SilentlyContinue).Count -eq 0 -and (Test-Path -LiteralPath $watchdog -PathType Leaf)){
      & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $watchdog | Out-Null
      Write-Output 'RECOVERY_START_ATTEMPTED=true'
    }
  }catch{Write-Output ('RECOVERY_START_ERROR='+$_.Exception.Message)}
  Write-Output 'STATUS=FAIL'
  exit 5
}finally{
  if($watchdogDisabledByUs){try{Enable-ScheduledTask -InputObject $watchTask -ErrorAction Stop|Out-Null;Write-Output 'WATCHDOG_TASK_REENABLED=true'}catch{Write-Output ('WATCHDOG_REENABLE_ERROR='+$_.Exception.Message)}}
}
