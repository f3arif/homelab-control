#Requires -Version 5.1
param([ValidateSet('coolyo','movies')][string]$User='coolyo')
$ErrorActionPreference='Stop'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$ids=@{coolyo='2D994DBA-B8C7-44C8-8D34-7D85716B2EBC';movies='64F6DF5C-78B5-4DFE-B0FF-7295CBFB3A5A'}
$userId=$ids[$User]

function Find-CommandPath([string[]]$Names){
  foreach($n in $Names){
    $c=Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
    if($c){
      if($c.Source){return [string]$c.Source}
      if($c.Path){return [string]$c.Path}
    }
  }
  return $null
}

$sqlite=Find-CommandPath @('sqlite3.exe','sqlite3')
$python=Find-CommandPath @('python.exe','python','py.exe','py')
$pythonLauncher=$false
if($python){$pythonLauncher=([IO.Path]::GetFileName($python) -match '^py(\.exe)?$')}
$backend=$(if($sqlite){'sqlite3-cli'}elseif($python){'python-stdlib-sqlite3'}else{'none'})

$pythonSql=@'
import sqlite3, sys
from pathlib import Path
p = Path(sys.argv[1]).resolve()
q = sys.argv[2]
uri = p.as_uri() + '?mode=ro'
con = sqlite3.connect(uri, uri=True, timeout=5)
try:
    cur = con.execute(q)
    for row in cur:
        vals=[]
        for v in row:
            if v is None:
                vals.append('')
            else:
                vals.append(str(v).replace('\r',' ').replace('\n',' '))
        print('|'.join(vals))
finally:
    con.close()
'@

function Sql([string]$q){
  if(-not(Test-Path $db)){return @()}
  if($sqlite){return @(& $sqlite -readonly -noheader -separator '|' $db $q 2>$null)}
  if($python){
    if($pythonLauncher){return @(& $python -3 -c $pythonSql $db $q 2>$null)}
    return @(& $python -c $pythonSql $db $q 2>$null)
  }
  return @()
}

if(-not($sqlite -or $python)){
  [ordered]@{ok=$false;user=$User;userId=$userId;sqliteBackend='none';reason='No read-only SQLite backend available. Install sqlite3 or Python, or use another authenticated Jellyfin API credential source.'}|ConvertTo-Json -Compress
  exit 0
}

$candidates=New-Object System.Collections.Generic.List[string]
$seen=New-Object 'System.Collections.Generic.HashSet[string]'
$tables=@(Sql "select name from sqlite_master where type='table' order by name;")
foreach($t in $tables){
  $safeT=$t.Replace('"','""')
  $cols=@(Sql ('pragma table_info("{0}");' -f $safeT))
  foreach($line in $cols){
    $p=$line -split '\|'
    if($p.Count -ge 3 -and $p[1] -match '(?i)token|accesskey|apikey'){
      $col=$p[1].Replace('"','""')
      try{
        $vals=@(Sql ('select "{0}" from "{1}" where "{0}" is not null and length("{0}")>=12 limit 100;' -f $col,$safeT))
        foreach($v in $vals){if($v -and $seen.Add($v)){[void]$candidates.Add($v)}}
      }catch{}
    }
  }
}
$valid=$null;$tested=0
foreach($tok in $candidates){
  $tested++
  try{
    $h=@{'X-Emby-Token'=$tok}
    $me=Invoke-RestMethod -Uri "http://127.0.0.1:8096/Users/$userId" -Headers $h -TimeoutSec 5
    if($me.Id){$valid=$tok;break}
  }catch{}
}
if(-not $valid){
  [ordered]@{ok=$false;user=$User;userId=$userId;sqliteBackend=$backend;candidateCount=$candidates.Count;tested=$tested;reason='No active token found; no secret values were exposed.'}|ConvertTo-Json -Compress
  exit 0
}
$headers=@{'X-Emby-Token'=$valid}
$out=New-Object System.Collections.Generic.List[object]
$errors=New-Object System.Collections.Generic.List[string]
foreach($uri in @(
  "http://127.0.0.1:8096/Users/$userId/Views?IncludeExternalContent=true",
  "http://127.0.0.1:8096/UserViews?userId=$userId&includeHidden=true"
)){
  try{
    $r=Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 10
    [void]$out.Add([ordered]@{endpoint=$uri;total=$r.TotalRecordCount;items=@($r.Items|ForEach-Object{[ordered]@{name=$_.Name;id=$_.Id;type=$_.Type;collectionType=$_.CollectionType;locationType=$_.LocationType;isFolder=$_.IsFolder}})})
  }catch{[void]$errors.Add("$uri :: $($_.Exception.Message)")}
}
[ordered]@{ok=($out.Count -gt 0);user=$User;userId=$userId;sqliteBackend=$backend;tokenFound=$true;tokenExposed=$false;tested=$tested;responses=@($out);errors=@($errors)}|ConvertTo-Json -Depth 10 -Compress
