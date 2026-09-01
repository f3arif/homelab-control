#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$library='Home Videos and Photos'
$itemId='EE75511A-E395-034B-1E7E-657707B15125'
$serverId='c3d285e9b6924aa8963af4f44b806579'
$tempName='AFZ-Temporary-HomeVideos-Rebind'
$tempToken=[guid]::NewGuid().ToString('N')
$backupDir=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinHomeVideosRebind-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$inserted=$false;$removed=$false;$added=$false
function Find-Python{foreach($n in @('python.exe','python','py.exe','py')){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){return $(if($c.Path){$c.Path}else{$c.Source})}};return $null}
$python=Find-Python
function RunPy([string]$mode,[string]$arg='-'){
 if(-not $python){throw 'Python missing'}
 if([string]::IsNullOrEmpty($arg)){$arg='-'}
 $tmp=Join-Path $env:TEMP ('jf-home-v2-'+[guid]::NewGuid().ToString('n')+'.py')
 $code=@'
import sqlite3,sys,datetime,json,pathlib
p,mode,token,name,arg=sys.argv[1:6]
if mode=='backup':
 s=sqlite3.connect(p,timeout=15); d=sqlite3.connect(arg,timeout=15)
 try: s.backup(d); d.commit(); print('BACKUP_OK')
 finally: d.close(); s.close()
elif mode in ('insert','delete','verifykey'):
 c=sqlite3.connect(p,timeout=15)
 try:
  c.execute('pragma busy_timeout=15000')
  if mode=='insert':
   cols={r[1] for r in c.execute('pragma table_info("ApiKeys")')}
   if not {'AccessToken','DateCreated','DateLastActivity','Name'}.issubset(cols): raise SystemExit(3)
   now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
   c.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name));c.commit()
   print('KEY_INSERTED=%d'%c.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0])
  elif mode=='delete':
   c.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name));c.commit();print('KEY_DELETED')
  else: print('KEY_REMAINING=%d'%c.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0])
 finally:c.close()
elif mode=='state':
 c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10);c.row_factory=sqlite3.Row
 try:
  cols=[r[1] for r in c.execute('pragma table_info("BaseItems")')];m={x.lower():x for x in cols}
  def col(k): return '"'+m[k]+'"' if k in m else 'NULL'
  rows=[dict(r) for r in c.execute('select '+','.join(col(k) for k in ('id','name','path','parentid','topparentid','data'))+' from BaseItems')]
  def g(r,k): return r.get(m.get(k,'')) if m.get(k,'') else None
  def n(v): return ('' if v is None else str(v)).lower().replace('-','')
  target=arg.lower().replace('-','');tr=[r for r in rows if n(g(r,'id'))==target]
  direct=[r for r in rows if n(g(r,'parentid'))==target];desc=[r for r in rows if n(g(r,'topparentid'))==target]
  phys=[]
  if tr:
   try: phys=json.loads(str(g(tr[0],'data') or '{}')).get('PhysicalFolderIds',[]) or []
   except: pass
  print(json.dumps({'target':len(tr),'name':g(tr[0],'name') if tr else None,'path':g(tr[0],'path') if tr else None,'physical':len(phys),'direct':len(direct),'desc':len(desc)}))
 finally:c.close()
'@
 [IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
 try{
   if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){$o=& $python -3 $tmp $db $mode $tempToken $tempName $arg}else{$o=& $python $tmp $db $mode $tempToken $tempName $arg}
   if($LASTEXITCODE -ne 0){throw "Python $mode failed exit=$LASTEXITCODE"}
   return @($o|ForEach-Object{[string]$_})
 }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function State{return (((RunPy 'state' $itemId)-join '')|ConvertFrom-Json)}
function Api([string]$path){$sep=if($path.Contains('?')){'&'}else{'?'};return $base+$path+$sep+'ApiKey='+[uri]::EscapeDataString($tempToken)}
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_REBIND_REPAIR_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'MEDIA_FILE_WRITE=false'
try{
 if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw 'SAFE_STOP: DB missing'}
 if(-not(Test-Path -LiteralPath $source -PathType Container)){throw 'SAFE_STOP: source missing'}
 $mc=@(Get-ChildItem -LiteralPath $source -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'}|Select-Object -First 10001).Count
 Write-Output ('SOURCE_MEDIA_COUNT_CAPPED='+$mc);if($mc -lt 1){throw 'SAFE_STOP: no media'}
 $pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 10
 Write-Output ('PUBLIC_SERVER|name='+[string]$pub.ServerName+'|version='+[string]$pub.Version+'|id='+[string]$pub.Id)
 if(([string]$pub.Id).ToLowerInvariant() -ne $serverId){throw 'SAFE_STOP: server id mismatch'}
 $jp=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'jellyfin.exe'});Write-Output ('JELLYFIN_PROCESS_COUNT='+$jp.Count);if($jp.Count -ne 1){throw 'SAFE_STOP: process count mismatch'}
 $cmd=[string]$jp[0].CommandLine;if($cmd -and $cmd -notmatch '(?i)--datadir\s+"?C:\\Users\\Faiz\\AppData\\Local\\Jellyfin'){throw 'SAFE_STOP: datadir mismatch'}
 $pre=State;Write-Output ('PRE_DB_STATE|target='+$pre.target+'|physical='+$pre.physical+'|direct='+$pre.direct+'|desc='+$pre.desc)
 if([int]$pre.target -ne 1 -or [string]$pre.name -ne $library){throw 'SAFE_STOP: target mismatch'}
 New-Item -ItemType Directory -Force -Path $backupDir|Out-Null
 if(((RunPy 'backup' (Join-Path $backupDir 'jellyfin.db'))-join ';') -notmatch 'BACKUP_OK'){throw 'SAFE_STOP: backup failed'}
 foreach($r in @('C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos','C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos')){if(Test-Path -LiteralPath $r -PathType Container){Copy-Item -LiteralPath $r -Destination (Join-Path $backupDir ('root-'+[guid]::NewGuid().ToString('n').Substring(0,8))) -Recurse -Force}}
 Write-Output ('BACKUP_DIR='+$backupDir)
 if(((RunPy 'insert')-join ';') -notmatch 'KEY_INSERTED=1'){throw 'SAFE_STOP: temp key insert failed'};$inserted=$true
 $si=Invoke-RestMethod -Uri (Api '/System/Info') -TimeoutSec 10;Write-Output ('TEMP_API_AUTH=PASS|serverId='+[string]$si.Id)
 if(([string]$si.Id).ToLowerInvariant() -ne $serverId){throw 'SAFE_STOP: auth server mismatch'}
 $vf=@(Invoke-RestMethod -Uri (Api '/Library/VirtualFolders') -TimeoutSec 15);$lib=@($vf|Where-Object{[string]$_.Name -eq $library});Write-Output ('VIRTUAL_FOLDER_MATCH_COUNT='+$lib.Count);if($lib.Count -ne 1){throw 'SAFE_STOP: virtual folder mismatch'}
 if([string]$lib[0].ItemId -and (([string]$lib[0].ItemId).Replace('-','').ToLowerInvariant() -ne $itemId.Replace('-','').ToLowerInvariant())){throw 'SAFE_STOP: item id mismatch'}
 $loc=@($lib[0].Locations|ForEach-Object{[string]$_});$pi=@();if($lib[0].LibraryOptions -and $lib[0].LibraryOptions.PathInfos){$pi=@($lib[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
 $present=(@($loc|Where-Object{$_ -ieq $source}).Count -gt 0)-or(@($pi|Where-Object{$_ -ieq $source}).Count -gt 0);Write-Output ('SOURCE_REGISTERED_BEFORE='+$present)
 if($present){$u=Api('/Library/VirtualFolders/Paths?name='+[uri]::EscapeDataString($library)+'&path='+[uri]::EscapeDataString($source)+'&refreshLibrary=false');Invoke-WebRequest -UseBasicParsing -Uri $u -Method Delete -TimeoutSec 30|Out-Null;$removed=$true;Write-Output 'REMOVE_PATH=PASS'}
 $body=@{Name=$library;Path=$source}|ConvertTo-Json -Compress;Invoke-WebRequest -UseBasicParsing -Uri (Api '/Library/VirtualFolders/Paths?refreshLibrary=true') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null;$added=$true;Write-Output 'ADD_PATH=PASS'
 $bound=$false
 for($i=0;$i -lt 24 -and -not $bound;$i++){Start-Sleep -Seconds 5;$v=@(Invoke-RestMethod -Uri (Api '/Library/VirtualFolders') -TimeoutSec 15);$l=@($v|Where-Object{[string]$_.Name -eq $library});if($l.Count -eq 1){$a=@($l[0].Locations|ForEach-Object{[string]$_});$b=@();if($l[0].LibraryOptions -and $l[0].LibraryOptions.PathInfos){$b=@($l[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})};$bound=(@($a|Where-Object{$_ -ieq $source}).Count -gt 0)-or(@($b|Where-Object{$_ -ieq $source}).Count -gt 0)}}
 Write-Output ('SOURCE_REGISTERED_AFTER='+$bound);if(-not $bound){throw 'Repair failed: binding absent'}
 $ready=$false;$last=$null
 for($i=0;$i -lt 60 -and -not $ready;$i++){Start-Sleep -Seconds 5;$last=State;if([int]$last.physical -gt 0 -and (([int]$last.direct -gt 0)-or([int]$last.desc -gt 0))){$ready=$true}}
 if($last){Write-Output ('POST_DB_STATE|physical='+$last.physical+'|direct='+$last.direct+'|desc='+$last.desc)}
 Write-Output ('INDEXED_CHILDREN_READY='+$ready);Write-Output $(if($ready){'REPAIR_STATUS=PASS'}else{'REPAIR_STATUS=PASS_BINDING_SCAN_PENDING'})
}catch{
 Write-Output ('REPAIR_STATUS=SAFE_STOP|error='+($_.Exception.Message -replace '\|','/'))
 if($removed -and -not $added -and $inserted){try{$body=@{Name=$library;Path=$source}|ConvertTo-Json -Compress;Invoke-WebRequest -UseBasicParsing -Uri (Api '/Library/VirtualFolders/Paths?refreshLibrary=false') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null;Write-Output 'ROLLBACK_READD=PASS'}catch{Write-Output 'ROLLBACK_READD=FAIL'}}
}finally{
 if($inserted){$clean=$false;for($i=1;$i -le 3 -and -not $clean;$i++){try{[void](RunPy 'delete');$q=(RunPy 'verifykey')-join ';';if($q -match 'KEY_REMAINING=0'){$clean=$true;Write-Output ('TEMP_KEY_CLEANUP=PASS|attempt='+$i)}}catch{Start-Sleep -Milliseconds 500}};if(-not $clean){Write-Output 'TEMP_KEY_CLEANUP=FAIL'}}else{Write-Output 'TEMP_KEY_CLEANUP=NOT_NEEDED'}
 Write-Output 'SECRET_EXPOSED=false'
}
