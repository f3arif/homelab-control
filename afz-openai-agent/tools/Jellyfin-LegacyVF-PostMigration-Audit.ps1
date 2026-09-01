#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$base='http://127.0.0.1:8096'
$activeRoot='C:\Users\Faiz\AppData\Local\Jellyfin\root\default'
$tempName='AFZ-Temporary-PostMigration-Audit'
$tempToken=[guid]::NewGuid().ToString('N')
Write-Output 'AFZ_JELLYFIN_LEGACY_VF_POSTMIGRATION_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY_EXCEPT_TEMP_KEY=true'
Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmp=Join-Path $env:TEMP ('jf-postmig-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,json,datetime,urllib.request,urllib.parse,pathlib,os
p,base,token,name,root=sys.argv[1:6]
def key(mode):
 c=sqlite3.connect(p,timeout=15)
 try:
  if mode=='insert':
   now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
   c.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name));c.commit()
   return c.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
  if mode=='delete':
   c.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name));c.commit();return c.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0]
 finally:c.close()
def get_json(path):
 u=base+path+('&&' if '?' in path else '?')+'ApiKey='+urllib.parse.quote(token,safe='')
 with urllib.request.urlopen(u,timeout=30) as r:return json.loads(r.read().decode('utf-8'))
def db_rows():
 c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10);c.row_factory=sqlite3.Row
 try:
  cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')];m={x.lower():x for x in cols}
  def col(k):return '"'+m[k]+'"' if k in m else 'NULL'
  rows=[dict(r) for r in c.execute('select '+','.join(col(k) for k in ('id','name','type','path','parentid','topparentid','data'))+' from BaseItems')]
  def g(r,k):return r.get(m.get(k,'')) if m.get(k,'') else None
  def n(v):return ('' if v is None else str(v)).lower().replace('-','')
  homes=[]
  for r in rows:
   if str(g(r,'name') or '')=='Home Videos and Photos':
    phys=[]
    try:phys=json.loads(str(g(r,'data') or '{}')).get('PhysicalFolderIds',[]) or []
    except:pass
    rid=n(g(r,'id'));direct=sum(1 for x in rows if n(g(x,'parentid'))==rid);desc=sum(1 for x in rows if n(g(x,'topparentid'))==rid)
    homes.append({'id':g(r,'id'),'type':g(r,'type'),'path':g(r,'path'),'physical':len(phys),'direct':direct,'desc':desc})
  return homes
 finally:c.close()
inserted=False
try:
 if key('insert')!=1:print('STATUS=SAFE_STOP|reason=TEMP_KEY_INSERT_FAILED');sys.exit(0)
 inserted=True
 v=get_json('/Library/VirtualFolders')
 if not isinstance(v,list): v=[v]
 print('LIVE_VIRTUAL_FOLDER_COUNT=%d'%len(v))
 for x in v:
  loc=x.get('Locations') or []
  pis=((x.get('LibraryOptions') or {}).get('PathInfos') or [])
  ppaths=[str(z.get('Path') or '') for z in pis if isinstance(z,dict)]
  print('LIVE_VF|name=%s|itemId=%s|collectionType=%s|locations=%s|pathInfos=%s'%(x.get('Name',''),x.get('ItemId',''),x.get('CollectionType',''),';'.join(map(str,loc)),';'.join(ppaths)))
 homes=db_rows();print('HOME_DB_ROW_COUNT=%d'%len(homes))
 for h in homes:print('HOME_DB|id=%s|type=%s|path=%s|physical=%s|direct=%s|desc=%s'%(h['id'],h['type'],h['path'],h['physical'],h['direct'],h['desc']))
 if os.path.isdir(root):
  ds=sorted([x for x in os.listdir(root) if os.path.isdir(os.path.join(root,x))]);print('ACTIVE_ROOT_DIR_COUNT=%d'%len(ds));
  for x in ds:print('ACTIVE_ROOT_DIR='+x)
 print('STATUS=PASS')
finally:
 if inserted:
  try:rem=key('delete');print('TEMP_KEY_CLEANUP='+('PASS' if rem==0 else 'FAIL'))
  except Exception as e:print('TEMP_KEY_CLEANUP=FAIL')
 print('SECRET_EXPOSED=false')
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $db $base $tempToken $tempName $activeRoot}else{& $exe $tmp $db $base $tempToken $tempName $activeRoot}
 if($LASTEXITCODE -ne 0){Write-Output ('HELPER_EXIT='+$LASTEXITCODE)}
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
