#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$dataRoot='C:\Users\Faiz\AppData\Local\Jellyfin'
$name='Home Videos and Photos'
$itemId='EE75511A-E395-034B-1E7E-657707B15125'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$expectedServer='c3d285e9b6924aa8963af4f44b806579'
$tempName='AFZ-Temporary-HomeVideos-Rebind'
$tempToken=[guid]::NewGuid().ToString('N')
$backupRoot=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinHomeVideosRebind-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$removed=$false;$added=$false;$inserted=$false
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
$python=Find-Cmd @('python.exe','python','py.exe','py')
function Run-Py([string]$mode,[string]$arg=''){
 if(-not $python){throw 'Python is required.'}
 $tmp=Join-Path $env:TEMP ('jf-home-rebind-'+[guid]::NewGuid().ToString('n')+'.py')
 $code=@'
import sqlite3,sys,datetime,json,pathlib,os
p,mode,token,name,arg=sys.argv[1:6]
if mode=='backup':
 src=sqlite3.connect(p,timeout=15); dst=sqlite3.connect(arg,timeout=15)
 try: src.backup(dst); dst.commit(); print('BACKUP_OK')
 finally: dst.close(); src.close()
elif mode in ('insert','delete','verifykey'):
 c=sqlite3.connect(p,timeout=15)
 try:
  c.execute('pragma busy_timeout=15000')
  if mode=='insert':
   cols=[r[1] for r in c.execute('pragma table_info("ApiKeys")')]
   if not {'AccessToken','DateCreated','DateLastActivity','Name'}.issubset(set(cols)):
    print('SCHEMA_MISMATCH'); raise SystemExit(3)
   now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
   c.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name)); c.commit()
   n=c.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]; print('KEY_INSERTED=%d'%n)
  elif mode=='delete':
   c.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name)); c.commit(); print('KEY_DELETED')
  else:
   n=c.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0]; print('KEY_REMAINING=%d'%n)
 finally:c.close()
elif mode=='state':
 c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10); c.row_factory=sqlite3.Row
 try:
  cols=[r[1] for r in c.execute('pragma table_info("BaseItems")')]; low={x.lower():x for x in cols}
  def qcol(k): return '"'+low[k]+'"' if k in low else 'NULL'
  target=arg.lower().replace('-','')
  rows=[dict(r) for r in c.execute('select '+','.join(qcol(k) for k in ('id','name','type','path','parentid','topparentid','data'))+' from BaseItems')]
  def g(r,k): return r.get(low.get(k,'')) if low.get(k,'') else None
  def norm(v): return ('' if v is None else str(v)).lower().replace('-','')
  tr=[r for r in rows if norm(g(r,'id'))==target]
  direct=[r for r in rows if norm(g(r,'parentid'))==target]
  top=[r for r in rows if norm(g(r,'topparentid'))==target]
  phys=[]
  if tr:
   try: phys=json.loads(str(g(tr[0],'data') or '{}')).get('PhysicalFolderIds',[]) or []
   except: phys=[]
  print(json.dumps({'targetCount':len(tr),'name':(g(tr[0],'name') if tr else None),'path':(g(tr[0],'path') if tr else None),'physicalFolderIds':phys,'direct':len(direct),'desc':len(top)}))
 finally:c.close()
'@
 [IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
 try{
   if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){$out=& $python -3 $tmp $db $mode $tempToken $tempName $arg}else{$out=& $python $tmp $db $mode $tempToken $tempName $arg}
   if($LASTEXITCODE -ne 0){throw "Python mode $mode failed exit=$LASTEXITCODE"}
   return @($out|ForEach-Object{[string]$_})
 } finally {Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function ApiUri([string]$path){$sep=if($path.Contains('?')){'&'}else{'?'};return $base+$path+$sep+'ApiKey='+[uri]::EscapeDataString($tempToken)}
function Get-State(){return ((Run-Py 'state' $itemId)-join ''|ConvertFrom-Json)}
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_REBIND_REPAIR_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'TARGET_LIBRARY=Home Videos and Photos'
Write-Output 'MEDIA_FILE_WRITE=false'
try{
 if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw 'SAFE_STOP: live DB missing'}
 if(-not(Test-Path -LiteralPath $source -PathType Container)){throw 'SAFE_STOP: source folder missing'}
 $mediaCount=@(Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue|Where-Object{$_.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'}|Select-Object -First 10001).Count
 Write-Output ('SOURCE_MEDIA_COUNT_CAPPED='+$mediaCount)
 if($mediaCount -lt 1){throw 'SAFE_STOP: source has no media'}
 $pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 10
 Write-Output ('PUBLIC_SERVER|name='+[string]$pub.ServerName+'|version='+[string]$pub.Version+'|id='+[string]$pub.Id)
 if(([string]$pub.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: unexpected server id'}
 $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'jellyfin.exe'})
 Write-Output ('JELLYFIN_PROCESS_COUNT='+$procs.Count)
 if($procs.Count -ne 1){throw 'SAFE_STOP: Jellyfin process count is not one'}
 $cmd=[string]$procs[0].CommandLine
 if($cmd -and $cmd -notmatch '(?i)--datadir\s+"?C:\\Users\\Faiz\\AppData\\Local\\Jellyfin'){throw 'SAFE_STOP: process datadir mismatch'}
 $s=Get-State
 Write-Output ('PRE_DB_STATE|targetCount='+$s.targetCount+'|physicalIds='+@($s.physicalFolderIds).Count+'|direct='+$s.direct+'|desc='+$s.desc)
 if([int]$s.targetCount -ne 1 -or [string]$s.name -ne $name){throw 'SAFE_STOP: target DB row mismatch'}
 New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
 $dbBackup=Join-Path $backupRoot 'jellyfin.db'
 $b=(Run-Py 'backup' $dbBackup)-join ';'
 if($b -notmatch 'BACKUP_OK' -or -not(Test-Path -LiteralPath $dbBackup -PathType Leaf)){throw 'SAFE_STOP: DB backup failed'}
 foreach($root in @('C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos','C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos')){
   if(Test-Path -LiteralPath $root -PathType Container){$dest=Join-Path $backupRoot ((Split-Path $root -Leaf)+'-'+([guid]::NewGuid().ToString('n').Substring(0,8)));Copy-Item -LiteralPath $root -Destination $dest -Recurse -Force}
 }
 Write-Output ('BACKUP_DIR='+$backupRoot)
 $ins=(Run-Py 'insert')-join ';'
 if($ins -notmatch 'KEY_INSERTED=1'){throw 'SAFE_STOP: temporary API key insert failed'}
 $inserted=$true
 $info=Invoke-RestMethod -Uri (ApiUri '/System/Info') -Method Get -TimeoutSec 10
 Write-Output ('TEMP_API_AUTH=PASS|serverId='+[string]$info.Id)
 if(([string]$info.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: authenticated server id mismatch'}
 $vf=@(Invoke-RestMethod -Uri (ApiUri '/Library/VirtualFolders') -Method Get -TimeoutSec 15)
 $lib=@($vf|Where-Object{[string]$_.Name -eq $name})
 Write-Output ('VIRTUAL_FOLDER_MATCH_COUNT='+$lib.Count)
 if($lib.Count -ne 1){throw 'SAFE_STOP: Home Videos virtual folder is not unique'}
 if([string]$lib[0].ItemId -and (([string]$lib[0].ItemId).Replace('-','').ToLowerInvariant() -ne $itemId.Replace('-','').ToLowerInvariant())){throw 'SAFE_STOP: Home Videos item id mismatch'}
 $locs=@($lib[0].Locations|ForEach-Object{[string]$_})
 $pis=@();if($lib[0].LibraryOptions -and $lib[0].LibraryOptions.PathInfos){$pis=@($lib[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
 $present=(@($locs|Where-Object{$_ -ieq $source}).Count -gt 0) -or (@($pis|Where-Object{$_ -ieq $source}).Count -gt 0)
 Write-Output ('SOURCE_REGISTERED_BEFORE='+$present)
 if($present){
   $del=ApiUri ('/Library/VirtualFolders/Paths?name='+[uri]::EscapeDataString($name)+'&path='+[uri]::EscapeDataString($source)+'&refreshLibrary=false')
   Invoke-WebRequest -UseBasicParsing -Uri $del -Method Delete -TimeoutSec 30|Out-Null
   $removed=$true
   Write-Output 'REMOVE_PATH=PASS'
 }
 $body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress
 $add=ApiUri '/Library/VirtualFolders/Paths?refreshLibrary=true'
 Invoke-WebRequest -UseBasicParsing -Uri $add -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null
 $added=$true
 Write-Output 'ADD_PATH=PASS'
 $binding=$false
 for($i=1;$i -le 24 -and -not $binding;$i++){
   Start-Sleep -Seconds 5
   $v2=@(Invoke-RestMethod -Uri (ApiUri '/Library/VirtualFolders') -Method Get -TimeoutSec 15)
   $l2=@($v2|Where-Object{[string]$_.Name -eq $name})
   if($l2.Count -eq 1){$ll=@($l2[0].Locations|ForEach-Object{[string]$_});$pp=@();if($l2[0].LibraryOptions -and $l2[0].LibraryOptions.PathInfos){$pp=@($l2[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})};$binding=(@($ll|Where-Object{$_ -ieq $source}).Count -gt 0) -or (@($pp|Where-Object{$_ -ieq $source}).Count -gt 0)}
 }
 Write-Output ('SOURCE_REGISTERED_AFTER='+$binding)
 if(-not $binding){throw 'Repair failed: source was not registered after add'}
 $indexed=$false;$last=$null
 for($i=1;$i -le 60 -and -not $indexed;$i++){
   Start-Sleep -Seconds 5
   $last=Get-State
   if(@($last.physicalFolderIds).Count -gt 0 -and (([int]$last.direct -gt 0) -or ([int]$last.desc -gt 0))){$indexed=$true}
 }
 if($last){Write-Output ('POST_DB_STATE|physicalIds='+@($last.physicalFolderIds).Count+'|direct='+$last.direct+'|desc='+$last.desc)}
 Write-Output ('INDEXED_CHILDREN_READY='+$indexed)
 if($indexed){Write-Output 'REPAIR_STATUS=PASS'}else{Write-Output 'REPAIR_STATUS=PASS_BINDING_SCAN_PENDING'}
} catch {
 Write-Output ('REPAIR_STATUS=SAFE_STOP|error='+($_.Exception.Message -replace '\|','/'))
 if($removed -and -not $added -and $inserted){
   try{$body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress;Invoke-WebRequest -UseBasicParsing -Uri (ApiUri '/Library/VirtualFolders/Paths?refreshLibrary=false') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null;Write-Output 'ROLLBACK_READD=PASS'}catch{Write-Output 'ROLLBACK_READD=FAIL'}
 }
} finally {
 if($inserted){
   $clean=$false
   for($i=1;$i -le 3 -and -not $clean;$i++){try{[void](Run-Py 'delete');$v=(Run-Py 'verifykey')-join ';';if($v -match 'KEY_REMAINING=0'){$clean=$true;Write-Output ('TEMP_KEY_CLEANUP=PASS|attempt='+$i)}}catch{Start-Sleep -Milliseconds 500}}
   if(-not $clean){Write-Output 'TEMP_KEY_CLEANUP=FAIL'}
 } else {Write-Output 'TEMP_KEY_CLEANUP=NOT_NEEDED'}
 Write-Output 'SECRET_EXPOSED=false'
}
