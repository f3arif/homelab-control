#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$name='Home Videos and Photos'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$expectedServer='c3d285e9b6924aa8963af4f44b806579'
$backupDir=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinHomeVideosRebindV3-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$removed=$false;$added=$false
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_REBIND_REPAIR_V3'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'MEDIA_FILE_WRITE=false'
Write-Output 'MUTATION_SCOPE=one-existing-homevideos-media-path-remove-readd-refresh'
function Get-Python { foreach($n in @('python.exe','python','py.exe','py')){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){return $(if($c.Path){$c.Path}else{$c.Source})}};return $null }
$python=Get-Python
if(-not $python){Write-Output 'REPAIR_STATUS=SAFE_STOP|reason=NO_PYTHON';exit 2}
function Run-Python([string]$code,[string[]]$args){$tmp=Join-Path $env:TEMP ('jf-v3-'+[guid]::NewGuid().ToString('n')+'.py');[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)));try{if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){& $python -3 $tmp @args}else{& $python $tmp @args};return $LASTEXITCODE}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}}
function Read-Key {
 $o=Join-Path $env:TEMP ('jf-key-'+[guid]::NewGuid().ToString('n')+'.txt')
 $c=@'
import sqlite3,sys
p,o=sys.argv[1:3]
db=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5)
try:
 r=db.execute("select AccessToken from ApiKeys where AccessToken is not null and length(AccessToken)>0 order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
 open(o,'w',encoding='utf-8').write('' if not r else r[0])
finally:db.close()
'@
 try{$rc=Run-Python $c @($db,$o);if($rc -ne 0 -or -not(Test-Path $o)){return ''};return ([IO.File]::ReadAllText($o)).Trim()}finally{Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue}
}
function Backup-Db([string]$dest){$c=@'
import sqlite3,sys
s=sqlite3.connect(sys.argv[1],timeout=20);d=sqlite3.connect(sys.argv[2],timeout=20)
try:s.backup(d);d.commit();print('OK')
finally:d.close();s.close()
'@;$o=& { $tmp=Join-Path $env:TEMP ('jf-bak-'+[guid]::NewGuid().ToString('n')+'.py');[IO.File]::WriteAllText($tmp,$c,(New-Object Text.UTF8Encoding($false)));try{if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){$x=& $python -3 $tmp $db $dest}else{$x=& $python $tmp $db $dest};if($LASTEXITCODE -ne 0){throw 'backup python failed'};return @($x)}finally{Remove-Item $tmp -Force -ErrorAction SilentlyContinue}};return (($o -join ';') -match 'OK')}
function Get-Home($headers){$vf=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $headers -TimeoutSec 20);return @($vf|Where-Object{[string]$_.Name -eq $name})}
try{
 if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw 'SAFE_STOP: DB missing'}
 if(-not(Test-Path -LiteralPath $source -PathType Container)){throw 'SAFE_STOP: source missing'}
 $mediaCount=@(Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue|Where-Object{$_.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'}|Select-Object -First 10001).Count
 Write-Output ('SOURCE_MEDIA_COUNT_CAPPED='+$mediaCount)
 if($mediaCount -lt 1){throw 'SAFE_STOP: no source media'}
 $pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 10
 Write-Output ('PUBLIC_SERVER|name='+[string]$pub.ServerName+'|version='+[string]$pub.Version+'|id='+[string]$pub.Id)
 if(([string]$pub.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: server id mismatch'}
 $p=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'jellyfin.exe'})
 if($p.Count -ne 1){throw 'SAFE_STOP: process count mismatch'}
 $cmd=[string]$p[0].CommandLine;Write-Output ('PROCESS|pid='+$p[0].ProcessId+'|cmd='+(($cmd)-replace '\|','/'))
 if($cmd -notmatch '(?i)--datadir\s+"?C:\\Users\\Faiz\\AppData\\Local\\Jellyfin'){throw 'SAFE_STOP: datadir mismatch'}
 $token=Read-Key;if([string]::IsNullOrWhiteSpace($token)){throw 'SAFE_STOP: no API key'}
 $h=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Rebind", Device="Windows-main", DeviceId="afz-homevideos-rebind", Version="3.0", Token="'+$token+'"');Accept='application/json'}
 $si=Invoke-RestMethod -Uri ($base+'/System/Info') -Headers $h -TimeoutSec 10
 Write-Output ('API_AUTH=PASS|serverId='+[string]$si.Id)
 if(([string]$si.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: authenticated server mismatch'}
 $lib=@(Get-Home $h);if($lib.Count -ne 1){throw 'SAFE_STOP: Home Videos not unique'}
 $loc=@($lib[0].Locations|ForEach-Object{[string]$_});$pi=@();if($lib[0].LibraryOptions -and $lib[0].LibraryOptions.PathInfos){$pi=@($lib[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
 Write-Output ('PRE_LOCATION_COUNT='+$loc.Count);foreach($x in $loc){Write-Output ('PRE_LOCATION|path='+$x+'|exists='+(Test-Path -LiteralPath $x))};Write-Output ('PRE_PATHINFO_COUNT='+$pi.Count);foreach($x in $pi){Write-Output ('PRE_PATHINFO|path='+$x)}
 if($loc.Count -ne 1 -or [string]$loc[0] -ine $source){throw 'SAFE_STOP: unexpected location set'}
 if(@($pi|Where-Object{$_ -ieq $source}).Count -eq 1){Write-Output 'REPAIR_STATUS=NOOP_PATHINFO_ALREADY_CORRECT';exit 0}
 New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
 if(-not(Backup-Db (Join-Path $backupDir 'jellyfin.db'))){throw 'SAFE_STOP: DB backup failed'}
 foreach($r in @('C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos','C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos')){if(Test-Path -LiteralPath $r -PathType Container){Copy-Item -LiteralPath $r -Destination (Join-Path $backupDir ((($r -replace '[:\\ ]','_').Trim('_')))) -Recurse -Force}}
 Write-Output ('BACKUP_DIR='+$backupDir);Write-Output 'BACKUP_STATUS=PASS'
 $del=$base+'/Library/VirtualFolders/Paths?name='+[uri]::EscapeDataString($name)+'&path='+[uri]::EscapeDataString($source)+'&refreshLibrary=false'
 Invoke-WebRequest -UseBasicParsing -Uri $del -Headers $h -Method Delete -TimeoutSec 30|Out-Null;$removed=$true;Write-Output 'REMOVE_PATH=PASS'
 $body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress
 Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Library/VirtualFolders/Paths?refreshLibrary=true') -Headers $h -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null;$added=$true;Write-Output 'ADD_PATH=PASS'
 $ready=$false
 for($i=1;$i -le 30 -and -not $ready;$i++){Start-Sleep -Seconds 4;$x=@(Get-Home $h);if($x.Count -eq 1){$ll=@($x[0].Locations|ForEach-Object{[string]$_});$pp=@();if($x[0].LibraryOptions -and $x[0].LibraryOptions.PathInfos){$pp=@($x[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})};$ready=(@($ll|Where-Object{$_ -ieq $source}).Count -eq 1 -and @($pp|Where-Object{$_ -ieq $source}).Count -eq 1)}}
 Write-Output ('PATH_BINDING_READY='+$ready)
 if(-not $ready){throw 'PathInfo did not restore'}
 Write-Output 'REPAIR_STATUS=PASS_PATH_REBOUND_SCAN_RUNNING'
} catch {
 Write-Output ('REPAIR_STATUS=SAFE_STOP|error='+($_.Exception.Message -replace '\|','/'))
 if($removed -and -not $added){try{$token=Read-Key;if($token){$h=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Rebind", Device="Windows-main", DeviceId="afz-homevideos-rebind", Version="3.0", Token="'+$token+'"')};$body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress;Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Library/VirtualFolders/Paths?refreshLibrary=true') -Headers $h -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null;Write-Output 'ROLLBACK_READD=PASS'}}catch{Write-Output 'ROLLBACK_READD=FAIL'}}
 exit 1
} finally {Write-Output 'TEMP_KEY_CREATED=false';Write-Output 'SECRET_EXPOSED=false'}
