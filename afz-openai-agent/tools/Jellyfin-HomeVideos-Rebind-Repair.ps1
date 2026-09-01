#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$name='Home Videos and Photos'
$targetId='EE75511A-E395-034B-1E7E-657707B15125'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$expectedServer='c3d285e9b6924aa8963af4f44b806579'
$vfDir='C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos'
$tempName='AFZ-Temporary-HomeVideos-Rebind'
$tempToken=[guid]::NewGuid().ToString('N')
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinHomeVideosRebind-'+$stamp)
$utf8=New-Object Text.UTF8Encoding($false)
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
$python=Find-Cmd @('python.exe','python','py.exe','py')
if(-not $python){throw 'Python is required for bounded SQLite backup/key operation.'}
function Run-Py([string]$mode,[string]$backup=''){
  $tmp=Join-Path $env:TEMP ('jf-home-rebind-'+[guid]::NewGuid().ToString('n')+'.py')
  $py=@'
import sqlite3,sys,datetime,os
p,mode,token,name,target,source,backup=sys.argv[1:8]
if mode=='backup':
 os.makedirs(os.path.dirname(backup),exist_ok=True)
 src=sqlite3.connect(p,timeout=20); dst=sqlite3.connect(backup)
 try: src.backup(dst)
 finally: dst.close(); src.close()
 print('BACKUP_OK|path='+backup)
 raise SystemExit(0)
con=sqlite3.connect(p,timeout=20)
try:
 con.execute('PRAGMA busy_timeout=20000')
 if mode=='precheck':
  r=con.execute('select Id,Name,Type,Path,Data from BaseItems where lower(replace(Id,"-",""))=lower(replace(?,"-",""))',(target,)).fetchone()
  if not r: print('TARGET_MISSING'); raise SystemExit(4)
  direct=con.execute('select count(*) from BaseItems where lower(replace(ParentId,"-",""))=lower(replace(?,"-",""))',(target,)).fetchone()[0]
  top=con.execute('select count(*) from BaseItems where lower(replace(TopParentId,"-",""))=lower(replace(?,"-",""))',(target,)).fetchone()[0]
  sourceRows=con.execute('select count(*) from BaseItems where lower(Path)=lower(?)',(source,)).fetchone()[0]
  print('PRECHECK|id=%s|name=%s|type=%s|path=%s|direct=%d|top=%d|sourceRows=%d'%(r[0],r[1],r[2],r[3],direct,top,sourceRows))
 elif mode=='insert':
  cols=[r[1] for r in con.execute('pragma table_info("ApiKeys")')]
  if not {'AccessToken','DateCreated','DateLastActivity','Name'}.issubset(set(cols)):
   print('SCHEMA_MISMATCH'); raise SystemExit(3)
  before=con.execute('select count(*) from ApiKeys').fetchone()[0]
  now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
  con.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name));con.commit()
  after=con.execute('select count(*) from ApiKeys').fetchone()[0]
  exists=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  print('INSERT|before=%d|after=%d|exists=%d'%(before,after,exists))
 elif mode=='delete':
  before=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  con.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name));con.commit()
  after=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  print('DELETE|before=%d|after=%d'%(before,after))
 elif mode=='verifykey':
  n=con.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0]
  print('VERIFY_KEY|remaining=%d'%n)
 elif mode=='verifyitems':
  direct=con.execute('select count(*) from BaseItems where lower(replace(ParentId,"-",""))=lower(replace(?,"-",""))',(target,)).fetchone()[0]
  top=con.execute('select count(*) from BaseItems where lower(replace(TopParentId,"-",""))=lower(replace(?,"-",""))',(target,)).fetchone()[0]
  sourceRows=con.execute('select count(*) from BaseItems where lower(Path)=lower(?)',(source,)).fetchone()[0]
  sourceDesc=con.execute('select count(*) from BaseItems where lower(Path) like lower(?)',(source.rstrip('\\')+'\\%',)).fetchone()[0]
  print('VERIFY_ITEMS|direct=%d|top=%d|sourceRows=%d|sourceDesc=%d'%(direct,top,sourceRows,sourceDesc))
finally: con.close()
'@
  [IO.File]::WriteAllText($tmp,$py,$utf8)
  try{
    if([IO.Path]::GetFileName($python) -match '^py(\.exe)?$'){& $python -3 $tmp $db $mode $tempToken $tempName $targetId $source $backup}else{& $python $tmp $db $mode $tempToken $tempName $targetId $source $backup}
    if($LASTEXITCODE -ne 0){throw "SQLite $mode failed with exit=$LASTEXITCODE"}
  } finally {Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function ApiUri([string]$path,[hashtable]$query=@{}){
  $parts=New-Object System.Collections.Generic.List[string]
  foreach($k in $query.Keys){$parts.Add(([uri]::EscapeDataString([string]$k))+'='+([uri]::EscapeDataString([string]$query[$k])))}
  $parts.Add('ApiKey='+([uri]::EscapeDataString($tempToken)))
  return $base+$path+'?'+($parts -join '&')
}
function Get-VirtualFolders(){@(Invoke-RestMethod -Uri (ApiUri '/Library/VirtualFolders') -Method Get -TimeoutSec 30)}
function Add-Source($pathInfo,[bool]$refresh=$true){
  $obj=[ordered]@{Name=$name}
  if($null -ne $pathInfo){$obj.PathInfo=$pathInfo}else{$obj.Path=$source}
  $body=$obj|ConvertTo-Json -Depth 20 -Compress
  Invoke-WebRequest -UseBasicParsing -Uri (ApiUri '/Library/VirtualFolders/Paths' @{refreshLibrary=([string]$refresh).ToLowerInvariant()}) -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null
}
function Remove-Source([bool]$refresh=$false){
  Invoke-WebRequest -UseBasicParsing -Uri (ApiUri '/Library/VirtualFolders/Paths' @{name=$name;path=$source;refreshLibrary=([string]$refresh).ToLowerInvariant()}) -Method Delete -TimeoutSec 60|Out-Null
}
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_REBIND_REPAIR_V3'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'MUTATION_SCOPE=homevideos-media-path-only'
$inserted=$false;$removed=$false;$added=$false;$sourcePi=$null;$repairPassed=$false
try{
  if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw 'Live Jellyfin DB missing'}
  if(-not(Test-Path -LiteralPath $source -PathType Container)){throw 'Home Videos source missing'}
  $pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 15
  Write-Output ('PUBLIC_SERVER|name='+[string]$pub.ServerName+'|version='+[string]$pub.Version+'|id='+[string]$pub.Id)
  if(([string]$pub.Id).ToLowerInvariant() -ne $expectedServer){throw 'Unexpected Jellyfin server ID'}
  $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.Name -ieq 'jellyfin.exe'})
  if($procs.Count -ne 1){throw ('Jellyfin process count='+$procs.Count)}
  $cmd=[string]$procs[0].CommandLine;Write-Output ('PROCESS|pid='+$procs[0].ProcessId+'|cmd='+(($cmd)-replace '\|','/'))
  if($cmd -notmatch '(?i)--datadir\s+"?C:\\Users\\Faiz\\AppData\\Local\\Jellyfin'){throw 'Jellyfin datadir mismatch'}
  $ff=@(Get-Process ffmpeg -ErrorAction SilentlyContinue);Write-Output ('FFMPEG_COUNT='+$ff.Count);if($ff.Count -gt 0){throw 'Active FFmpeg/playback; refusing library mutation'}
  $media=@(Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue|Where-Object {$_.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'}|Select-Object -First 5)
  if($media.Count -eq 0){throw 'Home Videos source contains no recognized media'}
  Write-Output ('SOURCE_EXISTS=true|sample_media_count='+$media.Count)
  $pre=@(Run-Py 'precheck') -join ';';Write-Output $pre
  if($pre -notmatch 'name=Home Videos and Photos'){throw 'Precondition mismatch: target collection row'}
  if($pre -notmatch 'direct=0' -or $pre -notmatch 'top=0'){Write-Output 'REPAIR_STATUS=NOOP_ALREADY_INDEXED';$repairPassed=$true;return}
  New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
  $dbBackup=Join-Path $backupDir 'jellyfin.db'
  $b=@(Run-Py 'backup' $dbBackup) -join ';';Write-Output $b
  if(-not(Test-Path -LiteralPath $dbBackup -PathType Leaf)){throw 'SQLite online backup failed'}
  foreach($r in @($vfDir,'C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos')){if(Test-Path -LiteralPath $r -PathType Container){$dest=Join-Path $backupDir ((($r -replace '[:\\ ]','_').Trim('_')));Copy-Item -LiteralPath $r -Destination $dest -Recurse -Force}}
  Write-Output 'ROOT_CONFIG_BACKUP=PASS'
  $ins=@(Run-Py 'insert') -join ';';Write-Output $ins
  if($ins -notmatch 'exists=1'){throw 'Temporary API key insert verification failed'}
  $inserted=$true;Write-Output 'TEMP_KEY_INSERTED=true'
  $vf=Get-VirtualFolders
  Write-Output ('API_AUTH=PASS|virtual_folders='+$vf.Count)
  $lib=@($vf|Where-Object {[string]$_.Name -eq $name})
  if($lib.Count -ne 1){throw ('Home Videos virtual folder match count='+$lib.Count)}
  $locations=@($lib[0].Locations|ForEach-Object{[string]$_})
  $pis=@($lib[0].LibraryOptions.PathInfos)
  $sourcePi=@($pis|Where-Object {[string]$_.Path -ieq $source}|Select-Object -First 1)
  if($sourcePi.Count -gt 0){$sourcePi=$sourcePi[0]}else{$sourcePi=$null}
  $sourceInLocations=@($locations|Where-Object{$_ -ieq $source}).Count -gt 0
  Write-Output ('API_PRECHECK|itemId='+[string]$lib[0].ItemId+'|locations='+$locations.Count+'|pathInfos='+$pis.Count+'|sourceInLocations='+$sourceInLocations+'|sourcePathInfo='+[bool]($null -ne $sourcePi))
  if(-not $sourceInLocations -and $null -eq $sourcePi){throw 'API does not recognize expected source path; refusing remove'}
  Remove-Source $false;$removed=$true;Write-Output 'SOURCE_REMOVE_API=PASS'
  Start-Sleep -Milliseconds 1500
  Add-Source $sourcePi $true;$added=$true;Write-Output 'SOURCE_ADD_API=PASS|refresh=true'
  $deadline=(Get-Date).AddMinutes(8);$verified=$false
  do{
    Start-Sleep -Seconds 10
    $v=@(Run-Py 'verifyitems') -join ';';Write-Output $v
    if($v -match 'sourceRows=([1-9][0-9]*)' -or $v -match 'sourceDesc=([1-9][0-9]*)' -or $v -match 'direct=([1-9][0-9]*)' -or $v -match 'top=([1-9][0-9]*)'){$verified=$true;break}
  }while((Get-Date) -lt $deadline)
  if(-not $verified){throw 'Rebind completed but indexed descendants did not appear within verification window'}
  $vf2=Get-VirtualFolders;$lib2=@($vf2|Where-Object {[string]$_.Name -eq $name});if($lib2.Count -ne 1){throw 'Home Videos virtual folder missing after rebind'}
  $loc2=@($lib2[0].Locations|ForEach-Object{[string]$_});if(-not(@($loc2|Where-Object{$_ -ieq $source}).Count)){throw 'Home Videos source missing after rebind'}
  Write-Output ('API_POSTCHECK=PASS|locations='+$loc2.Count)
  $repairPassed=$true;Write-Output 'REPAIR_STATUS=PASS'
}catch{
  Write-Output ('REPAIR_STATUS=SAFE_STOP|error='+($_.Exception.Message -replace '\|','/'))
  if($removed -and -not $added -and $inserted){try{Add-Source $sourcePi $true;$added=$true;Write-Output 'ROLLBACK_READD=PASS'}catch{Write-Output ('ROLLBACK_READD=FAIL|error='+($_.Exception.Message -replace '\|','/'))}}
}finally{
  if($inserted){
    $clean=$false
    for($i=1;$i -le 5 -and -not $clean;$i++){try{$d=@(Run-Py 'delete') -join ';';$v=@(Run-Py 'verifykey') -join ';';if($v -match 'remaining=0'){$clean=$true;Write-Output ('TEMP_KEY_CLEANUP=PASS|attempt='+$i)}}catch{Start-Sleep -Milliseconds 700}}
    if(-not $clean){Write-Output 'TEMP_KEY_CLEANUP=FAIL'}
  }else{Write-Output 'TEMP_KEY_CLEANUP=NOT_NEEDED'}
  Write-Output ('BACKUP_DIR='+$backupDir)
  Write-Output 'SECRET_EXPOSED=false'
}
if(-not $repairPassed){exit 2}
