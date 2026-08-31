#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$liveDb='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$backupRoot='C:\AFZ\MediaCatalog\Backups'
$target='EE75511A-E395-034B-1E7E-657707B15125'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
Write-Output 'AFZ_JELLYFIN_HOME_WEDDING_DB_RECONCILE_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=FAIL|reason=NO_PYTHON';exit 1}
$dbs=New-Object System.Collections.Generic.List[string]
if(Test-Path -LiteralPath $liveDb -PathType Leaf){$dbs.Add($liveDb)}
if(Test-Path -LiteralPath $backupRoot -PathType Container){Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter jellyfin.db -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 100|ForEach-Object{$dbs.Add($_.FullName)}}
$dbs=@($dbs|Select-Object -Unique)
Write-Output ('DB_COUNT='+$dbs.Count)
$tmp=Join-Path $env:TEMP ('jf-dbrec-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,json,os
TARGET=sys.argv[1].lower().replace('-','')
SOURCE=sys.argv[2].lower()
for db in sys.argv[3:]:
 scope='live' if os.path.normcase(db)==os.path.normcase(sys.argv[3]) else 'backup'
 try:
  c=sqlite3.connect('file:'+db.replace('\\','/')+'?mode=ro',uri=True,timeout=4); c.row_factory=sqlite3.Row
  tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
  if 'BaseItems' not in tabs:
   print('DB_NOTE|scope=%s|db=%s|BaseItems_missing'%(scope,db)); c.close(); continue
  cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')]
  low={x.lower():x for x in cols}
  wanted=[k for k in ('id','name','type','path','parentid','topparentid','data','datecreated','datelastsaved','datelastrefreshed') if k in low]
  sel=','.join('"'+low[k].replace('"','""')+'"' for k in wanted)
  rows=[dict(r) for r in c.execute('select '+sel+' from BaseItems')]
  def g(r,k): return r.get(low.get(k,'')) if low.get(k,'') else None
  def norm(v): return ('' if v is None else str(v)).lower().replace('-','')
  target_rows=[r for r in rows if norm(g(r,'id'))==TARGET]
  for r in target_rows:
   print('TARGET|scope=%s|db=%s|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|data=%s'%(scope,db,g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')))
  if scope=='live':
   direct=[]; top=[]
   for r in rows:
    if norm(g(r,'parentid'))==TARGET: direct.append(r)
    if norm(g(r,'topparentid'))==TARGET: top.append(r)
   print('LIVE_DIRECT_CHILD_COUNT=%d'%len(direct)); print('LIVE_TOP_DESC_COUNT=%d'%len(top))
   for r in direct[:200]: print('LIVE_CHILD|id=%s|name=%s|type=%s|path=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path')))
   source_rows=[r for r in rows if SOURCE in str(g(r,'path') or '').lower()]
   print('LIVE_SOURCE_PATH_ROW_COUNT=%d'%len(source_rows))
   for r in source_rows[:200]: print('LIVE_SOURCE_ROW|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid')))
  hits=[]
  for r in rows:
   text=(str(g(r,'name') or '')+' '+str(g(r,'path') or '')+' '+str(g(r,'data') or '')).lower()
   if 'wedding' in text or SOURCE in text:
    hits.append(r)
  if hits:
   print('DB_MATCH_COUNT|scope=%s|db=%s|count=%d'%(scope,db,len(hits)))
   for r in hits[:100]: print('DB_MATCH|scope=%s|db=%s|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|data=%s'%(scope,db,g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')))
  c.close()
 except Exception as e:
  print('DB_ERROR|scope=%s|db=%s|error=%s:%s'%(scope,db,type(e).__name__,e))
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $target $source @dbs}else{& $exe $tmp $target $source @dbs}
 if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
 Write-Output 'STATUS=PASS'
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
