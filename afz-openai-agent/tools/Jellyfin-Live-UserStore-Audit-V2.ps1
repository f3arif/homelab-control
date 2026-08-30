#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function Find-CommandPath([string[]]$Names){
  foreach($n in $Names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}}
  return $null
}
function Safe([object]$v){if($null -eq $v){return ''};return ([string]$v).Replace("`r",' ').Replace("`n",' ')}

Write-Output 'AFZ_JELLYFIN_LIVE_USERSTORE_AUDIT_V2'
Write-Output ('TIME='+((Get-Date).ToString('o')))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('COMPUTER='+$env:COMPUTERNAME)

$procs=@(Get-CimInstance Win32_Process -Filter "Name='jellyfin.exe'" -ErrorAction SilentlyContinue)
foreach($p in $procs){Write-Output ("PROCESS|pid=$($p.ProcessId)")}

$dbs=New-Object System.Collections.Generic.List[string]
foreach($p in @(
  'C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db',
  'C:\ProgramData\Jellyfin\Server\data\jellyfin.db',
  'C:\Users\Faiz\AppData\Local\Jellyfin\jellyfin.db',
  'C:\ProgramData\Jellyfin\Server\jellyfin.db'
)){
  if((Test-Path -LiteralPath $p -PathType Leaf)-and -not $dbs.Contains($p)){[void]$dbs.Add($p)}
}
if($dbs.Count -eq 0){Write-Output 'AUDIT_STATUS=NO_DB';exit 0}

$python=Find-CommandPath @('python.exe','python','py.exe','py')
if(-not $python){Write-Output 'AUDIT_STATUS=NO_PYTHON';exit 0}
$launcher=([IO.Path]::GetFileName($python)-match '^py(\.exe)?$')
$tmpPy=Join-Path $env:TEMP ('jf-userstore-v2-'+[guid]::NewGuid().ToString('n')+'.py')
$py=@'
import json, sqlite3, sys, pathlib
p=sys.argv[1]
uri='file:'+pathlib.Path(p).as_posix()+'?mode=ro'
try:
    con=sqlite3.connect(uri, uri=True, timeout=5)
except Exception as e:
    print('DB_OPEN_ERROR|'+type(e).__name__)
    raise SystemExit(0)
con.row_factory=sqlite3.Row
try:
    tables=[r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]
    print('DB|path='+p+'|tables='+str(len(tables)))
    lower={t.lower():t for t in tables}
    for wanted in ('users','permissions','preferences','baseitems'):
        t=lower.get(wanted)
        if not t: continue
        cols=[r[1] for r in con.execute('pragma table_info("'+t.replace('"','""')+'")')]
        print('SCHEMA|table='+t+'|columns='+','.join(cols))

    ut=lower.get('users')
    if ut:
        cols=[r[1] for r in con.execute('pragma table_info("'+ut+'")')]
        safe=[c for c in cols if not any(x in c.lower() for x in ('password','token','secret','apikey','accesskey','authprovider','resetprovider'))]
        preferred=[c for c in safe if c.lower() in ('id','username','name','internalid','lastlogindate','lastactivitydate')]
        use=preferred or safe[:8]
        sql='select '+','.join('"'+c.replace('"','""')+'"' for c in use)+' from "'+ut+'"'
        for r in con.execute(sql):
            d={c:('' if r[c] is None else str(r[c])) for c in use}
            print('USER|'+json.dumps(d,separators=(',',':')))

    pt=lower.get('permissions')
    if pt:
        cols=[r[1] for r in con.execute('pragma table_info("'+pt+'")')]
        use=[c for c in cols if c.lower() in ('userid','kind','value','id')]
        sql='select '+','.join('"'+c.replace('"','""')+'"' for c in use)+' from "'+pt+'"'
        for r in con.execute(sql):
            d={c:('' if r[c] is None else str(r[c])) for c in use}
            kind=''.join(str(d.get(c,'')) for c in use if c.lower()=='kind')
            if kind in ('16','EnableAllFolders','enableallfolders'):
                print('ENABLE_ALL_FOLDERS|'+json.dumps(d,separators=(',',':')))

    prt=lower.get('preferences')
    if prt:
        cols=[r[1] for r in con.execute('pragma table_info("'+prt+'")')]
        use=[c for c in cols if c.lower() in ('userid','kind','value','id')]
        sql='select '+','.join('"'+c.replace('"','""')+'"' for c in use)+' from "'+prt+'"'
        for r in con.execute(sql):
            d={c:('' if r[c] is None else str(r[c])) for c in use}
            kind=''.join(str(d.get(c,'')) for c in use if c.lower()=='kind')
            if kind in ('5','EnabledFolders','enabledfolders'):
                print('ENABLED_FOLDERS|'+json.dumps(d,separators=(',',':')))

    bt=lower.get('baseitems')
    if bt:
        cols=[r[1] for r in con.execute('pragma table_info("'+bt+'")')]
        candidates=[c for c in cols if c.lower() in ('id','name','type','path','parentid','presentationuniqueKey'.lower())]
        if candidates:
            sql='select '+','.join('"'+c.replace('"','""')+'"' for c in candidates)+' from "'+bt+'"'
            for r in con.execute(sql):
                d={c:('' if r[c] is None else str(r[c])) for c in candidates}
                typ=''.join(str(d.get(c,'')) for c in candidates if c.lower()=='type').lower()
                name=''.join(str(d.get(c,'')) for c in candidates if c.lower()=='name')
                path=''.join(str(d.get(c,'')) for c in candidates if c.lower()=='path')
                if 'collectionfolder' in typ or 'root/default' in path.lower() or name in ('Home Videos and Photos','Movies','Wedding','Stream Now (TorBox)','Real-Debrid Movies','TorBox Downloaded Movies','Bollywood   Hindi (TorBox)','Bollywood - Hindi (All Sources)','Bollywood - Hindi (Downloaded)','Movies - All Sources','qBittorrent Movies','Downloaded Movies'):
                    print('FOLDER|'+json.dumps(d,separators=(',',':')))
finally:
    con.close()
'@
[IO.File]::WriteAllText($tmpPy,$py,(New-Object Text.UTF8Encoding($false)))
try{
  foreach($db in $dbs){
    $fi=Get-Item -LiteralPath $db
    Write-Output ("DB_CANDIDATE|path=$(Safe $db)|bytes=$($fi.Length)|modified=$($fi.LastWriteTime.ToString('o'))")
    if($launcher){& $python -3 $tmpPy $db}else{& $python $tmpPy $db}
  }
}finally{Remove-Item -LiteralPath $tmpPy -Force -ErrorAction SilentlyContinue}
Write-Output 'AUDIT_STATUS=PASS'
