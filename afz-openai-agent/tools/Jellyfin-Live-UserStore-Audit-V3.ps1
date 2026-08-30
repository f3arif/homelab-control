#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function Find-CommandPath([string[]]$Names){
  foreach($n in $Names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Source){return [string]$c.Source};if($c.Path){return [string]$c.Path}}}
  return $null
}
function Safe([object]$v){if($null -eq $v){return ''};return ([string]$v).Replace("`r",' ').Replace("`n",' ')}

Write-Output 'AFZ_JELLYFIN_LIVE_USERSTORE_AUDIT_V3'
Write-Output ('TIME='+((Get-Date).ToString('o')))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
Write-Output ('COMPUTER='+$env:COMPUTERNAME)

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
$tmpPy=Join-Path $env:TEMP ('jf-userstore-v3-'+[guid]::NewGuid().ToString('n')+'.py')
$py=@'
import json, sqlite3, sys, pathlib
p=sys.argv[1]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
con.row_factory=sqlite3.Row
try:
    tables=[r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]
    lower={t.lower():t for t in tables}
    print('DB|path='+p+'|tables='+str(len(tables)))

    ut=lower.get('users')
    if ut:
        for r in con.execute('select Id,InternalId,Username,LastActivityDate,LastLoginDate from Users'):
            print('USER|'+json.dumps({k:('' if r[k] is None else str(r[k])) for k in r.keys()},separators=(',',':')))

    pt=lower.get('permissions')
    if pt:
        for r in con.execute('select Id,Kind,UserId,Value from Permissions where Kind=16'):
            print('ENABLE_ALL_FOLDERS|'+json.dumps({k:('' if r[k] is None else str(r[k])) for k in r.keys()},separators=(',',':')))

    prt=lower.get('preferences')
    if prt:
        labels={5:'EnabledFolders',7:'LatestItemExcludes',8:'MyMediaExcludes',9:'GroupedFolders',11:'OrderedViews'}
        for r in con.execute('select Id,Kind,UserId,Value from Preferences where Kind in (5,7,8,9,11) order by UserId,Kind,Id'):
            d={k:('' if r[k] is None else str(r[k])) for k in r.keys()}
            d['Label']=labels.get(int(r['Kind']) if r['Kind'] is not None else -1,'Other')
            print('PREFERENCE|'+json.dumps(d,separators=(',',':')))

    bt=lower.get('baseitems')
    if bt:
        wanted=('Home Videos and Photos','Movies','Wedding','Stream Now (TorBox)','Real-Debrid Movies','TorBox Downloaded Movies','Bollywood   Hindi (TorBox)','Bollywood - Hindi (All Sources)','Bollywood - Hindi (Downloaded)','Movies - All Sources','qBittorrent Movies','Downloaded Movies','Downloading')
        q='select Id,Name,ParentId,Path,PresentationUniqueKey,Type from BaseItems where Type like ? or Name in ('+','.join('?' for _ in wanted)+')'
        params=['%CollectionFolder%']+list(wanted)
        for r in con.execute(q,params):
            print('FOLDER|'+json.dumps({k:('' if r[k] is None else str(r[k])) for k in r.keys()},separators=(',',':')))
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
