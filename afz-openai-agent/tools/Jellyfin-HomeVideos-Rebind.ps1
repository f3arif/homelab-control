#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db';$base='http://127.0.0.1:8096';$name='Home Videos and Photos';$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive';$root='C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_REBIND_V1';Write-Output ('TIME='+(Get-Date -Format o));Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path $source -PathType Container)){Write-Output 'STATUS=SAFE_STOP|reason=SOURCE_MISSING';exit 2}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1);if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 2}
$t=Join-Path $env:TEMP ('jf-key-'+[guid]::NewGuid().ToString('n')+'.py');[IO.File]::WriteAllText($t,"import sqlite3,sys\nc=sqlite3.connect('file:'+sys.argv[1].replace('\\\\','/')+'?mode=ro',uri=True)\nr=c.execute(\"select AccessToken from ApiKeys where AccessToken is not null order by coalesce(DateLastActivity,DateCreated) desc limit 1\").fetchone();print('' if not r else r[0]);c.close()",(New-Object Text.UTF8Encoding($false)))
try{$e=$py.Path;if([IO.Path]::GetFileName($e)-match '^py(\.exe)?$'){$token=(& $e -3 $t $db|Out-String).Trim()}else{$token=(& $e $t $db|Out-String).Trim()}}finally{Remove-Item $t -Force -ErrorAction SilentlyContinue}
if(-not $token){Write-Output 'STATUS=SAFE_STOP|reason=NO_API_KEY';exit 2}
$h=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Repair", Device="Windows-main", DeviceId="afz-homevideos-repair", Version="1.0", Token="'+$token+'"');Accept='application/json'}
try{$before=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $h -TimeoutSec 20)}catch{Write-Output ('STATUS=SAFE_STOP|reason=AUTH_FAILED|error='+$_.Exception.Message);exit 3}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$bak='C:\AFZ\MediaCatalog\Backups\HomeVideosRebind-'+$stamp;New-Item -ItemType Directory -Force -Path $bak|Out-Null;Copy-Item $db (Join-Path $bak 'jellyfin.db') -Force;if(Test-Path $root){Copy-Item $root (Join-Path $bak 'Home Videos and Photos') -Recurse -Force};Write-Output ('BACKUP='+$bak)
$matches=@($before|Where-Object{[string]$_.Name -eq $name});$already=$false;foreach($m in $matches){if(@($m.Locations|Where-Object{[string]$_ -ieq $source}).Count){$already=$true}}
if(-not $already){$body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress;try{Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders/Paths?refreshLibrary=true') -Headers ($h+@{'Content-Type'='application/json'}) -Method Post -Body $body -TimeoutSec 60|Out-Null;Write-Output 'REBIND_POST=PASS'}catch{Write-Output ('STATUS=FAIL|reason=REBIND_POST_FAILED|error='+$_.Exception.Message);exit 4}}else{Write-Output 'REBIND_POST=SKIPPED_ALREADY_PRESENT'}
try{Invoke-RestMethod -Uri ($base+'/Library/Refresh') -Headers $h -Method Post -TimeoutSec 20|Out-Null;Write-Output 'LIBRARY_REFRESH=REQUESTED'}catch{Write-Output ('LIBRARY_REFRESH=FAILED|'+$_.Exception.Message)}
Start-Sleep -Seconds 5
$after=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $h -TimeoutSec 20);$ok=$false;foreach($m in @($after|Where-Object{[string]$_.Name -eq $name})){if(@($m.Locations|Where-Object{[string]$_ -ieq $source}).Count){$ok=$true;Write-Output ('HOME_VF|itemId='+[string]$m.ItemId+'|locations='+(@($m.Locations)-join ';'))}}
Write-Output ('REBIND_VERIFIED='+$ok);if(-not $ok){Write-Output 'STATUS=FAIL|reason=POSTVERIFY_MISSING';exit 5};Write-Output 'STATUS=PASS'
