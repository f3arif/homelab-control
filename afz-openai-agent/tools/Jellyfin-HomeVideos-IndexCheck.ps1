#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$target='EE75511A-E395-034B-1E7E-657707B15125'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_INDEX_CHECK_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_MISSING';exit 2}
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 2}
$tmp=Join-Path $env:TEMP ('jf-home-index-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys
p,target,source=sys.argv[1],sys.argv[2].replace('-','').lower(),sys.argv[3].lower()
c=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5);c.row_factory=sqlite3.Row
try:
 cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')]; low={x.lower():x for x in cols}
 def col(n): return '"'+low[n].replace('"','""')+'"' if n in low else 'NULL'
 q='select '+','.join([col(x) for x in ('id','name','type','path','parentid','topparentid','data')])+' from BaseItems'
 rows=list(c.execute(q))
 def norm(v): return ('' if v is None else str(v)).replace('-','').lower()
 tr=[r for r in rows if norm(r[0])==target]
 print('TARGET_ROW_COUNT=%d'%len(tr))
 for r in tr: print('TARGET|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|data=%s'%tuple('' if x is None else str(x).replace('\r',' ').replace('\n',' ') for x in r))
 direct=[r for r in rows if norm(r[4])==target]
 desc=[r for r in rows if norm(r[5])==target]
 src=[r for r in rows if source in str(r[3] or '').lower()]
 print('LIVE_DIRECT_CHILD_COUNT=%d'%len(direct));print('LIVE_TOP_DESC_COUNT=%d'%len(desc));print('LIVE_SOURCE_PATH_ROW_COUNT=%d'%len(src))
 for r in src[:30]: print('SOURCE_ROW|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s'%tuple('' if x is None else str(x) for x in r[:6]))
except Exception as e:
 print('DB_ERROR=%s:%s'%(type(e).__name__,e));sys.exit(3)
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{$exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $db $target $source}else{& $exe $tmp $db $target $source};if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
$media=0
if(Test-Path -LiteralPath $source -PathType Container){foreach($f in Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue){if($f.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'){$media++;if($media -ge 10000){break}}}}
Write-Output ('SOURCE_MEDIA_COUNT_CAPPED='+$media)
Write-Output 'STATUS=PASS'
