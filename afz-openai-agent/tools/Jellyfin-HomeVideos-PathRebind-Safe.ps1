#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$name='Home Videos and Photos'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$targetId='EE75511A-E395-034B-1E7E-657707B15125'
$currentVf='C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos'
$legacyVf='C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_PATH_REBIND_SAFE_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'MUTATION_SCOPE=single-homevideos-media-path-rebind-and-library-validation'

if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 2}
if(-not(Test-Path -LiteralPath $source -PathType Container)){Write-Output 'STATUS=SAFE_STOP|reason=SOURCE_MISSING';exit 2}
if(-not(Test-Path -LiteralPath $currentVf -PathType Container)){Write-Output ('CURRENT_VF_EXISTS=false|path='+$currentVf);Write-Output 'STATUS=SAFE_STOP|reason=CURRENT_VIRTUAL_FOLDER_DIR_MISSING';exit 2}
Write-Output ('CURRENT_VF_EXISTS=true|path='+$currentVf)
Write-Output ('LEGACY_VF_EXISTS='+(Test-Path -LiteralPath $legacyVf -PathType Container))
$mediaCount=0
foreach($f in Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue){if($f.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'){$mediaCount++;if($mediaCount -ge 500){break}}}
Write-Output ('SOURCE_MEDIA_COUNT_CAPPED='+$mediaCount)
if($mediaCount -lt 1){Write-Output 'STATUS=SAFE_STOP|reason=SOURCE_HAS_NO_MEDIA';exit 2}

$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 2}
$exe=$py.Path
$tmpKey=Join-Path $env:TEMP ('jf-key-'+[guid]::NewGuid().ToString('n')+'.py')
$tmpState=Join-Path $env:TEMP ('jf-state-'+[guid]::NewGuid().ToString('n')+'.py')
$keyCode=@'
import sqlite3,sys
p=sys.argv[1]
c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5)
try:
 r=c.execute("select AccessToken from ApiKeys where AccessToken is not null and length(AccessToken)>0 order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
 print('' if not r else r[0])
finally:c.close()
'@
$stateCode=@'
import sqlite3,sys,json
p=sys.argv[1]; target=sys.argv[2].lower().replace('-',''); source=sys.argv[3].lower()
c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
try:
 rows=list(c.execute('select Id,ParentId,TopParentId,Path,Data from BaseItems'))
 def n(v): return ('' if v is None else str(v)).lower().replace('-','')
 direct=sum(1 for r in rows if n(r['ParentId'])==target)
 top=sum(1 for r in rows if n(r['TopParentId'])==target)
 src=sum(1 for r in rows if source in str(r['Path'] or '').lower())
 pf=0
 for r in rows:
  if n(r['Id'])==target:
   try: pf=len(json.loads(r['Data'] or '{}').get('PhysicalFolderIds') or [])
   except: pf=-1
   break
 print('%d|%d|%d|%d'%(direct,top,src,pf))
finally:c.close()
'@
[IO.File]::WriteAllText($tmpKey,$keyCode,(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($tmpState,$stateCode,(New-Object Text.UTF8Encoding($false)))
function Run-Py([string]$script,[string[]]$args){
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){return (& $exe -3 $script @args | Out-String).Trim()}
 return (& $exe $script @args | Out-String).Trim()
}
try{$token=Run-Py $tmpKey @($db)}catch{$token=''}
if([string]::IsNullOrWhiteSpace($token)){Remove-Item $tmpKey,$tmpState -Force -ErrorAction SilentlyContinue;Write-Output 'STATUS=SAFE_STOP|reason=NO_API_KEY';exit 2}
$headers=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Repair", Device="Windows-main", DeviceId="afz-homevideos-repair", Version="1.0", Token="'+$token+'"');Accept='application/json'}
function Get-Vf(){return @(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $headers -Method Get -TimeoutSec 20)}
try{$vf=Get-Vf}catch{Remove-Item $tmpKey,$tmpState -Force -ErrorAction SilentlyContinue;Write-Output ('STATUS=SAFE_STOP|reason=API_AUTH_FAILED|error='+$_.Exception.Message);exit 3}
$match=@($vf|Where-Object {[string]$_.Name -eq $name})
Write-Output ('PRE_VIRTUAL_FOLDER_MATCH_COUNT='+$match.Count)
if($match.Count -ne 1){Remove-Item $tmpKey,$tmpState -Force -ErrorAction SilentlyContinue;Write-Output 'STATUS=SAFE_STOP|reason=LIBRARY_NOT_UNIQUE';exit 3}
$loc=@($match[0].Locations|ForEach-Object{[string]$_})
Write-Output ('PRE_LOCATION_COUNT='+$loc.Count)
Write-Output ('PRE_SOURCE_IN_LOCATIONS='+[bool](@($loc|Where-Object{$_ -ieq $source}).Count))
if(@($loc|Where-Object{$_ -ieq $source}).Count -ne 1){Remove-Item $tmpKey,$tmpState -Force -ErrorAction SilentlyContinue;Write-Output 'STATUS=SAFE_STOP|reason=EXPECTED_SOURCE_NOT_UNIQUE_IN_LOCATIONS';exit 3}
$preState=Run-Py $tmpState @($db,$targetId,$source);Write-Output ('PRE_DB_STATE='+$preState)

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir='C:\AFZ\MediaCatalog\Backups\JellyfinHomeVideosPathRebind-'+$stamp
New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
$backupPy=Join-Path $env:TEMP ('jf-backup-'+[guid]::NewGuid().ToString('n')+'.py')
$backupCode=@'
import sqlite3,sys
src=sqlite3.connect(sys.argv[1],timeout=10);dst=sqlite3.connect(sys.argv[2],timeout=10)
try: src.backup(dst)
finally: dst.close();src.close()
'@
[IO.File]::WriteAllText($backupPy,$backupCode,(New-Object Text.UTF8Encoding($false)))
$dbBackup=Join-Path $backupDir 'jellyfin.db'
try{
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $backupPy $db $dbBackup *> $null}else{& $exe $backupPy $db $dbBackup *> $null}
 if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $dbBackup -PathType Leaf)){throw 'SQLite backup failed'}
 Copy-Item -LiteralPath $currentVf -Destination (Join-Path $backupDir 'current-vf') -Recurse -Force
 if(Test-Path -LiteralPath $legacyVf -PathType Container){Copy-Item -LiteralPath $legacyVf -Destination (Join-Path $backupDir 'legacy-vf') -Recurse -Force}
 Write-Output ('BACKUP_DIR='+$backupDir)
 Write-Output 'BACKUP_STATUS=PASS'
} catch {Remove-Item $tmpKey,$tmpState,$backupPy -Force -ErrorAction SilentlyContinue;Write-Output ('STATUS=SAFE_STOP|reason=BACKUP_FAILED|error='+$_.Exception.Message);exit 4}
finally{Remove-Item $backupPy -Force -ErrorAction SilentlyContinue}

$removed=$false;$added=$false
try{
 $n=[uri]::EscapeDataString($name);$p=[uri]::EscapeDataString($source)
 $delUrl=$base+'/Library/VirtualFolders/Paths?name='+$n+'&path='+$p+'&refreshLibrary=false'
 $r=Invoke-WebRequest -UseBasicParsing -Uri $delUrl -Headers $headers -Method Delete -TimeoutSec 30
 Write-Output ('REMOVE_HTTP_STATUS='+[int]$r.StatusCode)
 if([int]$r.StatusCode -ne 204){throw 'Unexpected remove status'}
 $removed=$true
 Start-Sleep -Seconds 2
 $body=(@{Name=$name;Path=$source}|ConvertTo-Json -Compress)
 $addUrl=$base+'/Library/VirtualFolders/Paths?refreshLibrary=true'
 $r2=Invoke-WebRequest -UseBasicParsing -Uri $addUrl -Headers $headers -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
 Write-Output ('ADD_HTTP_STATUS='+[int]$r2.StatusCode)
 if([int]$r2.StatusCode -ne 204){throw 'Unexpected add status'}
 $added=$true
 Write-Output 'REBIND_SUBMITTED=true'
} catch {
 Write-Output ('REBIND_ERROR='+$_.Exception.Message)
 if($removed -and -not $added){
  try{$body=(@{Name=$name;Path=$source}|ConvertTo-Json -Compress);$rr=Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Library/VirtualFolders/Paths?refreshLibrary=false') -Headers $headers -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30;Write-Output ('ROLLBACK_ADD_HTTP_STATUS='+[int]$rr.StatusCode)}catch{Write-Output ('ROLLBACK_ADD_FAILED='+$_.Exception.Message)}
 }
 Remove-Item $tmpKey,$tmpState -Force -ErrorAction SilentlyContinue
 Write-Output 'STATUS=FAIL|reason=REBIND_FAILED'
 exit 5
}

$verified=$false
for($i=0;$i -lt 60;$i++){
 Start-Sleep -Seconds 5
 try{
  $cur=Get-Vf;$m=@($cur|Where-Object {[string]$_.Name -eq $name});$okLoc=$false;$okPi=$false
  if($m.Count -eq 1){$okLoc=@($m[0].Locations|Where-Object{[string]$_ -ieq $source}).Count -eq 1;$pis=@($m[0].LibraryOptions.PathInfos);$okPi=@($pis|Where-Object{[string]$_.Path -ieq $source}).Count -ge 1}
  $st=Run-Py $tmpState @($db,$targetId,$source)
  $parts=$st -split '\|';$direct=[int]$parts[0];$top=[int]$parts[1];$srcRows=[int]$parts[2];$pf=[int]$parts[3]
  if(($i%6)-eq 0){Write-Output ('VERIFY_PROGRESS|seconds='+(($i+1)*5)+'|location='+$okLoc+'|pathInfo='+$okPi+'|direct='+$direct+'|top='+$top+'|sourceRows='+$srcRows+'|physicalFolderIds='+$pf)}
  if($okLoc -and ($okPi -or $pf -gt 0) -and ($direct -gt 0 -or $top -gt 0 -or $srcRows -gt 0)){$verified=$true;Write-Output ('POST_DB_STATE='+$st);Write-Output ('POST_SOURCE_IN_LOCATIONS='+$okLoc);Write-Output ('POST_SOURCE_IN_PATHINFOS='+$okPi);break}
 }catch{Write-Output ('VERIFY_RETRY_ERROR='+$_.Exception.Message)}
}
Remove-Item $tmpKey,$tmpState -Force -ErrorAction SilentlyContinue
Write-Output 'SECRET_EXPOSED=false'
if($verified){Write-Output 'STATUS=PASS';exit 0}
Write-Output 'STATUS=PARTIAL|reason=REBIND_ACCEPTED_BUT_INDEX_NOT_YET_PROVEN'
exit 6
