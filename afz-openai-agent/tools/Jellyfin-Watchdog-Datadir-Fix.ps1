#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$path='C:\Scripts\JellyfinWatchdog.ps1'
$expectedHash='B337625BE8B8955EE500C04E9E24DD96498C3C8CF65E5B6AFE3E13AFEFBC7138'
$old='    Start-Process "C:\Program Files\Jellyfin\Server\jellyfin.exe"'
$new='    Start-Process "C:\Program Files\Jellyfin\Server\jellyfin.exe" -ArgumentList ''--datadir "C:\Users\Faiz\AppData\Local\Jellyfin"'''
Write-Output 'AFZ_JELLYFIN_WATCHDOG_DATADIR_FIX_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $path -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_MISSING';exit 2}
$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
Write-Output ('BEFORE_SHA256='+$hash)
if($hash -ne $expectedHash){Write-Output 'STATUS=SAFE_STOP|reason=WATCHDOG_HASH_MISMATCH';exit 3}
$raw=Get-Content -LiteralPath $path -Raw -ErrorAction Stop
if(([regex]::Matches($raw,[regex]::Escape($old))).Count -ne 1){Write-Output 'STATUS=SAFE_STOP|reason=START_LINE_NOT_UNIQUE';exit 4}
if($raw -match '(?i)--datadir'){Write-Output 'STATUS=SAFE_STOP|reason=DATADIR_ALREADY_PRESENT';exit 5}
$backupDir='C:\AFZ\MediaCatalog\Backups\JellyfinWatchdog'
New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
$backup=Join-Path $backupDir ('JellyfinWatchdog-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.ps1')
Copy-Item -LiteralPath $path -Destination $backup -Force
$updated=$raw.Replace($old,$new)
$tmp=Join-Path $env:TEMP ('jf-watchdog-'+[guid]::NewGuid().ToString('n')+'.ps1')
[IO.File]::WriteAllText($tmp,$updated,(New-Object Text.UTF8Encoding($false)))
try{
 $tokens=$null;$errors=$null
 [void][System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors)
 if(@($errors).Count -gt 0){Write-Output ('STATUS=SAFE_STOP|reason=PARSER_ERROR|count='+@($errors).Count);exit 6}
 Copy-Item -LiteralPath $tmp -Destination $path -Force
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
$after=Get-Content -LiteralPath $path -Raw
if($after -notmatch [regex]::Escape('--datadir "C:\Users\Faiz\AppData\Local\Jellyfin"')){Write-Output 'STATUS=FAIL|reason=VERIFY_DATADIR_MISSING';exit 7}
$afterHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
Write-Output ('BACKUP='+$backup)
Write-Output ('AFTER_SHA256='+$afterHash)
Write-Output 'DATADIR_FIXED=true'
Write-Output 'STATUS=PASS'
