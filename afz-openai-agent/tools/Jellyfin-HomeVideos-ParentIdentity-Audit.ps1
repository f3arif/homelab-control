#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$ids=@('F27CAA37-E514-2225-CCED-ED48F6553502','E9D5075A-555C-1CBC-394E-EC4CEF295274','EE75511A-E395-034B-1E7E-657707B15125','BE04AC47-5861-0637-7D2C-74AC1432209E')
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_PARENT_IDENTITY_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o));Write-Output 'READ_ONLY=true';Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py -or -not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=PREREQ_MISSING';exit 0}
$tmp=Join-Path $env:TEMP ('jf-parentid-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,json,pathlib
p=sys.argv[1];wanted={x.lower().replace('-','') for x in sys.argv[2:]}
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10);c.row_factory=sqlite3.Row
try:
 cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')];m={x.lower():x for x in cols}
 fields=('id','name','type','path','parentid','topparentid','data','datecreated','datelastsaved','datelastrefreshed')
 def col(k):return '"'+m[k]+'"' if k in m else 'NULL'
 rows=[dict(r) for r in c.execute('select '+','.join(col(k) for k in fields)+' from BaseItems')]
 def g(r,k):return r.get(m.get(k,'')) if m.get(k,'') else None
 def n(v):return ('' if v is None else str(v)).lower().replace('-','')
 for r in rows:
  if n(g(r,'id')) in wanted:
   rid=n(g(r,'id'));children=[x for x in rows if n(g(x,'parentid'))==rid]
   print('ID_ROW|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|children=%d|data=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),len(children),str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')[:3000]))
   for x in children[:100]:print('ID_CHILD|parent=%s|id=%s|name=%s|type=%s|path=%s'%(g(r,'id'),g(x,'id'),g(x,'name'),g(x,'type'),g(x,'path')))
 cf=[]
 for r in rows:
  typ=str(g(r,'type') or '')
  if 'CollectionFolder' in typ or 'UserRootFolder' in typ or 'AggregateFolder' in typ:
   cf.append(r)
 print('TOP_FOLDER_ROW_COUNT=%d'%len(cf))
 for r in cf:
  rid=n(g(r,'id'));children=sum(1 for x in rows if n(g(x,'parentid'))==rid)
  print('TOP_FOLDER|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|children=%d|data=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),children,str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')[:1800]))
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{$exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $db @ids}else{& $exe $tmp $db @ids}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
Write-Output 'STATUS=PASS';Write-Output 'SECRET_EXPOSED=false'
