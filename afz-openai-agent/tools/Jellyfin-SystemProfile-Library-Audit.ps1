#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Windows\System32\config\systemprofile\AppData\Local\Jellyfin\data\jellyfin.db'
$root='C:\Windows\System32\config\systemprofile\AppData\Local\Jellyfin\root\default'
Write-Output 'AFZ_JELLYFIN_SYSTEMPROFILE_LIBRARY_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('DB_EXISTS='+(Test-Path -LiteralPath $db -PathType Leaf))
Write-Output ('ROOT_EXISTS='+(Test-Path -LiteralPath $root -PathType Container))
if(Test-Path -LiteralPath $root -PathType Container){
  $dirs=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)
  Write-Output ('ROOT_DIR_COUNT='+$dirs.Count)
  foreach($d in $dirs){
    Write-Output ('ROOT_DIR|name='+$d.Name+'|path='+$d.FullName)
    foreach($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue|Where-Object {$_.Extension -in @('.mblink','.xml')})){
      if($f.Extension -ieq '.mblink'){
        $v='';try{$v=([IO.File]::ReadAllText($f.FullName)).Trim()}catch{$v='<read-failed>'}
        Write-Output ('MLINK|library='+$d.Name+'|file='+$f.Name+'|target='+$v+'|targetExists='+(if($v -and $v -ne '<read-failed>'){Test-Path -LiteralPath $v}else{$false}))
      } else { Write-Output ('CONFIG_FILE|library='+$d.Name+'|file='+$f.Name+'|size='+$f.Length) }
    }
  }
}
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 0}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmp=Join-Path $env:TEMP ('jf-syslib-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,pathlib,json
p=sys.argv[1]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
try:
 tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
 print('TABLE_COUNT=%d'%len(tabs))
 if 'BaseItems' not in tabs:
  print('BASEITEMS_MISSING=true');sys.exit(0)
 cols=[r[1] for r in c.execute('pragma table_info("BaseItems")')]; low={x.lower():x for x in cols}
 wanted=[k for k in ('id','name','type','path','parentid','topparentid','data') if k in low]
 sel=','.join('"'+low[k]+'"' for k in wanted)
 rows=[dict(r) for r in c.execute('select '+sel+' from BaseItems')]
 def g(r,k):return r.get(low.get(k,'')) if low.get(k,'') else None
 libs=[r for r in rows if 'collectionfolder' in str(g(r,'type') or '').lower()]
 print('COLLECTION_FOLDER_COUNT=%d'%len(libs))
 for r in libs:
  data=str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')
  print('COLLECTION|id=%s|name=%s|path=%s|parent=%s|top=%s|data=%s'%(g(r,'id'),g(r,'name'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),data))
 wedd=[r for r in rows if 'wedding' in ((str(g(r,'name') or '')+' '+str(g(r,'path') or '')+' '+str(g(r,'data') or '')).lower())]
 print('WEDDING_MATCH_COUNT=%d'%len(wedd))
 for r in wedd[:100]:print('WEDDING_MATCH|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|data=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),str(g(r,'data') or '').replace('\r',' ').replace('\n',' ')))
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{
 $exe=$py.Path
 if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $db}else{& $exe $tmp $db}
 if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
 Write-Output 'STATUS=PASS'
}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
