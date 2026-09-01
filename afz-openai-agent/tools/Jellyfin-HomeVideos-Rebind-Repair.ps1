#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$name='Home Videos and Photos'
$itemId='EE75511A-E395-034B-1E7E-657707B15125'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$expectedServer='5ae656ad8fc948f38e1ac1d5a6769aa5'
$backupRoot=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinHomeVideosRebind-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$removed=$false;$added=$false
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
$python=Find-Cmd @('python.exe','python','py.exe','py')
function Run-Py([string]$mode,[string]$arg=''){
 if(-not $python){throw 'Python is required.'}
 $tmp=Join-Path $env:TEMP ('jf-home-rebind-'+[guid]::NewGuid().ToString('n')+'.py')
 $code=@'
import sqlite3,sys,json,pathlib
p,mode,arg=sys.argv[1:4]
if mode=='backup':
 src=sqlite3.connect(p,timeout=15); dst=sqlite3.connect(arg,timeout=15)
 try: src.backup(dst); dst.commit(); print('BACKUP_OK')
 finally: dst.close(); src.close()
elif mode=='key':
 c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10)
 try:
  r=c.execute("select AccessToken from ApiKeys where AccessToken is not null and length(AccessToken)>0 order by coalesce(DateLastActivity,DateCreated) desc limit 1").fetchone()
  print('' if not r else r[0])
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
   if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){$out=& $python -3 $tmp $db $mode $arg}else{$out=& $python $tmp $db $mode $arg}
   if($LASTEXITCODE -ne 0){throw "Python mode $mode failed exit=$LASTEXITCODE"}
   return @($out|ForEach-Object{[string]$_})
 } finally {Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Get-State(){return ((Run-Py 'state' $itemId)-join ''|ConvertFrom-Json)}
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_REBIND_REPAIR_V2'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'SECRET_EXPOSED=false'
Write-Output 'TARGET_LIBRARY=Home Videos and Photos'
Write-Output 'MEDIA_FILE_WRITE=false'
Write-Output 'MUTATION_SCOPE=one-existing-homevideos-media-path-remove-readd-and-refresh'
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
 Write-Output ('PROCESS|pid='+$procs[0].ProcessId+'|cmd='+(($cmd)-replace '\|','/'))
 if($cmd -and $cmd -notmatch '(?i)--datadir\s+"?C:\\Users\\Faiz\\AppData\\Local\\Jellyfin'){throw 'SAFE_STOP: process datadir mismatch'}
 $s=Get-State
 Write-Output ('PRE_DB_STATE|targetCount='+$s.targetCount+'|physicalIds='+@($s.physicalFolderIds).Count+'|direct='+$s.direct+'|desc='+$s.desc)
 if([int]$s.targetCount -ne 1 -or [string]$s.name -ne $name){throw 'SAFE_STOP: target DB row mismatch'}
 $token=((Run-Py 'key')-join '').Trim()
 if([string]::IsNullOrWhiteSpace($token)){throw 'SAFE_STOP: no server API key'}
 $headers=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Repair", Device="Windows-main", DeviceId="afz-homevideos-repair", Version="2.0", Token="'+$token+'"');Accept='application/json'}
 $info=Invoke-RestMethod -Uri ($base+'/System/Info') -Headers $headers -Method Get -TimeoutSec 10
 Write-Output ('API_AUTH=PASS|serverId='+[string]$info.Id)
 if(([string]$info.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: authenticated server id mismatch'}
 $vf=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $headers -Method Get -TimeoutSec 15)
 $lib=@($vf|Where-Object{[string]$_.Name -eq $name})
 Write-Output ('VIRTUAL_FOLDER_MATCH_COUNT='+$lib.Count)
 if($lib.Count -ne 1){throw 'SAFE_STOP: Home Videos virtual folder is not unique'}
 $locs=@($lib[0].Locations|ForEach-Object{[string]$_})
 $pis=@();if($lib[0].LibraryOptions -and $lib[0].LibraryOptions.PathInfos){$pis=@($lib[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
 Write-Output ('PRE_LOCATION_COUNT='+$locs.Count)
 foreach($p in $locs){Write-Output ('PRE_LOCATION|path='+$p+'|exists='+(Test-Path -LiteralPath $p))}
 Write-Output ('PRE_PATHINFO_COUNT='+$pis.Count)
 foreach($p in $pis){Write-Output ('PRE_PATHINFO|path='+$p)}
 if($locs.Count -ne 1 -or [string]$locs[0] -ine $source){throw 'SAFE_STOP: unexpected location set'}
 if(@($pis|Where-Object{$_ -ieq $source}).Count -gt 0 -and (@($s.physicalFolderIds).Count -gt 0 -or [int]$s.direct -gt 0 -or [int]$s.desc -gt 0)){
   Write-Output 'REPAIR_STATUS=NOOP_ALREADY_HEALTHY';exit 0
 }
 New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
 $dbBackup=Join-Path $backupRoot 'jellyfin.db'
 $b=(Run-Py 'backup' $dbBackup)-join ';'
 if($b -notmatch 'BACKUP_OK' -or -not(Test-Path -LiteralPath $dbBackup -PathType Leaf)){throw 'SAFE_STOP: DB backup failed'}
 foreach($root in @('C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos','C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos')){
   if(Test-Path -LiteralPath $root -PathType Container){$dest=Join-Path $backupRoot ((($root -replace '[:\\ ]','_').Trim('_')));Copy-Item -LiteralPath $root -Destination $dest -Recurse -Force}
 }
 Write-Output ('BACKUP_DIR='+$backupRoot)
 Write-Output 'BACKUP_STATUS=PASS'
 $nameQ=[uri]::EscapeDataString($name);$pathQ=[uri]::EscapeDataString($source)
 $del=$base+'/Library/VirtualFolders/Paths?name='+$nameQ+'&path='+$pathQ+'&refreshLibrary=false'
 Invoke-WebRequest -UseBasicParsing -Uri $del -Headers $headers -Method Delete -TimeoutSec 30|Out-Null
 $removed=$true
 Write-Output 'REMOVE_PATH=PASS'
 $body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress
 Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Library/VirtualFolders/Paths?refreshLibrary=true') -Headers $headers -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null
 $added=$true
 Write-Output 'ADD_PATH=PASS'
 $binding=$false
 for($i=1;$i -le 24 -and -not $binding;$i++){
   Start-Sleep -Seconds 5
   $v2=@(Invoke-RestMethod -Uri ($base+'/Library/VirtualFolders') -Headers $headers -Method Get -TimeoutSec 15)
   $l2=@($v2|Where-Object{[string]$_.Name -eq $name})
   if($l2.Count -eq 1){$ll=@($l2[0].Locations|ForEach-Object{[string]$_});$pp=@();if($l2[0].LibraryOptions -and $l2[0].LibraryOptions.PathInfos){$pp=@($l2[0].LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})};$binding=(@($ll|Where-Object{$_ -ieq $source}).Count -gt 0) -and (@($pp|Where-Object{$_ -ieq $source}).Count -gt 0)}
 }
 Write-Output ('PATH_BINDING_READY='+$binding)
 if(-not $binding){throw 'Repair failed: source PathInfo was not restored'}
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
 if($removed -and -not $added){
   try{
     $token=((Run-Py 'key')-join '').Trim();if($token){$headers=@{Authorization=('MediaBrowser Client="AFZ-HomeVideos-Repair", Device="Windows-main", DeviceId="afz-homevideos-repair", Version="2.0", Token="'+$token+'"');Accept='application/json'};$body=@{Name=$name;Path=$source}|ConvertTo-Json -Compress;Invoke-WebRequest -UseBasicParsing -Uri ($base+'/Library/VirtualFolders/Paths?refreshLibrary=true') -Headers $headers -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 60|Out-Null;Write-Output 'ROLLBACK_READD=PASS'}
   }catch{Write-Output 'ROLLBACK_READD=FAIL'}
 }
 exit 1
} finally {
 Write-Output 'TEMP_KEY_CREATED=false'
 Write-Output 'SECRET_EXPOSED=false'
}
