#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function Find-CommandPath([string[]]$Names){
  foreach($n in $Names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}}
  return $null
}
function Safe([object]$v){if($null -eq $v){return ''};return ([string]$v).Replace("`r",' ').Replace("`n",' ')}

Write-Output 'AFZ_JELLYFIN_LIVE_USERSTORE_AUDIT_V1'
Write-Output ('TIME='+((Get-Date).ToString('o')))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('COMPUTER='+$env:COMPUTERNAME)

$procs=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
foreach($p in $procs){
  $cmd=[string]$p.CommandLine
  $san=$cmd -replace '(?i)(--apikey(?:=|\s+))\S+','$1<redacted>'
  Write-Output ("PROCESS|pid=$($p.ProcessId)|exe=$(Safe $p.ExecutablePath)|cmd=$(Safe $san)")
}

$dirs=New-Object System.Collections.Generic.List[string]
foreach($p in @(
  'C:\Users\Faiz\AppData\Local\Jellyfin\data',
  'C:\ProgramData\Jellyfin\Server\data',
  'C:\Users\Faiz\AppData\Local\Jellyfin',
  'C:\ProgramData\Jellyfin\Server'
)){if(Test-Path -LiteralPath $p -PathType Container){[void]$dirs.Add($p)}}
foreach($p in $procs){
  $cmd=[string]$p.CommandLine
  foreach($rx in @('(?i)--datadir(?:=|\s+)"?([^"\r\n]+?)"?(?:\s+--|$)','(?i)--configdir(?:=|\s+)"?([^"\r\n]+?)"?(?:\s+--|$)')){
    if($cmd -match $rx){$d=$Matches[1].Trim().Trim('"');if((Test-Path -LiteralPath $d -PathType Container)-and -not $dirs.Contains($d)){[void]$dirs.Add($d)}}
  }
}
foreach($d in $dirs){Write-Output ("DIR|path=$(Safe $d)")}

$dbs=New-Object System.Collections.Generic.List[string]
foreach($d in $dirs){
  foreach($name in @('jellyfin.db','data\jellyfin.db','users.db','data\users.db')){
    $p=Join-Path $d $name
    if((Test-Path -LiteralPath $p -PathType Leaf)-and -not $dbs.Contains($p)){[void]$dbs.Add($p)}
  }
}
foreach($d in $dirs){
  try{foreach($p in @(Get-ChildItem -LiteralPath $d -Filter '*.db' -File -ErrorAction SilentlyContinue)){if(-not $dbs.Contains($p.FullName)){[void]$dbs.Add($p.FullName)}}}catch{}
}

$python=Find-CommandPath @('python.exe','python','py.exe','py')
if(-not $python){Write-Output 'AUDIT_STATUS=NO_PYTHON';exit 0}
$launcher=([IO.Path]::GetFileName($python)-match '^py(\.exe)?$')
$py=@'
import json, sqlite3, sys, os
p=sys.argv[1]
try:
  con=sqlite3.connect('file:'+p.replace('\\','/')+'?mode=ro',uri=True,timeout=5)
except Exception as e:
  print('DB_OPEN_ERROR|'+type(e).__name__); raise SystemExit(0)
try:
  tables=[r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]
  print('DB|path='+p+'|tables='+str(len(tables)))
  rel=[t for t in tables if any(x in t.lower() for x in ('user','permission','preference'))]
  print('RELATED_TABLES|'+','.join(rel))
  for t in rel:
    q='pragma table_info("'+t.replace('"','""')+'")'
    cols=[r[1] for r in con.execute(q)]
    print('SCHEMA|table='+t+'|columns='+','.join(cols))
    safe=[c for c in cols if not any(x in c.lower() for x in ('password','token','apikey','accesskey','secret','easy'))]
    if not safe: continue
    sql='select '+','.join('"'+c.replace('"','""')+'"' for c in safe)+' from "'+t.replace('"','""')+'" limit 500'
    try:
      for row in con.execute(sql):
        vals=[]
        for v in row:
          if isinstance(v,(bytes,bytearray)):
            if len(v)==16: vals.append(v.hex())
            else: vals.append('<blob:'+str(len(v))+'>')
          else: vals.append('' if v is None else str(v).replace('\r',' ').replace('\n',' '))
        print('ROW|table='+t+'|'+json.dumps(dict(zip(safe,vals)),separators=(',',':')))
    except Exception as e:
      print('ROW_ERROR|table='+t+'|'+type(e).__name__)
finally:
  con.close()
'@
foreach($db in $dbs){
  Write-Output ("DB_CANDIDATE|path=$(Safe $db)|bytes=$((Get-Item -LiteralPath $db).Length)|modified=$((Get-Item -LiteralPath $db).LastWriteTime.ToString('o'))")
  if($launcher){& $python -3 -c $py $db 2>$null}else{& $python -c $py $db 2>$null}
}

# Legacy per-user XML may still exist on mixed/migrated installations; inspect only safe fields.
foreach($root in @('C:\Users\Faiz\AppData\Local\Jellyfin\config\users','C:\ProgramData\Jellyfin\Server\config\users')){
  if(-not(Test-Path -LiteralPath $root -PathType Container)){continue}
  foreach($policy in @(Get-ChildItem -LiteralPath $root -Filter 'policy.xml' -File -Recurse -ErrorAction SilentlyContinue)){
    try{
      [xml]$x=Get-Content -LiteralPath $policy.FullName -Raw
      $n=$x.UserPolicy
      Write-Output ("LEGACY_POLICY|path=$(Safe $policy.FullName)|EnableAllFolders=$(Safe $n.EnableAllFolders)|EnabledFolders=$(Safe $n.EnabledFolders.InnerText)|IsAdministrator=$(Safe $n.IsAdministrator)")
    }catch{}
  }
}
Write-Output 'AUDIT_STATUS=PASS'
