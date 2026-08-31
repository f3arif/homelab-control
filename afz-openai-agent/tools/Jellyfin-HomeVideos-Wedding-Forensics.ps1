#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$liveDb='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$liveRoot='C:\Users\Faiz\AppData\Local\Jellyfin\root\default'
$targetId='ee75511ae395034b1e7e657707b15125'
$backupRoot='C:\AFZ\MediaCatalog\Backups'
Write-Output 'AFZ_JELLYFIN_HOMEVIDEOS_WEDDING_FORENSICS_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('TARGET_ID='+$targetId)

$py=(Get-Command python.exe,python,py.exe,py -ErrorAction SilentlyContinue|Select-Object -First 1)
if(-not $py){Write-Output 'FORENSICS_STATUS=FAIL|reason=NO_PYTHON';exit 1}
$dbs=New-Object System.Collections.Generic.List[string]
if(Test-Path -LiteralPath $liveDb -PathType Leaf){$dbs.Add($liveDb)}
if(Test-Path -LiteralPath $backupRoot -PathType Container){
  Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'jellyfin.db' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 80 | ForEach-Object {$dbs.Add($_.FullName)}
}
$dbs=@($dbs|Select-Object -Unique)
Write-Output ('DB_CANDIDATE_COUNT='+$dbs.Count)

$tmpPy=Join-Path $env:TEMP ('jf-home-wedding-'+[guid]::NewGuid().ToString('n')+'.py')
$code=@'
import sqlite3,sys,json,os,re
T=sys.argv[1].lower().replace('-','')
paths=sys.argv[2:]
out=[]
def norm(v): return ('' if v is None else str(v)).lower().replace('-','')
def qid(x): return '"'+x.replace('"','""')+'"'
for p in paths:
 d={'db':p,'target':[],'matches':[],'children':[],'error':None}
 try:
  uri='file:'+p.replace('\\','/')+'?mode=ro'
  c=sqlite3.connect(uri,uri=True,timeout=5);c.row_factory=sqlite3.Row
  tabs={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
  if 'BaseItems' not in tabs:
   d['error']='BaseItems_missing';out.append(d);c.close();continue
  cols=[r[1] for r in c.execute('pragma table_info(BaseItems)')];lc={x.lower():x for x in cols}
  wanted=[x for x in ('id','name','type','path','parentid','topparentid','presentationuniqueid','datecreated') if x in lc]
  if not wanted: d['error']='columns_missing';out.append(d);c.close();continue
  select=','.join(qid(lc[x]) for x in wanted)
  rows=[dict(r) for r in c.execute('select '+select+' from BaseItems')]
  for r in rows:
   rid=norm(r.get(lc.get('id','')))
   name=str(r.get(lc.get('name','')) or '')
   path=str(r.get(lc.get('path','')) or '')
   if rid==T: d['target'].append(r)
   text=(name+' '+path).lower()
   if 'wedding' in text or 'home videos' in text: d['matches'].append(r)
  if d['target'] and 'id' in lc:
   ids={norm(r.get(lc['id'])) for r in d['target']}
   for r in rows:
    par=norm(r.get(lc.get('parentid',''))) if 'parentid' in lc else ''
    top=norm(r.get(lc.get('topparentid',''))) if 'topparentid' in lc else ''
    if par in ids or top in ids: d['children'].append(r)
  c.close()
 except Exception as e: d['error']=type(e).__name__+':'+str(e)
 out.append(d)
print(json.dumps(out,separators=(',',':'),default=str))
'@
[IO.File]::WriteAllText($tmpPy,$code,(New-Object Text.UTF8Encoding($false)))
try {
  $exe=$py.Path
  if([IO.Path]::GetFileName($exe)-match '^py(\.exe)?$'){$raw=(& $exe -3 $tmpPy $targetId @dbs 2>&1|Out-String)}else{$raw=(& $exe $tmpPy $targetId @dbs 2>&1|Out-String)}
  if($LASTEXITCODE -ne 0){throw ('Python DB audit failed: '+$raw)}
  $data=$raw|ConvertFrom-Json
  $liveTarget=$null;$historicWedding=0;$historicHome=0
  foreach($d in @($data)){
    $isLive=([string]$d.db -ieq $liveDb)
    foreach($r in @($d.target)){
      $p=[string]$r.Path;$exists=$false;if($p){$exists=Test-Path -LiteralPath $p}
      Write-Output ('TARGET_ROW|scope='+(if($isLive){'live'}else{'backup'})+'|db='+[string]$d.db+'|name='+[string]$r.Name+'|type='+[string]$r.Type+'|path='+$p+'|path_exists='+$exists+'|parent='+[string]$r.ParentId)
      if($isLive){$liveTarget=$r}
    }
    if($isLive){Write-Output ('LIVE_TARGET_DESCENDANT_COUNT='+@($d.children).Count)}
    foreach($r in @($d.matches)){
      $nm=[string]$r.Name;$pp=[string]$r.Path;$low=($nm+' '+$pp).ToLowerInvariant()
      if($low -match 'wedding'){$historicWedding++}
      if($low -match 'home videos'){$historicHome++}
      if((-not $isLive) -or $low -match 'wedding'){
        $exists=$false;if($pp){$exists=Test-Path -LiteralPath $pp}
        Write-Output ('MATCH_ROW|scope='+(if($isLive){'live'}else{'backup'})+'|db='+[string]$d.db+'|name='+$nm+'|type='+[string]$r.Type+'|path='+$pp+'|path_exists='+$exists)
      }
    }
    if($d.error){Write-Output ('DB_AUDIT_NOTE|db='+[string]$d.db+'|'+[string]$d.error)}
  }
  Write-Output ('HOME_MATCH_TOTAL='+$historicHome)
  Write-Output ('WEDDING_MATCH_TOTAL='+$historicWedding)

  # Current virtual-folder configs and their absolute path references.
  if(Test-Path -LiteralPath $liveRoot -PathType Container){
    $dirs=@(Get-ChildItem -LiteralPath $liveRoot -Directory -Force -ErrorAction SilentlyContinue)
    Write-Output ('LIVE_ROOT_FOLDER_COUNT='+$dirs.Count)
    foreach($dir in $dirs){
      $refs=New-Object System.Collections.Generic.List[string]
      foreach($f in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.xml' -ErrorAction SilentlyContinue)){
        try{$txt=[IO.File]::ReadAllText($f.FullName)}catch{continue}
        foreach($m in [regex]::Matches($txt,'[A-Za-z]:\\[^<\r\n"]+')){$v=$m.Value.Trim();if(-not $refs.Contains($v)){$refs.Add($v)}}
      }
      if($refs.Count -eq 0){Write-Output ('ROOT_CONFIG|library='+$dir.Name+'|path_ref=NONE')}
      foreach($r in $refs){Write-Output ('ROOT_CONFIG|library='+$dir.Name+'|path_ref='+$r+'|exists='+(Test-Path -LiteralPath $r))}
    }
  } else {Write-Output 'LIVE_ROOT=missing'}

  # Search backed-up root/config files for Home Videos/Wedding and source paths.
  $cfgHits=0
  if(Test-Path -LiteralPath $backupRoot -PathType Container){
    foreach($f in @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Include '*.xml','*.txt' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1500)){
      try{$txt=[IO.File]::ReadAllText($f.FullName)}catch{continue}
      if($txt -match '(?i)Wedding|Home Videos and Photos'){
        $cfgHits++
        $refs=@([regex]::Matches($txt,'[A-Za-z]:\\[^<\r\n"]+')|ForEach-Object{$_.Value.Trim()}|Select-Object -Unique)
        if($refs.Count -eq 0){Write-Output ('BACKUP_CONFIG_HIT|file='+$f.FullName+'|path_ref=NONE')}
        foreach($r in $refs){Write-Output ('BACKUP_CONFIG_HIT|file='+$f.FullName+'|path_ref='+$r+'|exists='+(Test-Path -LiteralPath $r))}
      }
    }
  }
  Write-Output ('BACKUP_CONFIG_HIT_COUNT='+$cfgHits)

  # Fast bounded directory discovery across fixed drives (depth <= 4) for likely source folders.
  $found=New-Object System.Collections.Generic.List[string]
  function Scan-Dirs([string]$root,[int]$depth){
    if($depth -lt 0){return}
    $kids=@();try{$kids=@([IO.Directory]::EnumerateDirectories($root))}catch{return}
    foreach($k in $kids){
      $leaf=[IO.Path]::GetFileName($k)
      if($leaf -match '(?i)^Wedding$|Home Videos|HomeVideos'){$found.Add($k)}
      if($depth -gt 0 -and $leaf -notmatch '^(?i)(Windows|Program Files|Program Files \(x86\)|ProgramData|\$Recycle.Bin|System Volume Information|node_modules|\.git)$'){Scan-Dirs $k ($depth-1)}
      if($found.Count -ge 50){return}
    }
  }
  foreach($drv in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)){
    if($found.Count -ge 50){break}
    Scan-Dirs ([string]$drv.DeviceID+'\') 3
  }
  $found=@($found|Select-Object -Unique)
  Write-Output ('FILESYSTEM_NAME_HIT_COUNT='+$found.Count)
  foreach($p in $found){
    $mediaCount=0
    try{$mediaCount=@(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -match '(?i)^\.(mp4|mkv|mov|avi|m4v|mts|m2ts|jpg|jpeg|png|heic)$'}|Select-Object -First 5001).Count}catch{}
    Write-Output ('FILESYSTEM_HIT|path='+$p+'|media_count_capped='+$mediaCount)
  }
  Write-Output 'FORENSICS_STATUS=PASS'
} finally {
  Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue
}
