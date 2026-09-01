#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$activeRoot='C:\Users\Faiz\AppData\Local\Jellyfin\root\default'
$legacyRoot='C:\ProgramData\Jellyfin\Server\root\default'
$expectedServer='c3d285e9b6924aa8963af4f44b806579'
$names=@('Downloading','Home Videos and Photos','Movies','Stream Now (TorBox)')
$tempName='AFZ-Temporary-LegacyVF-Migration'
$tempToken=[guid]::NewGuid().ToString('N')
$backup=Join-Path 'C:\AFZ\MediaCatalog\Backups' ('JellyfinLegacyVFMigration-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$inserted=$false;$copied=New-Object System.Collections.Generic.List[string]
function Find-Python{foreach($n in @('python.exe','python','py.exe','py')){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){return $(if($c.Path){$c.Path}else{$c.Source})}};return $null}
$python=Find-Python
function RunPy([string]$mode,[string]$arg='-'){
 if(-not $python){throw 'Python missing'};if([string]::IsNullOrEmpty($arg)){$arg='-'}
 $tmp=Join-Path $env:TEMP ('jf-vfmig-'+[guid]::NewGuid().ToString('n')+'.py')
 $code=@'
import sqlite3,sys,datetime,pathlib,json
p,mode,token,name,arg=sys.argv[1:6]
if mode=='backup':
 s=sqlite3.connect(p,timeout=15);d=sqlite3.connect(arg,timeout=15)
 try:s.backup(d);d.commit();print('BACKUP_OK')
 finally:d.close();s.close()
elif mode in ('insert','delete','verify'):
 c=sqlite3.connect(p,timeout=15)
 try:
  c.execute('pragma busy_timeout=15000')
  if mode=='insert':
   cols={r[1] for r in c.execute('pragma table_info("ApiKeys")')}
   if not {'AccessToken','DateCreated','DateLastActivity','Name'}.issubset(cols):raise SystemExit(3)
   now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
   c.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name));c.commit()
   print('KEY_INSERTED=%d'%c.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0])
  elif mode=='delete':
   c.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name));c.commit();print('KEY_DELETED')
  else:print('KEY_REMAINING=%d'%c.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0])
 finally:c.close()
elif mode=='itemstate':
 c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10);c.row_factory=sqlite3.Row
 try:
  cols=[r[1] for r in c.execute('pragma table_info("BaseItems")')];m={x.lower():x for x in cols}
  def col(k):return '"'+m[k]+'"' if k in m else 'NULL'
  rows=[dict(r) for r in c.execute('select '+','.join(col(k) for k in ('id','name','parentid','topparentid','data'))+' from BaseItems')]
  def g(r,k):return r.get(m.get(k,'')) if m.get(k,'') else None
  def n(v):return ('' if v is None else str(v)).lower().replace('-','')
  t=arg.lower().replace('-','');tr=[r for r in rows if n(g(r,'id'))==t];direct=[r for r in rows if n(g(r,'parentid'))==t];desc=[r for r in rows if n(g(r,'topparentid'))==t]
  phys=[]
  if tr:
   try:phys=json.loads(str(g(tr[0],'data') or '{}')).get('PhysicalFolderIds',[]) or []
   except:pass
  print(json.dumps({'target':len(tr),'name':g(tr[0],'name') if tr else None,'physical':len(phys),'direct':len(direct),'desc':len(desc)}))
 finally:c.close()
'@
 [IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
 try{
  if([IO.Path]::GetFileName($python)-match '^py(\.exe)?$'){$o=& $python -3 $tmp $db $mode $tempToken $tempName $arg}else{$o=& $python $tmp $db $mode $tempToken $tempName $arg}
  if($LASTEXITCODE -ne 0){throw "Python $mode failed exit=$LASTEXITCODE"};return @($o|ForEach-Object{[string]$_})
 }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Api([string]$p){$s=if($p.Contains('?')){'&'}else{'?'};return $base+$p+$s+'ApiKey='+[uri]::EscapeDataString($tempToken)}
Write-Output 'AFZ_JELLYFIN_LEGACY_VF_MIGRATION_V1'
Write-Output ('TIME='+(Get-Date -Format o));Write-Output 'SECRET_EXPOSED=false';Write-Output 'MEDIA_FILE_WRITE=false';Write-Output 'LEGACY_ROOT_DELETE=false'
try{
 if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw 'SAFE_STOP: DB missing'}
 if(-not(Test-Path -LiteralPath $activeRoot -PathType Container)){throw 'SAFE_STOP: active root missing'}
 if(-not(Test-Path -LiteralPath $legacyRoot -PathType Container)){throw 'SAFE_STOP: legacy root missing'}
 $pub=Invoke-RestMethod -Uri ($base+'/System/Info/Public') -TimeoutSec 10;Write-Output ('PUBLIC_SERVER|name='+[string]$pub.ServerName+'|version='+[string]$pub.Version+'|id='+[string]$pub.Id)
 if(([string]$pub.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: server mismatch'}
 $procs=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -ieq 'jellyfin.exe'});Write-Output ('JELLYFIN_PROCESS_COUNT='+$procs.Count);if($procs.Count -ne 1){throw 'SAFE_STOP: process count mismatch'}
 $ff=@(Get-Process ffmpeg -ErrorAction SilentlyContinue);Write-Output ('FFMPEG_PROCESS_COUNT='+$ff.Count);if($ff.Count -gt 0){throw 'SAFE_STOP: active ffmpeg/playback detected'}
 foreach($n in $names){
  $src=Join-Path $legacyRoot $n;$dst=Join-Path $activeRoot $n
  if(-not(Test-Path -LiteralPath $src -PathType Container)){throw ('SAFE_STOP: missing legacy definition '+$n)}
  if(Test-Path -LiteralPath $dst){throw ('SAFE_STOP: active destination already exists '+$n)}
  if(-not(Test-Path -LiteralPath (Join-Path $src 'options.xml') -PathType Leaf)){throw ('SAFE_STOP: options.xml missing '+$n)}
  $links=@(Get-ChildItem -LiteralPath $src -Filter '*.mblink' -File -ErrorAction Stop);if($links.Count -lt 1){throw ('SAFE_STOP: mblink missing '+$n)}
  foreach($l in $links){$t=([IO.File]::ReadAllText($l.FullName)).Trim();if(-not(Test-Path -LiteralPath $t)){throw ('SAFE_STOP: mblink target missing '+$n)}}
 }
 New-Item -ItemType Directory -Force -Path $backup|Out-Null
 if(((RunPy 'backup' (Join-Path $backup 'jellyfin.db'))-join ';') -notmatch 'BACKUP_OK'){throw 'SAFE_STOP: DB backup failed'}
 Copy-Item -LiteralPath $activeRoot -Destination (Join-Path $backup 'active-root-before') -Recurse -Force
 foreach($n in $names){Copy-Item -LiteralPath (Join-Path $legacyRoot $n) -Destination (Join-Path $backup ('legacy-'+($n -replace '[^A-Za-z0-9._-]','_'))) -Recurse -Force}
 Write-Output ('BACKUP_DIR='+$backup)
 foreach($n in $names){$src=Join-Path $legacyRoot $n;$dst=Join-Path $activeRoot $n;Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force;$copied.Add($dst);Write-Output ('COPIED_VF='+$n)}
 foreach($n in $names){$dst=Join-Path $activeRoot $n;if(-not(Test-Path -LiteralPath (Join-Path $dst 'options.xml') -PathType Leaf)){throw ('Migration copy verify failed '+$n)};$links=@(Get-ChildItem -LiteralPath $dst -Filter '*.mblink' -File);if($links.Count -lt 1){throw ('Migration mblink verify failed '+$n)}}
 if(((RunPy 'insert')-join ';') -notmatch 'KEY_INSERTED=1'){throw 'SAFE_STOP: temp key insert failed'};$inserted=$true
 $si=Invoke-RestMethod -Uri (Api '/System/Info') -TimeoutSec 10;Write-Output ('TEMP_API_AUTH=PASS|serverId='+[string]$si.Id)
 if(([string]$si.Id).ToLowerInvariant() -ne $expectedServer){throw 'SAFE_STOP: auth server mismatch'}
 Write-Output 'LIBRARY_REFRESH=START'
 Invoke-WebRequest -UseBasicParsing -Uri (Api '/Library/Refresh') -Method Post -TimeoutSec 600|Out-Null
 Write-Output 'LIBRARY_REFRESH=PASS'
 $vf=@(Invoke-RestMethod -Uri (Api '/Library/VirtualFolders') -TimeoutSec 30)
 Write-Output ('LIVE_VIRTUAL_FOLDER_COUNT='+$vf.Count)
 foreach($x in $vf){Write-Output ('LIVE_VF|name='+[string]$x.Name+'|itemId='+[string]$x.ItemId+'|collectionType='+[string]$x.CollectionType)}
 foreach($n in $names){if(@($vf|Where-Object{[string]$_.Name -eq $n}).Count -ne 1){throw ('Migration verify missing live virtual folder '+$n)}}
 $home=@($vf|Where-Object{[string]$_.Name -eq 'Home Videos and Photos'})[0]
 $loc=@($home.Locations|ForEach-Object{[string]$_});$pi=@();if($home.LibraryOptions -and $home.LibraryOptions.PathInfos){$pi=@($home.LibraryOptions.PathInfos|ForEach-Object{[string]$_.Path})}
 $homeSource='C:\Users\Faiz\Downloads\Cloud drive\OneDrive';$bound=(@($loc|Where-Object{$_ -ieq $homeSource}).Count -gt 0)-or(@($pi|Where-Object{$_ -ieq $homeSource}).Count -gt 0)
 Write-Output ('HOME_SOURCE_BOUND='+$bound);if(-not $bound){throw 'Home Videos source not bound after migration'}
 $st=((RunPy 'itemstate' ([string]$home.ItemId))-join ''|ConvertFrom-Json);Write-Output ('HOME_DB_STATE|itemId='+[string]$home.ItemId+'|physical='+$st.physical+'|direct='+$st.direct+'|desc='+$st.desc)
 if([int]$st.physical -lt 1){throw 'Home Videos physical folder not registered after refresh'}
 Write-Output 'MIGRATION_STATUS=PASS'
}catch{
 Write-Output ('MIGRATION_STATUS=SAFE_STOP|error='+($_.Exception.Message -replace '\|','/'))
 if(-not $inserted -and $copied.Count -gt 0){foreach($p in @($copied)){try{Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop;Write-Output ('ROLLBACK_COPY_REMOVED='+$p)}catch{Write-Output ('ROLLBACK_COPY_REMOVE_FAILED='+$p)}}}
}finally{
 if($inserted){$ok=$false;for($i=1;$i -le 3 -and -not $ok;$i++){try{[void](RunPy 'delete');$v=(RunPy 'verify')-join ';';if($v -match 'KEY_REMAINING=0'){$ok=$true;Write-Output ('TEMP_KEY_CLEANUP=PASS|attempt='+$i)}}catch{Start-Sleep -Milliseconds 500}};if(-not $ok){Write-Output 'TEMP_KEY_CLEANUP=FAIL'}}else{Write-Output 'TEMP_KEY_CLEANUP=NOT_NEEDED'}
 Write-Output 'SECRET_EXPOSED=false'
}
