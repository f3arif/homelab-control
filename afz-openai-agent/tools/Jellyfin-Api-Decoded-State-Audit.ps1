#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
function J($o){$o|ConvertTo-Json -Depth 20 -Compress}
Write-Output 'AFZ_JELLYFIN_API_DECODED_STATE_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'READ_ONLY=true'
Write-Output 'SECRET_EXPOSED=false'
if(-not(Test-Path -LiteralPath $db -PathType Leaf)){Write-Output 'STATUS=SAFE_STOP|reason=DB_NOT_FOUND';exit 0}
$python=Find-Cmd @('python.exe','python','py.exe','py')
if(-not $python){Write-Output 'STATUS=SAFE_STOP|reason=NO_PYTHON';exit 0}
$tmpPy=Join-Path $env:TEMP ('jf-apikey-'+[guid]::NewGuid().ToString('n')+'.py')
$tmpJson=Join-Path $env:TEMP ('jf-apikey-'+[guid]::NewGuid().ToString('n')+'.json')
$py=@'
import json, sqlite3, sys, pathlib
p=sys.argv[1]; out=sys.argv[2]
con=sqlite3.connect('file:'+pathlib.Path(p).as_posix()+'?mode=ro',uri=True,timeout=5)
try:
    cols=[r[1] for r in con.execute('pragma table_info("ApiKeys")')]
    if 'AccessToken' not in cols:
        json.dump([],open(out,'w',encoding='utf-8')); raise SystemExit(0)
    q='select AccessToken, Name, DateLastActivity, DateCreated from ApiKeys where AccessToken is not null and length(AccessToken)>=16 order by DateLastActivity desc, DateCreated desc'
    rows=[]
    for r in con.execute(q): rows.append({'token':r[0],'name':r[1] or '','last':str(r[2] or ''),'created':str(r[3] or '')})
    json.dump(rows,open(out,'w',encoding='utf-8'))
finally:
    con.close()
'@
[IO.File]::WriteAllText($tmpPy,$py,(New-Object Text.UTF8Encoding($false)))
try {
  if([IO.Path]::GetFileName($python) -match '^py(\.exe)?$'){& $python -3 $tmpPy $db $tmpJson}else{& $python $tmpPy $db $tmpJson}
  if($LASTEXITCODE -ne 0 -or -not(Test-Path $tmpJson)){Write-Output 'STATUS=SAFE_STOP|reason=APIKEY_READ_FAILED';exit 0}
  $keys=@(Get-Content -LiteralPath $tmpJson -Raw -Encoding UTF8|ConvertFrom-Json)
  Write-Output ('APIKEY_CANDIDATES='+$keys.Count)
  $token=$null;$users=$null;$tested=0
  foreach($k in $keys){
    $tested++
    try{$r=Invoke-RestMethod -Uri ($base+'/Users') -Headers @{'X-Emby-Token'=[string]$k.token} -TimeoutSec 8;if($null -ne $r){$token=[string]$k.token;$users=@($r);break}}catch{}
  }
  Write-Output ('APIKEY_TESTED='+$tested)
  if(-not $token){Write-Output 'STATUS=SAFE_STOP|reason=NO_ACTIVE_API_KEY';exit 0}
  Write-Output 'API_AUTH=PASS'
  foreach($u in $users){
    $cfg=$u.Configuration;$pol=$u.Policy
    $state=[ordered]@{
      name=[string]$u.Name;id=[string]$u.Id;enableAllFolders=[bool]$pol.EnableAllFolders;
      myMediaExcludes=@($cfg.MyMediaExcludes);latestItemExcludes=@($cfg.LatestItemsExcludes);
      groupedFolders=@($cfg.GroupedFolders);orderedViews=@($cfg.OrderedViews)
    }
    Write-Output ('USER_STATE|'+(J $state))
    try{
      $v=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Id+'/Views?IncludeExternalContent=true') -Headers @{'X-Emby-Token'=$token} -TimeoutSec 10
      $items=@($v.Items|ForEach-Object{[ordered]@{name=[string]$_.Name;id=[string]$_.Id;type=[string]$_.Type;collectionType=[string]$_.CollectionType;displayPreferencesId=[string]$_.DisplayPreferencesId}})
      Write-Output ('USER_VIEWS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;count=$items.Count;items=$items})))
    }catch{Write-Output ('USER_VIEWS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
    try{
      $dp=Invoke-RestMethod -Uri ($base+'/DisplayPreferences/usersettings?userId='+$u.Id+'&client=emby') -Headers @{'X-Emby-Token'=$token} -TimeoutSec 10
      $home=[ordered]@{}
      if($dp.CustomPrefs){foreach($p in $dp.CustomPrefs.PSObject.Properties){if($p.Name -like 'homesection*' -or $p.Name -like 'landing-*'){$home[$p.Name]=[string]$p.Value}}}
      Write-Output ('DISPLAY_PREFS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;client=[string]$dp.Client;home=$home})))
    }catch{Write-Output ('DISPLAY_PREFS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
  }
  Write-Output 'STATUS=PASS'
} finally {
  Remove-Item -LiteralPath $tmpPy,$tmpJson -Force -ErrorAction SilentlyContinue
}
