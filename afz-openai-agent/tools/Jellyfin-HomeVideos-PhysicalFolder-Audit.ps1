#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$source='C:\Users\Faiz\Downloads\Cloud drive\OneDrive'
$itemId='EE75511A-E395-034B-1E7E-657707B15125'
$activeDef='C:\Users\Faiz\AppData\Local\Jellyfin\root\default\Home Videos and Photos'
$legacyDef='C:\ProgramData\Jellyfin\Server\root\default\Home Videos and Photos'
$logRoot='C:\Users\Faiz\AppData\Local\Jellyfin\log'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_PHYSICALFOLDER_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o));Write-Output 'READ_ONLY=true';Write-Output 'SECRET_EXPOSED=false'
$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py -or -not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=PREREQ_MISSING';exit 0}
$tmp=Join-Path $env:TEMP ('jf-home-phys-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,json,pathlib,os
p,target,source=sys.argv[1:4]
c=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=10);c.row_factory=sqlite3.Row
try:
 cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')];m={x.lower():x for x in cols}
 def col(k):return '"'+m[k]+'"' if k in m else 'NULL'
 fields=('id','name','type','path','parentid','topparentid','data','datecreated','datelastsaved','datelastrefreshed')
 rows=[dict(r) for r in c.execute('select '+','.join(col(k) for k in fields)+' from BaseItems')]
 def g(r,k):return r.get(m.get(k,'')) if m.get(k,'') else None
 def n(v):return ('' if v is None else str(v)).lower().replace('-','')
 t=target.lower().replace('-','');tr=[r for r in rows if n(g(r,'id'))==t]
 if not tr:print('TARGET_MISSING');sys.exit(0)
 r=tr[0];data={}
 try:data=json.loads(str(g(r,'data') or '{}'))
 except:pass
 phys=data.get('PhysicalFolderIds',[]) or []
 print('HOME_TARGET|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|physicalIds=%s'%(g(r,'id'),g(r,'name'),g(r,'type'),g(r,'path'),g(r,'parentid'),g(r,'topparentid'),';'.join(map(str,phys))))
 for pid in phys:
  pn=n(pid);prs=[x for x in rows if n(g(x,'id'))==pn]
  print('PHYS_ID|id=%s|rowCount=%d'%(pid,len(prs)))
  for x in prs:
   direct=sum(1 for y in rows if n(g(y,'parentid'))==pn);desc=sum(1 for y in rows if n(g(y,'topparentid'))==pn)
   print('PHYS_ROW|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s|direct=%d|desc=%d|data=%s'%(g(x,'id'),g(x,'name'),g(x,'type'),g(x,'path'),g(x,'parentid'),g(x,'topparentid'),direct,desc,str(g(x,'data') or '').replace('\r',' ').replace('\n',' ')[:2500]))
 s=source.lower()
 exact=[x for x in rows if str(g(x,'path') or '').lower()==s]
 under=[x for x in rows if str(g(x,'path') or '').lower().startswith(s+'\\')]
 print('SOURCE_EXACT_DB_ROWS=%d'%len(exact));print('SOURCE_DESC_DB_ROWS=%d'%len(under))
 for x in exact[:50]:print('SOURCE_EXACT|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s'%(g(x,'id'),g(x,'name'),g(x,'type'),g(x,'path'),g(x,'parentid'),g(x,'topparentid')))
 for x in under[:100]:print('SOURCE_CHILD_DB|id=%s|name=%s|type=%s|path=%s|parent=%s|top=%s'%(g(x,'id'),g(x,'name'),g(x,'type'),g(x,'path'),g(x,'parentid'),g(x,'topparentid')))
finally:c.close()
'@
[IO.File]::WriteAllText($tmp,$code,(New-Object Text.UTF8Encoding($false)))
try{$exe=$py.Path;if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){& $exe -3 $tmp $db $itemId $source}else{& $exe $tmp $db $itemId $source}}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
Write-Output ('SOURCE_EXISTS='+(Test-Path -LiteralPath $source -PathType Container))
if(Test-Path -LiteralPath $source -PathType Container){
 $si=Get-Item -LiteralPath $source -Force;Write-Output ('SOURCE_ATTRS='+[string]$si.Attributes)
 $dirs=@(Get-ChildItem -LiteralPath $source -Directory -Force -ErrorAction SilentlyContinue|Sort-Object Name);Write-Output ('SOURCE_DIRECT_DIR_COUNT='+$dirs.Count);foreach($d in $dirs){Write-Output ('SOURCE_DIR|name='+$d.Name+'|attrs='+[string]$d.Attributes+'|reparse='+(($d.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0))}
 $ign=@(Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)^(\.ignore|\.nomedia|\.jellyfinignore|\.plexignore|\.hidden)$'}|Select-Object -First 100);Write-Output ('IGNORE_FILE_COUNT_CAPPED='+$ign.Count);foreach($f in $ign){Write-Output ('IGNORE_FILE='+$f.FullName)}
 $media=@(Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction SilentlyContinue|Where-Object{$_.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic|webp)$'}|Select-Object -First 40)
 Write-Output ('MEDIA_SAMPLE_COUNT='+$media.Count)
 foreach($f in $media){$read=$false;try{$fs=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);try{$b=$fs.ReadByte();$read=($b -ge -1)}finally{$fs.Dispose()}}catch{};Write-Output ('MEDIA_SAMPLE|rel='+$f.FullName.Substring($source.Length).TrimStart('\')+'|size='+$f.Length+'|attrs='+[string]$f.Attributes+'|readable='+$read)}
}
foreach($def in @($activeDef,$legacyDef)){Write-Output ('DEF|path='+$def+'|exists='+(Test-Path -LiteralPath $def -PathType Container));if(Test-Path -LiteralPath $def -PathType Container){$opt=Join-Path $def 'options.xml';if(Test-Path -LiteralPath $opt -PathType Leaf){try{$xml=[xml](Get-Content -LiteralPath $opt -Raw -Encoding UTF8);Write-Output ('OPTIONS|path='+$opt+'|root='+$xml.DocumentElement.Name+'|collectionType='+[string]$xml.DocumentElement.CollectionType+'|enablePhotos='+[string]$xml.DocumentElement.EnablePhotos+'|enableRealtimeMonitor='+[string]$xml.DocumentElement.EnableRealtimeMonitor)}catch{Write-Output ('OPTIONS_READ_ERROR='+$_.Exception.Message)}}}}
if(Test-Path -LiteralPath $logRoot -PathType Container){$logs=@(Get-ChildItem -LiteralPath $logRoot -Filter 'log_*.log' -File|Sort-Object LastWriteTime -Descending|Select-Object -First 2);foreach($log in $logs){Write-Output ('LOG_SCAN|file='+$log.Name+'|mtime='+$log.LastWriteTime.ToString('o'));$matches=@(Select-String -LiteralPath $log.FullName -Pattern 'Home Videos','Cloud drive','OneDrive','Access denied','UnauthorizedAccess','IOException','Error refreshing','Scan Media Library','ValidateMediaLibrary' -SimpleMatch -ErrorAction SilentlyContinue|Select-Object -Last 120);foreach($m in $matches){$line=([string]$m.Line -replace '(?i)(ApiKey|api_key|Token)=[A-Za-z0-9._-]+','$1=<redacted>');Write-Output ('LOG_MATCH|'+$line)}}}
Write-Output 'STATUS=PASS';Write-Output 'SECRET_EXPOSED=false'
