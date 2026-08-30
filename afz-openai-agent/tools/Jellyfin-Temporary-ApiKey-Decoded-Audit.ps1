#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:8096'
$db='C:\Users\Faiz\AppData\Local\Jellyfin\data\jellyfin.db'
$name='AFZ-Temporary-Local-Audit'
$token=[guid]::NewGuid().ToString('N')
function Find-Cmd([string[]]$names){foreach($n in $names){$c=Get-Command $n -ErrorAction SilentlyContinue|Select-Object -First 1;if($c){if($c.Path){return $c.Path};if($c.Source){return $c.Source}}};return $null}
function J($o){$o|ConvertTo-Json -Depth 30 -Compress}
function Run-Py([string]$mode){
  $python=Find-Cmd @('python.exe','python','py.exe','py')
  if(-not $python){throw 'Python is required for bounded SQLite operation.'}
  $tmp=Join-Path $env:TEMP ('jf-tempkey-'+[guid]::NewGuid().ToString('n')+'.py')
  $py=@'
import sqlite3,sys,pathlib,datetime
p,mode,token,name=sys.argv[1:5]
con=sqlite3.connect(p,timeout=15)
try:
  con.execute('PRAGMA busy_timeout=15000')
  if mode=='insert':
    cols=[r[1] for r in con.execute('pragma table_info("ApiKeys")')]
    required={'Id','AccessToken','DateCreated','DateLastActivity','Name'}
    if not required.issubset(set(cols)):
      print('SCHEMA_MISMATCH'); raise SystemExit(3)
    before=con.execute('select count(*) from ApiKeys').fetchone()[0]
    now=datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S.%f')+'0'
    con.execute('insert into ApiKeys(AccessToken,DateCreated,DateLastActivity,Name) values(?,?,?,?)',(token,now,now,name))
    con.commit()
    after=con.execute('select count(*) from ApiKeys').fetchone()[0]
    exists=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
    print('INSERT|before=%d|after=%d|exists=%d'%(before,after,exists))
  elif mode=='delete':
    before=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
    con.execute('delete from ApiKeys where AccessToken=? and Name=?',(token,name))
    con.commit()
    after=con.execute('select count(*) from ApiKeys where AccessToken=? and Name=?',(token,name)).fetchone()[0]
    print('DELETE|before=%d|after=%d'%(before,after))
  elif mode=='verify':
    n=con.execute('select count(*) from ApiKeys where AccessToken=? or Name=?',(token,name)).fetchone()[0]
    print('VERIFY|remaining=%d'%n)
finally:
  con.close()
'@
  [IO.File]::WriteAllText($tmp,$py,(New-Object Text.UTF8Encoding($false)))
  try{
    if([IO.Path]::GetFileName($python) -match '^py(\.exe)?$'){& $python -3 $tmp $db $mode $token $name}else{& $python $tmp $db $mode $token $name}
    if($LASTEXITCODE -ne 0){throw "SQLite $mode failed with exit=$LASTEXITCODE"}
  } finally {Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
Write-Output 'AFZ_JELLYFIN_TEMP_APIKEY_DECODED_AUDIT_V1'
Write-Output ('TIME='+(Get-Date -Format o))
Write-Output 'LOCALHOST_ONLY=true'
Write-Output 'USER_LIBRARY_WRITE=false'
Write-Output 'TEMP_CREDENTIAL_EXPOSED=false'
Write-Output 'TEMP_KEY_INSERTED=false'
$inserted=$false
try {
  if(-not(Test-Path -LiteralPath $db -PathType Leaf)){throw "DB not found: $db"}
  $insertResult=@(Run-Py 'insert') -join ';'
  if($insertResult -notmatch 'exists=1'){throw "Temporary key insert verification failed: $insertResult"}
  $inserted=$true
  Write-Output 'TEMP_KEY_INSERTED=true'
  $h=@{'X-Emby-Token'=$token}
  $users=@(Invoke-RestMethod -Uri ($base+'/Users') -Headers $h -TimeoutSec 10)
  Write-Output ('API_AUTH=PASS|users='+$users.Count)
  foreach($u in $users){
    $cfg=$u.Configuration;$pol=$u.Policy
    $state=[ordered]@{
      name=[string]$u.Name;id=[string]$u.Id;enableAllFolders=[bool]$pol.EnableAllFolders;
      myMediaExcludes=@($cfg.MyMediaExcludes);latestItemExcludes=@($cfg.LatestItemsExcludes);
      groupedFolders=@($cfg.GroupedFolders);orderedViews=@($cfg.OrderedViews)
    }
    Write-Output ('USER_STATE|'+(J $state))
    try{
      $v=Invoke-RestMethod -Uri ($base+'/Users/'+$u.Id+'/Views?IncludeExternalContent=true') -Headers $h -TimeoutSec 10
      $items=@($v.Items|ForEach-Object{[ordered]@{name=[string]$_.Name;id=[string]$_.Id;type=[string]$_.Type;collectionType=[string]$_.CollectionType;displayPreferencesId=[string]$_.DisplayPreferencesId}})
      Write-Output ('USER_VIEWS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;count=$items.Count;items=$items})))
    }catch{Write-Output ('USER_VIEWS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
    try{
      $dp=Invoke-RestMethod -Uri ($base+'/DisplayPreferences/usersettings?userId='+$u.Id+'&client=emby') -Headers $h -TimeoutSec 10
      $home=[ordered]@{}
      if($dp.CustomPrefs){foreach($p in $dp.CustomPrefs.PSObject.Properties){if($p.Name -like 'homesection*' -or $p.Name -like 'landing-*'){$home[$p.Name]=[string]$p.Value}}}
      Write-Output ('DISPLAY_PREFS|'+(J ([ordered]@{name=[string]$u.Name;id=[string]$u.Id;client=[string]$dp.Client;home=$home})))
    }catch{Write-Output ('DISPLAY_PREFS_ERROR|user='+$u.Name+'|error='+$_.Exception.Message)}
  }
  Write-Output 'AUDIT_STATUS=PASS'
} catch {
  Write-Output ('AUDIT_STATUS=SAFE_STOP|error='+$_.Exception.Message)
} finally {
  if($inserted){
    $clean=$false
    for($i=1;$i -le 3 -and -not $clean;$i++){
      try{$d=@(Run-Py 'delete') -join ';';$v=@(Run-Py 'verify') -join ';';if($v -match 'remaining=0'){$clean=$true;Write-Output ('TEMP_KEY_CLEANUP=PASS|attempt='+$i)}}catch{Start-Sleep -Milliseconds 500}
    }
    if(-not $clean){Write-Output 'TEMP_KEY_CLEANUP=FAIL'}
  } else {Write-Output 'TEMP_KEY_CLEANUP=NOT_NEEDED'}
  Write-Output 'TEMP_CREDENTIAL_EXPOSED=false'
}
