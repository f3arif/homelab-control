#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$oldRoot='C:\Windows\System32\config\systemprofile\AppData\Local\Jellyfin'
$oldDb=Join-Path $oldRoot 'data\jellyfin.db'
Write-Output 'AFZ_JELLYFIN_SYSTEMPROFILE_WEDDING_RECOVERY_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('OLD_ROOT_EXISTS='+(Test-Path -LiteralPath $oldRoot -PathType Container))
Write-Output ('OLD_DB_EXISTS='+(Test-Path -LiteralPath $oldDb -PathType Leaf))
if(-not(Test-Path -LiteralPath $oldDb -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=OLD_DB_MISSING';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmp=Join-Path $env:TEMP ('jf-old-wedding-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,json,pathlib,os
p=sys.argv[1]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
try:
 tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
 print('TABLE_COUNT=%d'%len(tabs))
 if 'BaseItems' not in tabs:
  print('STATUS=SAFE_STOP|reason=BASEITEMS_MISSING');sys.exit(0)
 cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')]; low={x.lower():x for x in cols}
 def C(n): return '"'+low[n].replace('"','""')+'"' if n in low else 'NULL'
 q='select '+','.join(C(x) for x in ('id','name','type','path','parentid','topparentid','data'))+' from BaseItems'
 rows=[dict(r) for r in c.execute(q)]
 def g(r,n): return r.get(low.get(n,'')) if low.get(n,'') else None
 def norm(v): return ('' if v is None else str(v)).replace('-','').lower()
 hits=[]
 for r in rows:
  name=str(g(r,'name') or '')
  typ=str(g(r,'type') or '')
  path=str(g(r,'path') or '')
  data=str(g(r,'data') or '')
  if 'wedding' in name.lower() or ('wedding' in path.lower() and ('CollectionFolder' in typ or 'Folder' in typ)):
   hits.append(r)
 print('WEDDING_DB_HIT_COUNT=%d'%len(hits))
 physical=[]
 for r in hits:
  print('WEDDING_DB_HIT|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|data=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')))
  if 'CollectionFolder' in str(g(r,'type') or ''):
   try:
    d=json.loads(str(g(r,'data') or '{}'))
    for x in d.get('PhysicalFolderIds') or []: physical.append(str(x))
    for x in d.get('PhysicalLocationsList') or []: print('WEDDING_LOCATION|path='+str(x))
    print('WEDDING_COLLECTION_TYPE='+str(d.get('CollectionType') or ''))
   except Exception as e: print('WEDDING_DATA_PARSE_ERROR='+type(e).__name__+':'+str(e))
 for pid in sorted(set(physical)):
  nr=pid.replace('-','').lower()
  ms=[r for r in rows if norm(g(r,'id'))==nr]
  print('WEDDING_PHYSICAL_ID|id=%s|rowCount=%d'%(pid,len(ms)))
  for r in ms: print('WEDDING_PHYSICAL_ROW|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid')))
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{$exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $oldDb}else{& $exe $tmp $oldDb};if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
$default=Join-Path $oldRoot 'root\default'
if(Test-Path -LiteralPath $default -PathType Container){
  $dirs=@(Get-ChildItem -LiteralPath $default -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '(?i)wedding'})
  Write-Output ('WEDDING_ROOTDIR_COUNT='+$dirs.Count)
  foreach($d in $dirs){
    Write-Output ('WEDDING_ROOTDIR|path='+$d.FullName)
    foreach($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue)){
      if($f.Extension -ieq '.mblink'){
        $v='';try{$v=([IO.File]::ReadAllText($f.FullName)).Trim()}catch{$v='READ_FAILED'}
        Write-Output ('WEDDING_MBLINK|file='+$f.Name+'|value='+$v+'|targetExists='+(if($v -and $v -ne 'READ_FAILED'){Test-Path -LiteralPath $v}else{$false}))
      } elseif($f.Name -ieq 'options.xml'){Write-Output ('WEDDING_OPTIONS|file='+$f.FullName+'|size='+$f.Length)}
    }
  }
}
Write-Output 'STATUS=PASS'
